# frozen_string_literal: true

module Features
  # Thread-safe MockRedis singleton for feature specs.
  # Both the test thread and Puma server thread share this instance.
  # Only intercepts Redis.new when a feature spec is actively running;
  # non-feature specs get a real Redis instance via super.
  module RedisOverride
    def new(*)
      if Features::BotHelpers.feature_spec_active?
        Features::BotHelpers.mock_redis
      else
        super
      end
    end
  end

  module BotHelpers
    module ClassMethods
      def mock_redis_instance
        Features::BotHelpers.mock_redis
      end
    end

    def self.included(base)
      base.extend(ClassMethods)
    end

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
      redis_state = Grid::RedisState.new(redis: self.class.mock_redis_instance)
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

    # Class-level mock redis instance shared across threads (test + Puma)
    def self.mock_redis
      @mock_redis ||= MockRedis.new
    end

    def self.reset_mock_redis!
      @mock_redis = MockRedis.new
    end

    def self.feature_spec_active?
      @feature_spec_active == true
    end

    def self.feature_spec_active=(value)
      @feature_spec_active = value
    end

    private

    def seed_stats(bot)
      redis = Features::BotHelpers.mock_redis
      redis.hset("grid:#{bot.id}:stats", 'realized_profit', '50.00')
      redis.hset("grid:#{bot.id}:stats", 'trade_count', bot.trades.count.to_s)
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

  # Prepend Redis.new override for feature specs so Puma thread uses MockRedis
  config.before(:suite) do
    next unless RSpec.configuration.files_to_run.any? { |f| f.include?('spec/features') }

    Redis.singleton_class.prepend(Features::RedisOverride)
  end

  config.before(:each, type: :feature) do
    Features::BotHelpers.feature_spec_active = true
    Features::BotHelpers.reset_mock_redis!
  end

  config.after(:each, type: :feature) do
    Features::BotHelpers.feature_spec_active = false
  end
end
