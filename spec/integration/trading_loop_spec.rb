# frozen_string_literal: true

require 'rails_helper'

# Integration specs that test end-to-end trading flows with all services
# wired together. Only the exchange client (Bybit::RestClient) is mocked —
# everything else (OrderFillWorker, Grid::RedisState, models) is real.

RSpec.describe 'Trading Loop Integration', type: :integration do # rubocop:disable RSpec/DescribeClass
  let(:exchange_account) { create(:exchange_account) }
  let(:client) { instance_double(Bybit::RestClient) }

  let(:mock_redis) { MockRedis.new }
  let(:redis_state) { Grid::RedisState.new(redis: mock_redis) }
  let(:order_counter) { { value: 0 } }

  let(:instrument_response) do
    Exchange::Response.new(
      success: true,
      data: {
        list: [
          {
            lotSizeFilter: { basePrecision: '0.0001', minOrderQty: '0.001', minOrderAmt: '1' },
            priceFilter: { tickSize: '0.01' },
          }
        ],
      }
    )
  end

  let(:ok_response) { Exchange::Response.new(success: true, data: {}) }

  before do
    allow(Bybit::RestClient).to receive(:new).and_return(client)
    allow(Grid::RedisState).to receive(:new).and_return(redis_state)
    allow(Redis).to receive(:new).and_return(mock_redis)
    allow(ActionCable.server).to receive(:broadcast)
    allow(BalanceSnapshotWorker).to receive(:perform_async)

    stub_exchange_order_stubs
    stub_exchange_query_stubs
  end

  # --- Helpers ---

  def stub_exchange_order_stubs
    stub_batch_place_orders
    stub_single_place_order
  end

  def stub_batch_place_orders
    counter = order_counter
    allow(client).to receive(:batch_place_orders) do |args|
      result_list = args[:orders].map do |order|
        counter[:value] += 1
        { orderId: "ex-#{counter[:value]}", orderLinkId: order[:order_link_id], code: '0' }
      end
      Exchange::Response.new(success: true, data: { list: result_list })
    end
  end

  def stub_single_place_order
    counter = order_counter
    allow(client).to receive(:place_order) do |**_args|
      counter[:value] += 1
      Exchange::Response.new(success: true, data: { orderId: "ex-#{counter[:value]}" })
    end
  end

  def stub_exchange_query_stubs
    wallet = Exchange::Response.new(
      success: true,
      data: { list: [{ coin: [{ coin: 'ETH', availableToWithdraw: '10' }] }] }
    )
    allow(client).to receive_messages(
      get_instruments_info: instrument_response,
      get_tickers: Exchange::Response.new(
        success: true, data: { list: [{ lastPrice: '2500.00' }] }
      ),
      get_wallet_balance: wallet,
      set_dcp: ok_response,
      cancel_all_orders: ok_response,
      cancel_order: ok_response
    )
  end

  def fill_event(order, price: nil, fee: '0.0001', fee_coin: 'ETH')
    Oj.dump(
      {
        orderId: order.exchange_order_id,
        orderLinkId: order.order_link_id,
        cumExecQty: order.quantity.to_s,
        avgPrice: (price || order.price).to_s,
        cumExecFee: fee,
        feeCurrency: fee_coin,
        updatedTime: (Time.current.to_f * 1000).to_i.to_s,
      }
    )
  end

  def worker
    OrderFillWorker.new
  end

  def create_level(bot:, index:, price:, side:)
    create(
      :grid_level, bot:, level_index: index, price: price,
                   expected_side: side, status: 'active'
    )
  end

  # --- Tests ---

  describe 'full buy-sell-buy cycle' do
    let!(:bot) { create(:bot, exchange_account:, status: 'pending', grid_count: 4) }

    it 'initializes, fills a buy, places counter-sell, fills sell, records profit' do
      Grid::Initializer.new(bot).call
      bot.reload

      expect(bot.status).to eq('running')
      expect(bot.grid_levels.count).to eq(5)
      expect(bot.orders.where(status: 'open').count).to be > 0

      buy_order = bot.orders.joins(:grid_level)
        .where(side: 'buy', status: 'open')
        .where(grid_levels: { price: ...2500 })
        .first
      next unless buy_order

      buy_level = buy_order.grid_level
      sell_level = bot.grid_levels.find_by(level_index: buy_level.level_index + 1)
      next unless sell_level

      worker.perform(fill_event(buy_order, fee: '0.0001', fee_coin: 'ETH'))

      buy_order.reload
      expect(buy_order.status).to eq('filled')
      expect(buy_order.net_quantity).to eq(buy_order.filled_quantity - BigDecimal('0.0001'))

      counter_sell = bot.orders.where(side: 'sell', grid_level: sell_level, status: 'open').last
      expect(counter_sell).to be_present
      expect(counter_sell.paired_order_id).to eq(buy_order.id)

      worker.perform(fill_event(counter_sell, fee: '0.25', fee_coin: 'USDT'))
      expect(counter_sell.reload.status).to eq('filled')

      trade = Trade.last
      expect(trade).to be_present
      expect(trade.buy_order).to eq(buy_order)
      expect(trade.sell_order).to eq(counter_sell)
      expect(trade.net_profit).to be > 0

      counter_buy = bot.orders.where(side: 'buy', grid_level: buy_level, status: 'open').last
      expect(counter_buy).to be_present
      expect(sell_level.reload.cycle_count).to be > 0
    end
  end

  describe 'multiple cycles accumulate profit' do
    let!(:bot) do
      create(
        :bot, exchange_account:, status: 'running',
              quantity_per_level: BigDecimal('0.1'),
              base_precision: 4, base_coin: 'ETH', quote_coin: 'USDT'
      )
    end
    let!(:buy_level) { create_level(bot: bot, index: 0, price: 2400, side: 'buy') }
    let!(:sell_level) { create_level(bot: bot, index: 1, price: 2500, side: 'sell') }

    it 'completes 3 buy-sell cycles with cumulative profit' do
      redis_state.seed(bot)

      3.times do |cycle|
        if cycle.zero?
          buy_order = create(
            :order, bot:, grid_level: buy_level, side: 'buy', price: 2400,
                    quantity: BigDecimal('0.1'), status: 'open',
                    exchange_order_id: "buy-#{cycle}",
                    order_link_id: "g#{bot.id}-L0-B-#{cycle}"
          )
          buy_level.update!(status: 'active', current_order_id: buy_order.exchange_order_id)
        else
          buy_order = bot.orders.where(
            side: 'buy', status: 'open', grid_level: buy_level
          ).order(:id).last
          expect(buy_order).to be_present
        end

        worker.perform(fill_event(buy_order))
        expect(buy_order.reload.status).to eq('filled')

        counter_sell = bot.orders.where(side: 'sell', status: 'open').order(:id).last
        expect(counter_sell).to be_present

        worker.perform(fill_event(counter_sell, fee: '0.25', fee_coin: 'USDT'))
        expect(counter_sell.reload.status).to eq('filled')
      end

      expect(bot.trades.count).to eq(3)
      bot.trades.each { |t| expect(t.net_profit).to be > 0 }
      expect(bot.trades.sum(:net_profit)).to be > 0

      stats = redis_state.read_stats(bot.id)
      expect(stats['trade_count'].to_i).to eq(3)
    end
  end

  describe 'idempotent fill processing' do
    let!(:bot) do
      create(
        :bot, exchange_account:, status: 'running',
              quantity_per_level: BigDecimal('0.1'),
              base_precision: 4, base_coin: 'ETH', quote_coin: 'USDT'
      )
    end
    let!(:buy_level) { create_level(bot: bot, index: 0, price: 2400, side: 'buy') }
    let!(:sell_level) { create_level(bot: bot, index: 1, price: 2500, side: 'sell') }
    let!(:buy_order) do
      create(
        :order, bot:, grid_level: buy_level, side: 'buy', price: 2400,
                quantity: BigDecimal('0.1'), status: 'open',
                exchange_order_id: 'dup-buy-1', order_link_id: "g#{bot.id}-L0-B-0"
      )
    end

    it 'processes duplicate fill messages exactly once' do
      redis_state.seed(bot)
      fill = fill_event(buy_order)

      worker.perform(fill)
      expect(buy_order.reload.status).to eq('filled')
      orders_after_first = bot.orders.count

      worker.perform(fill)
      expect(bot.orders.count).to eq(orders_after_first)
    end
  end

  describe 'fee-adjusted quantities prevent base asset leakage' do
    let!(:bot) do
      create(
        :bot, exchange_account:, status: 'running',
              quantity_per_level: BigDecimal('1.0'),
              base_precision: 4, base_coin: 'ETH', quote_coin: 'USDT'
      )
    end
    let!(:buy_level) { create_level(bot: bot, index: 0, price: 2400, side: 'buy') }
    let!(:sell_level) { create_level(bot: bot, index: 1, price: 2500, side: 'sell') }
    let!(:buy_order) do
      create(
        :order, bot:, grid_level: buy_level, side: 'buy', price: 2400,
                quantity: BigDecimal('1.0'), status: 'open',
                exchange_order_id: 'fee-buy-1', order_link_id: "g#{bot.id}-L0-B-0"
      )
    end

    it 'sell counter-order uses net_quantity (not filled_quantity)' do
      redis_state.seed(bot)

      worker.perform(fill_event(buy_order, fee: '0.001', fee_coin: 'ETH'))

      buy_order.reload
      expect(buy_order.net_quantity).to eq(BigDecimal('0.999'))

      counter_sell = bot.orders.where(side: 'sell', status: 'open').last
      expect(counter_sell).to be_present
      expect(counter_sell.quantity).to eq(BigDecimal('0.999'))
    end
  end

  describe 'stop-loss triggers emergency exit' do
    let!(:bot) do
      create(
        :bot, exchange_account:, status: 'running',
              quantity_per_level: BigDecimal('0.1'),
              base_precision: 4, base_coin: 'ETH', quote_coin: 'USDT',
              lower_price: 2400, upper_price: 2600,
              stop_loss_price: BigDecimal('2300')
      )
    end
    let!(:buy_level) { create_level(bot: bot, index: 0, price: 2400, side: 'buy') }
    let!(:buy_order) do
      create(
        :order, bot:, grid_level: buy_level, side: 'buy', price: 2400,
                quantity: BigDecimal('0.1'), status: 'open',
                exchange_order_id: 'sl-buy-1', order_link_id: "g#{bot.id}-L0-B-0"
      )
    end

    it 'stops bot when fill price hits stop-loss' do
      redis_state.seed(bot)
      worker.perform(fill_event(buy_order, price: '2200'))

      expect(buy_order.reload.status).to eq('filled')

      bot.reload
      expect(bot.status).to eq('stopped')
      expect(bot.stop_reason).to eq('stop_loss')
      expect(bot.orders.where(status: 'open').count).to eq(0)

      expect(client).to have_received(:cancel_all_orders).with(
        hash_including(symbol: 'ETHUSDT', emergency: true)
      )
      expect(client).to have_received(:place_order).with(
        hash_including(side: 'Sell', order_type: 'Market', emergency: true)
      )
    end
  end

  describe 'take-profit triggers emergency exit' do
    let!(:bot) do
      create(
        :bot, exchange_account:, status: 'running',
              quantity_per_level: BigDecimal('0.1'),
              base_precision: 4, base_coin: 'ETH', quote_coin: 'USDT',
              lower_price: 2400, upper_price: 2600,
              take_profit_price: BigDecimal('2700')
      )
    end
    let!(:buy_level) { create_level(bot: bot, index: 0, price: 2400, side: 'buy') }
    let!(:sell_level) { create_level(bot: bot, index: 1, price: 2600, side: 'sell') }
    let!(:sell_order) do
      buy = create(
        :order, bot:, grid_level: buy_level, side: 'buy', price: 2400,
                quantity: BigDecimal('0.1'), status: 'filled',
                exchange_order_id: 'tp-buy', order_link_id: "g#{bot.id}-L0-B-0",
                filled_quantity: BigDecimal('0.1'), net_quantity: BigDecimal('0.0999'),
                avg_fill_price: 2400, fee: BigDecimal('0.0001'), fee_coin: 'ETH'
      )
      create(
        :order, bot:, grid_level: sell_level, side: 'sell', price: 2600,
                quantity: BigDecimal('0.1'), status: 'open',
                exchange_order_id: 'tp-sell', order_link_id: "g#{bot.id}-L1-S-0",
                paired_order_id: buy.id
      )
    end

    it 'stops bot when fill price hits take-profit' do
      redis_state.seed(bot)

      worker.perform(
        fill_event(sell_order, price: '2800', fee: '0.25', fee_coin: 'USDT')
      )

      bot.reload
      expect(bot.status).to eq('stopped')
      expect(bot.stop_reason).to eq('take_profit')
    end
  end

  describe 'concurrent risk manager calls are race-safe' do
    let!(:bot) do
      create(
        :bot, exchange_account:, status: 'running',
              quantity_per_level: BigDecimal('0.1'),
              base_precision: 4, base_coin: 'ETH', quote_coin: 'USDT',
              lower_price: 2200, upper_price: 2600,
              stop_loss_price: BigDecimal('2000')
      )
    end

    it 'only one caller executes the emergency stop' do
      redis_state.seed(bot)

      rm_first = Grid::RiskManager.new(bot, current_price: '1900')
      rm_second = Grid::RiskManager.new(bot, current_price: '1900')

      results = [rm_first.check!, rm_second.check!]

      expect(results.compact.count).to eq(1)
      expect(client).to have_received(:cancel_all_orders).once
    end
  end

  describe 'bot with no risk settings runs normally' do
    let!(:bot) do
      create(
        :bot, exchange_account:, status: 'running',
              quantity_per_level: BigDecimal('0.1'),
              base_precision: 4, base_coin: 'ETH', quote_coin: 'USDT',
              stop_loss_price: nil, take_profit_price: nil
      )
    end
    let!(:buy_level) { create_level(bot: bot, index: 0, price: 2400, side: 'buy') }
    let!(:sell_level) { create_level(bot: bot, index: 1, price: 2500, side: 'sell') }
    let!(:buy_order) do
      create(
        :order, bot:, grid_level: buy_level, side: 'buy', price: 2400,
                quantity: BigDecimal('0.1'), status: 'open',
                exchange_order_id: 'no-risk-buy', order_link_id: "g#{bot.id}-L0-B-0"
      )
    end

    it 'processes fills without triggering any risk actions' do
      redis_state.seed(bot)

      worker.perform(fill_event(buy_order))

      bot.reload
      expect(bot.status).to eq('running')
      expect(client).not_to have_received(:cancel_all_orders)
    end
  end

  describe 'stopping bot does not place counter-orders' do
    let!(:bot) do
      create(
        :bot, exchange_account:, status: 'running',
              quantity_per_level: BigDecimal('0.1'),
              base_precision: 4, base_coin: 'ETH', quote_coin: 'USDT'
      )
    end
    let!(:buy_level) { create_level(bot: bot, index: 0, price: 2400, side: 'buy') }
    let!(:sell_level) { create_level(bot: bot, index: 1, price: 2500, side: 'sell') }
    let!(:buy_order) do
      create(
        :order, bot:, grid_level: buy_level, side: 'buy', price: 2400,
                quantity: BigDecimal('0.1'), status: 'open',
                exchange_order_id: 'stop-buy', order_link_id: "g#{bot.id}-L0-B-0"
      )
    end

    it 'marks order as filled but skips counter-order when bot is stopping' do
      redis_state.seed(bot)
      bot.update!(status: 'stopping')

      initial_order_count = bot.orders.count
      worker.perform(fill_event(buy_order))

      buy_order.reload
      expect(buy_order.status).to eq('filled')
      expect(bot.orders.count).to eq(initial_order_count)
    end
  end
end
