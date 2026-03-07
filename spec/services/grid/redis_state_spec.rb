# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Grid::RedisState do
  let(:redis) { MockRedis.new }
  let(:bot) do
    bot = instance_double(
      Bot,
      id: 42,
      status: 'running',
      grid_levels: grid_levels,
      trades: trades_relation
    )
    bot
  end
  let(:trades_relation) do
    relation = double('trades_relation') # rubocop:disable RSpec/VerifiedDoubles
    allow(relation).to receive(:sum).with(:net_profit).and_return(BigDecimal('12.50'))
    relation
  end
  let(:grid_levels) do
    [
      instance_double(
        GridLevel,
        level_index: 0,
        expected_side: 'buy',
        status: 'active',
        price: BigDecimal('2500.00'),
        current_order_id: 'order-001',
        cycle_count: 0
      ),
      instance_double(
        GridLevel,
        level_index: 1,
        expected_side: 'sell',
        status: 'active',
        price: BigDecimal('2600.00'),
        current_order_id: 'order-002',
        cycle_count: 1
      )
    ]
  end

  subject(:state) { described_class.new(redis:) }

  before do
    stub_const(
      'MockRedis', Class.new do
                     def initialize
                       @store = {}
                     end

                     def set(key, value)
                       @store[key] = value.to_s
                     end

                     def get(key)
                       @store[key]
                     end

                     def hset(key, field, value)
                       @store[key] ||= {}
                       @store[key][field.to_s] = value.to_s
                     end

                     def hget(key, field)
                       @store.dig(key, field.to_s)
                     end

                     def hgetall(key)
                       @store[key] || {}
                     end

                     def hincrby(key, field, increment)
                       @store[key] ||= {}
                       current = (@store[key][field.to_s] || '0').to_i
                       @store[key][field.to_s] = (current + increment).to_s
                     end

                     def del(*keys)
                       keys.flatten.each { |k| @store.delete(k) }
                     end

                     def pipelined
                       yield self
                     end

                     def raw_store
                       @store
                     end
                   end
    )
  end

  describe '#seed' do
    before { state.seed(bot) }

    it 'sets bot status in Redis' do
      expect(redis.get('grid:42:status')).to eq('running')
    end

    it 'sets initial stats with zeroed counters and uptime_start' do
      stats = Oj.load(redis.get('grid:42:stats'))
      expect(stats['realized_profit']).to eq('0')
      expect(stats['trade_count']).to eq('0')
      expect(stats['uptime_start']).to be_present
    end

    it 'stores each grid level as a hash entry' do
      levels_hash = redis.hgetall('grid:42:levels')
      expect(levels_hash.keys).to contain_exactly('0', '1')
    end

    it 'serializes level data correctly' do
      level_data = Oj.load(redis.hget('grid:42:levels', '0'))
      expect(level_data).to include(
        'side' => 'buy',
        'status' => 'active',
        'price' => '2500.0',
        'order_id' => 'order-001',
        'cycle_count' => 0
      )
    end
  end

  describe '#update_on_fill' do
    let(:grid_level) do
      instance_double(
        GridLevel,
        level_index: 0,
        expected_side: 'sell',
        status: 'filled',
        price: BigDecimal('2500.00'),
        current_order_id: 'order-003',
        cycle_count: 1
      )
    end

    context 'without a trade' do
      before { state.update_on_fill(bot, grid_level) }

      it 'updates the level entry in Redis' do
        level_data = Oj.load(redis.hget('grid:42:levels', '0'))
        expect(level_data['status']).to eq('filled')
        expect(level_data['order_id']).to eq('order-003')
      end

      it 'does not update trade_count' do
        expect(redis.hget('grid:42:stats', 'trade_count')).to be_nil
      end
    end

    context 'with a trade' do
      let(:trade) { instance_double(Trade) }

      before { state.update_on_fill(bot, grid_level, trade) }

      it 'increments trade_count' do
        expect(redis.hget('grid:42:stats', 'trade_count')).to eq('1')
      end

      it 'updates realized_profit from bot trades sum' do
        expect(redis.hget('grid:42:stats', 'realized_profit')).to eq('12.5')
      end

      it 'updates the level entry' do
        level_data = Oj.load(redis.hget('grid:42:levels', '0'))
        expect(level_data['side']).to eq('sell')
      end
    end
  end

  describe '#update_price' do
    it 'sets the current price key' do
      state.update_price(42, BigDecimal('2550.75'))
      expect(BigDecimal(redis.get('grid:42:current_price'))).to eq(BigDecimal('2550.75'))
    end
  end

  describe '#update_status' do
    it 'sets the status key' do
      state.update_status(42, 'paused')
      expect(redis.get('grid:42:status')).to eq('paused')
    end
  end

  describe '#cleanup' do
    before do
      state.seed(bot)
      state.update_price(42, BigDecimal('2550'))
    end

    it 'removes all known keys for the bot' do
      state.cleanup(42)

      expect(redis.get('grid:42:status')).to be_nil
      expect(redis.get('grid:42:current_price')).to be_nil
      expect(redis.hgetall('grid:42:levels')).to be_empty
      expect(redis.get('grid:42:stats')).to be_nil
    end

    it 'does not raise for non-existent bot' do
      expect { state.cleanup(999) }.not_to raise_error
    end
  end

  describe 'PREFIX' do
    it 'uses "grid" as the key prefix' do
      expect(described_class::PREFIX).to eq('grid')
    end
  end

  describe 'KNOWN_SUFFIXES' do
    it 'includes all four key suffixes' do
      expect(described_class::KNOWN_SUFFIXES).to contain_exactly('status', 'current_price', 'levels', 'stats')
    end
  end
end
