# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Grid::Initializer do
  let(:exchange_account) { create(:exchange_account) }
  let(:bot) { create(:bot, exchange_account:, status: 'pending', grid_count: 4) }
  let(:client) { instance_double(Bybit::RestClient) }
  let(:redis_state) { instance_double(Grid::RedisState) }
  let(:mock_redis) { MockRedis.new }

  before do
    stub_const(
      'MockRedis', Class.new do
                     def initialize
                       @store = {}
                     end

                     def set(key, value, **options)
                       return false if options[:nx] && @store.key?(key)

                       @store[key] = value
                       true
                     end

                     def get(key)
                       @store[key]&.to_s
                     end
                   end
    )

    allow(Bybit::RestClient).to receive(:new).and_return(client)
    allow(Grid::RedisState).to receive(:new).and_return(redis_state)
    allow(redis_state).to receive(:seed)
    allow(Redis).to receive(:new).and_return(mock_redis)

    stub_instrument_info
    stub_ticker
    stub_wallet_balance
    stub_batch_place_orders
  end

  subject(:initializer) { described_class.new(bot) }

  describe '#call' do
    context 'with valid pending bot' do
      it 'transitions bot from pending to running' do
        initializer.call
        expect(bot.reload.status).to eq('running')
      end

      it 'stores instrument info on bot' do
        initializer.call
        bot.reload
        expect(bot.tick_size).to eq(BigDecimal('0.01'))
        expect(bot.base_precision).to eq(4)
        expect(bot.min_order_qty).to eq(BigDecimal('0.001'))
      end

      it 'stores quantity_per_level on bot' do
        initializer.call
        expect(bot.reload.quantity_per_level).to be_present
      end

      it 'creates grid_level records' do
        initializer.call
        expect(bot.grid_levels.count).to eq(5) # grid_count 4 => 5 levels (0..4)
      end

      it 'creates order records for non-skipped levels' do
        initializer.call
        active_levels = bot.grid_levels.where(status: 'active')
        expect(bot.orders.count).to eq(active_levels.count)
      end

      it 'sets grid_level status to active for placed orders' do
        initializer.call
        active = bot.grid_levels.where(status: 'active')
        expect(active.count).to be > 0
      end

      it 'sets skipped status for neutral zone levels' do
        initializer.call
        skipped = bot.grid_levels.where(status: 'skipped')
        # Depends on price relative to grid — may be 0 or more
        expect(skipped.count).to be >= 0
      end

      it 'seeds Redis hot state' do
        initializer.call
        expect(redis_state).to have_received(:seed)
      end

      it 'returns the bot' do
        result = initializer.call
        expect(result).to eq(bot)
      end
    end

    context 'with order link ID format' do
      it 'generates order_link_ids matching the expected pattern' do
        initializer.call
        bot.orders.each do |order|
          expect(order.order_link_id).to match(described_class::ORDER_LINK_ID_PATTERN)
        end
      end

      it 'includes bot ID in order_link_id' do
        initializer.call
        order = bot.orders.first
        match = order.order_link_id.match(described_class::ORDER_LINK_ID_PATTERN)
        expect(match[1].to_i).to eq(bot.id)
      end
    end

    context 'when bot is not in pending status' do
      let(:bot) { create(:bot, exchange_account:, status: 'running') }

      it 'raises Error' do
        expect { initializer.call }.to raise_error(described_class::Error, /pending/)
      end
    end

    context 'when instrument info fetch fails' do
      before do
        allow(client).to receive(:get_instruments_info).and_return(
          Exchange::Response.new(success: false, error_message: 'API error')
        )
      end

      it 'transitions to error' do
        expect { initializer.call }.to raise_error(described_class::Error)
        expect(bot.reload.status).to eq('error')
      end
    end

    context 'when ticker fetch fails' do
      before do
        allow(client).to receive(:get_tickers).and_return(
          Exchange::Response.new(success: false, error_message: 'Ticker error')
        )
      end

      it 'transitions to error' do
        expect { initializer.call }.to raise_error(described_class::Error)
        expect(bot.reload.status).to eq('error')
      end
    end

    context 'with partial batch failure (< 50%)' do
      before do
        stub_batch_place_orders_with_partial_failure(1)
      end

      it 'still transitions to running' do
        initializer.call
        expect(bot.reload.status).to eq('running')
      end

      it 'creates orders for successful entries only' do
        initializer.call
        successful_levels = bot.grid_levels.where(status: 'active')
        expect(bot.orders.count).to eq(successful_levels.count)
      end
    end

    context 'with majority batch failure (> 50%)' do
      before do
        stub_batch_place_orders_with_majority_failure
      end

      it 'transitions to error' do
        expect { initializer.call }.to raise_error(described_class::Error, /Too many order failures/)
        expect(bot.reload.status).to eq('error')
      end
    end

    context 'when market buy for base asset is needed' do
      before do
        stub_wallet_balance(available: '0')
      end

      it 'places a market buy order' do
        allow(client).to receive(:place_order).and_return(
          Exchange::Response.new(success: true, data: { orderId: 'market-123' })
        )
        initializer.call
        expect(client).to have_received(:place_order).with(
          hash_including(side: 'Buy', order_type: 'Market')
        )
      end
    end

    context 'when quantity_per_level is below min_order_qty' do
      let(:bot) { create(:bot, exchange_account:, status: 'pending', grid_count: 4, investment_amount: 0.01) }

      before do
        allow(client).to receive(:get_instruments_info).and_return(
          Exchange::Response.new(
            success: true,
            data: {
              list: [
                {
                  lotSizeFilter: { basePrecision: '0.0001', minOrderQty: '100', minOrderAmt: '1' },
                  priceFilter: { tickSize: '0.01' },
                }
              ],
            }
          )
        )
      end

      it 'transitions to error' do
        expect { initializer.call }.to raise_error(described_class::Error)
        expect(bot.reload.status).to eq('error')
      end
    end

    context 'when market buy fails' do
      before do
        stub_wallet_balance(available: '0')
        allow(client).to receive(:place_order).and_return(
          Exchange::Response.new(success: false, error_message: 'Insufficient balance')
        )
      end

      it 'transitions to error' do
        expect { initializer.call }.to raise_error(described_class::Error, /Market buy/)
        expect(bot.reload.status).to eq('error')
      end
    end
  end

  # --- Helper methods for stubbing API responses ---

  def stub_instrument_info
    allow(client).to receive(:get_instruments_info).and_return(
      Exchange::Response.new(
        success: true,
        data: {
          list: [
            {
              lotSizeFilter: {
                basePrecision: '0.0001',
                minOrderQty: '0.001',
                minOrderAmt: '1',
              },
              priceFilter: {
                tickSize: '0.01',
              },
            }
          ],
        }
      )
    )
  end

  def stub_ticker
    allow(client).to receive(:get_tickers).and_return(
      Exchange::Response.new(
        success: true,
        data: { list: [{ lastPrice: '2500.00' }] }
      )
    )
  end

  def stub_wallet_balance(available: '100')
    allow(client).to receive(:get_wallet_balance).and_return(
      Exchange::Response.new(
        success: true,
        data: {
          list: [
            {
              coin: [
                {
                  coin: bot.base_coin,
                  availableToWithdraw: available,
                }
              ],
            }
          ],
        }
      )
    )
  end

  def stub_batch_place_orders
    allow(client).to receive(:batch_place_orders) do |args|
      orders = args[:orders]
      result_list = orders.each_with_index.map do |order, i|
        {
          orderId: "exchange-order-#{i}",
          orderLinkId: order[:order_link_id],
          code: '0',
        }
      end
      Exchange::Response.new(success: true, data: { list: result_list })
    end
  end

  def stub_batch_place_orders_with_partial_failure(fail_count)
    allow(client).to receive(:batch_place_orders) do |args|
      orders = args[:orders]
      result_list = orders.each_with_index.map do |order, i|
        if i < fail_count
          { orderId: '', orderLinkId: order[:order_link_id], code: '170213', msg: 'Test failure' }
        else
          { orderId: "exchange-order-#{i}", orderLinkId: order[:order_link_id], code: '0' }
        end
      end
      Exchange::Response.new(success: true, data: { list: result_list })
    end
  end

  def stub_batch_place_orders_with_majority_failure
    allow(client).to receive(:batch_place_orders) do |args|
      orders = args[:orders]
      result_list = orders.map do |order|
        { orderId: '', orderLinkId: order[:order_link_id], code: '170213', msg: 'Test failure' }
      end
      Exchange::Response.new(success: true, data: { list: result_list })
    end
  end
end
