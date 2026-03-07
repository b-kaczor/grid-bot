# frozen_string_literal: true

module Features
  module BotHelpers
    # Create a running bot with seeded grid levels and Redis state.
    def create_running_bot(exchange_account:, pair: 'ETHUSDT', **overrides)
      bot = create(
        :bot,
        exchange_account:,
        pair:,
        status: 'running',
        base_coin: pair.delete_suffix('USDT'),
        quote_coin: 'USDT',
        lower_price: 2000,
        upper_price: 3000,
        grid_count: 5,
        **overrides
      )

      seed_grid_levels(bot)
      seed_bot_redis_state(bot)
      bot
    end

    # Seed the Redis state for a bot (stats, price, levels).
    def seed_bot_redis_state(bot)
      redis_state = setup_mock_redis_state
      redis_state.seed(bot)
      redis_state.update_price(bot.id, '2500.00')
      seed_stats(bot)
      redis_state
    end

    # Seed balance snapshots for chart rendering (requires >= 2 records).
    def seed_bot_with_charts(bot)
      redis_state = seed_bot_redis_state(bot)
      create_chart_snapshots(bot)
      redis_state
    end

    private

    def setup_mock_redis_state
      mock_redis = MockRedis.new
      allow(Redis).to receive(:new).and_return(mock_redis)

      redis_state = Grid::RedisState.new(redis: mock_redis)
      allow(Grid::RedisState).to receive(:new).and_return(redis_state)
      redis_state
    end

    def seed_stats(bot)
      mock_redis = Redis.new
      mock_redis.hset("grid:#{bot.id}:stats", 'realized_profit', '50.00')
      mock_redis.hset("grid:#{bot.id}:stats", 'trade_count', bot.trades.count.to_s)
    end

    def create_chart_snapshots(bot)
      create(
        :balance_snapshot, bot:,
                           snapshot_at: 2.hours.ago, total_value_quote: '10000.00',
                           realized_profit: '0.00', current_price: '2400.00'
      )
      create(
        :balance_snapshot, bot:,
                           snapshot_at: 1.hour.ago, total_value_quote: '10050.00',
                           realized_profit: '50.00', current_price: '2500.00'
      )
    end

    def seed_grid_levels(bot)
      step = (bot.upper_price - bot.lower_price) / bot.grid_count
      (0..bot.grid_count).each do |i|
        price = bot.lower_price + (step * i)
        side = price < 2500 ? 'buy' : 'sell'
        create(:grid_level, bot:, level_index: i, price:, expected_side: side, status: 'active')
      end
    end
  end
end

RSpec.configure do |config|
  config.include Features::BotHelpers, type: :feature
end
