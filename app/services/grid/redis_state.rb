# frozen_string_literal: true

module Grid
  class RedisState
    PREFIX = 'grid'

    KNOWN_SUFFIXES = %w[status current_price levels stats].freeze

    def initialize(redis: nil)
      @redis = redis || Redis.new(url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0'))
    end

    def seed(bot)
      bot_id = bot.id
      @redis.pipelined do |pipe|
        pipe.set(key(bot_id, :status), bot.status)
        seed_stats(pipe, bot_id)
        seed_levels(pipe, bot_id, bot.grid_levels)
      end
    end

    def update_on_fill(bot, grid_level, trade = nil)
      bot_id = bot.id
      @redis.pipelined do |pipe|
        pipe.hset(key(bot_id, :levels), grid_level.level_index.to_s, level_json(grid_level))
        if trade
          pipe.hincrby(key(bot_id, :stats), 'trade_count', 1)
          pipe.hset(key(bot_id, :stats), 'realized_profit', bot.trades.sum(:net_profit).to_s)
        end
      end
    end

    def update_price(bot_id, price)
      @redis.set(key(bot_id, :current_price), price.to_s)
    end

    def update_status(bot_id, status)
      @redis.set(key(bot_id, :status), status)
    end

    def cleanup(bot_id)
      keys = KNOWN_SUFFIXES.map { |s| key(bot_id, s) }
      @redis.del(*keys)
    end

    private

    def seed_levels(pipe, bot_id, grid_levels)
      grid_levels.each do |level|
        pipe.hset(key(bot_id, :levels), level.level_index.to_s, level_json(level))
      end
    end

    def seed_stats(pipe, bot_id)
      stats_key = key(bot_id, :stats)
      pipe.hset(stats_key, 'realized_profit', '0')
      pipe.hset(stats_key, 'trade_count', '0')
      pipe.hset(stats_key, 'uptime_start', Time.current.to_i.to_s)
    end

    def key(bot_id, suffix)
      "#{PREFIX}:#{bot_id}:#{suffix}"
    end

    def level_json(level)
      Oj.dump(
        {
          side: level.expected_side,
          status: level.status,
          price: level.price.to_s,
          order_id: level.current_order_id,
          cycle_count: level.cycle_count,
        }
      )
    end
  end
end
