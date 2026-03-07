# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GridReconciliationWorker do
  let(:exchange_account) { create(:exchange_account) }
  let(:bot) do
    create(
      :bot,
      exchange_account:,
      status: 'running',
      quantity_per_level: BigDecimal('0.1'),
      base_precision: 4,
      base_coin: 'ETH',
      quote_coin: 'USDT'
    )
  end
  let(:client) { instance_double(Bybit::RestClient) }
  let(:redis) { Redis.new(url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0')) }

  let(:buy_level) do
    create(
      :grid_level, bot:, level_index: 0, price: 2400,
                   expected_side: 'buy', status: 'active',
                   current_order_id: 'ex-0',
                   current_order_link_id: "g#{bot.id}-L0-B-0"
    )
  end
  let(:sell_level) do
    create(
      :grid_level, bot:, level_index: 1, price: 2500,
                   expected_side: 'sell', status: 'active',
                   current_order_id: 'ex-1',
                   current_order_link_id: "g#{bot.id}-L1-S-0"
    )
  end
  let(:top_level) do
    create(
      :grid_level, bot:, level_index: 2, price: 2600,
                   expected_side: 'sell', status: 'active',
                   current_order_id: 'ex-2',
                   current_order_link_id: "g#{bot.id}-L2-S-0"
    )
  end

  let(:buy_order) do
    create(
      :order, bot:, grid_level: buy_level, side: 'buy', price: 2400,
              quantity: 0.1, status: 'open', exchange_order_id: 'ex-0',
              order_link_id: "g#{bot.id}-L0-B-0"
    )
  end
  let(:sell_order) do
    create(
      :order, bot:, grid_level: sell_level, side: 'sell', price: 2500,
              quantity: 0.1, status: 'open', exchange_order_id: 'ex-1',
              order_link_id: "g#{bot.id}-L1-S-0"
    )
  end
  let(:top_order) do
    create(
      :order, bot:, grid_level: top_level, side: 'sell', price: 2600,
              quantity: 0.1, status: 'open', exchange_order_id: 'ex-2',
              order_link_id: "g#{bot.id}-L2-S-0"
    )
  end

  let(:empty_open_orders) do
    Exchange::Response.new(success: true, data: { list: [], nextPageCursor: nil })
  end
  let(:success_place_response) do
    Exchange::Response.new(success: true, data: { orderId: 'new-order-123' })
  end
  let(:success_cancel_response) do
    Exchange::Response.new(success: true, data: {})
  end

  subject(:worker) { described_class.new }

  before do
    allow(Bybit::RestClient).to receive(:new).and_return(client)
    allow(client).to receive_messages(
      get_open_orders: empty_open_orders,
      get_order_history: Exchange::Response.new(success: true, data: { list: [] }),
      place_order: success_place_response,
      cancel_order: success_cancel_response
    )

    redis.del('grid:reconciliation:scheduled')
  end

  after do
    redis.del('grid:reconciliation:scheduled')
    Grid::RedisState::KNOWN_SUFFIXES.each { |s| redis.del("grid:#{bot.id}:#{s}") }
  end

  def exchange_order(attrs = {})
    {
      orderId: 'ex-0',
      orderLinkId: "g#{bot.id}-L0-B-0",
      side: 'Buy',
      price: '2400.00',
      qty: '0.1',
      orderStatus: 'New',
      cumExecQty: '0',
      avgPrice: '0',
      cumExecFee: '0',
      feeCurrency: 'USDT',
      updatedTime: (Time.current.to_f * 1000).to_i.to_s,
    }.merge(attrs)
  end

  describe '#perform' do
    context 'with scheduled mode (nil bot_id)' do
      it 'reconciles all running bots' do
        buy_level
        buy_order

        open_orders = Exchange::Response.new(
          success: true,
          data: { list: [exchange_order], nextPageCursor: nil }
        )
        allow(client).to receive(:get_open_orders).and_return(open_orders)

        worker.perform(nil)
      end

      it 'skips non-running bots' do
        paused_bot = create(:bot, exchange_account:, status: 'paused')
        create(
          :grid_level, bot: paused_bot, level_index: 0, price: 2400,
                       expected_side: 'buy', status: 'active'
        )

        worker.perform(nil)
        expect(client).not_to have_received(:get_open_orders)
      end

      it 'schedules next run via Redis mutex' do
        bot
        allow(described_class).to receive(:perform_in)
        worker.perform(nil)
        expect(described_class).to have_received(:perform_in).with(15, nil)
      end
    end

    context 'with on-demand mode (specific bot_id)' do
      it 'reconciles only the specified bot' do
        buy_level
        buy_order

        open_orders = Exchange::Response.new(
          success: true,
          data: { list: [exchange_order], nextPageCursor: nil }
        )
        allow(client).to receive(:get_open_orders).and_return(open_orders)

        worker.perform(bot.id)
      end

      it 'does not schedule next run' do
        allow(described_class).to receive(:perform_in)
        buy_level
        buy_order

        open_orders = Exchange::Response.new(
          success: true,
          data: { list: [exchange_order], nextPageCursor: nil }
        )
        allow(client).to receive(:get_open_orders).and_return(open_orders)

        worker.perform(bot.id)
        expect(described_class).not_to have_received(:perform_in)
      end
    end

    context 'when bot status changes to stopped before reconciliation' do
      it 'skips reconciliation for stopped bot' do
        buy_level
        buy_order
        bot.update!(status: 'stopped')

        worker.perform(bot.id)
        expect(client).not_to have_received(:get_open_orders)
      end
    end
  end

  describe 'missing order detection' do
    context 'when order was filled on exchange' do
      before do
        buy_level
        buy_order

        allow(client).to receive(:get_order_history).and_return(
          Exchange::Response.new(
            success: true,
            data: {
              list: [
                {
                  orderId: 'ex-0',
                  orderLinkId: buy_order.order_link_id,
                  orderStatus: 'Filled',
                  side: 'Buy',
                  cumExecQty: '0.1',
                  avgPrice: '2400.00',
                  cumExecFee: '0.0001',
                  feeCurrency: 'ETH',
                  updatedTime: (Time.current.to_f * 1000).to_i.to_s,
                }
              ],
            }
          )
        )
      end

      it 'enqueues OrderFillWorker with fill data' do
        allow(OrderFillWorker).to receive(:perform_async)
        worker.perform(bot.id)
        expect(OrderFillWorker).to have_received(:perform_async).with(anything)
      end
    end

    context 'when order was cancelled on exchange' do
      before do
        buy_level
        buy_order

        allow(client).to receive(:get_order_history).and_return(
          Exchange::Response.new(
            success: true,
            data: {
              list: [
                {
                  orderId: 'ex-0',
                  orderLinkId: buy_order.order_link_id,
                  orderStatus: 'Cancelled',
                }
              ],
            }
          )
        )
      end

      it 'marks local order as cancelled' do
        worker.perform(bot.id)
        expect(buy_order.reload.status).to eq('cancelled')
      end
    end

    context 'when order not found in history' do
      before do
        buy_level
        buy_order

        allow(client).to receive(:get_order_history).and_return(
          Exchange::Response.new(success: true, data: { list: [] })
        )
      end

      it 'marks local order as cancelled' do
        worker.perform(bot.id)
        expect(buy_order.reload.status).to eq('cancelled')
      end
    end
  end

  describe 'orphan handling' do
    context 'when orphan matches our pattern and bot' do
      before do
        sell_level
      end

      it 'adopts the orphan order' do
        orphan_data = exchange_order(
          orderId: 'orphan-123',
          orderLinkId: "g#{bot.id}-L1-S-1",
          side: 'Sell',
          price: '2500.00',
          qty: '0.1',
          orderStatus: 'New'
        )

        allow(client).to receive(:get_open_orders).and_return(
          Exchange::Response.new(
            success: true,
            data: { list: [orphan_data], nextPageCursor: nil }
          )
        )

        worker.perform(bot.id)

        adopted = Order.find_by(exchange_order_id: 'orphan-123')
        expect(adopted).to be_present
        expect(adopted.status).to eq('open')
        expect(adopted.side).to eq('sell')
        expect(adopted.grid_level).to eq(sell_level)
        expect(sell_level.reload.current_order_id).to eq('orphan-123')
        expect(sell_level.status).to eq('active')
      end
    end

    context 'when orphan does not match our pattern' do
      before do
        buy_level
        buy_order
      end

      it 'cancels the foreign order' do
        foreign_data = exchange_order(
          orderId: 'foreign-999',
          orderLinkId: 'manual-trade',
          side: 'Buy',
          price: '2400.00'
        )

        known_data = exchange_order(
          orderId: 'ex-0',
          orderLinkId: buy_order.order_link_id
        )
        allow(client).to receive(:get_open_orders).and_return(
          Exchange::Response.new(
            success: true,
            data: { list: [known_data, foreign_data], nextPageCursor: nil }
          )
        )

        worker.perform(bot.id)

        expect(client).to have_received(:cancel_order).with(
          hash_including(order_id: 'foreign-999')
        )
        expect(Order.find_by(exchange_order_id: 'foreign-999')).to be_nil
      end
    end
  end

  describe 'grid gap detection and repair' do
    context 'when a level has no active order' do
      before do
        buy_level.update!(
          status: 'filled', current_order_id: nil, current_order_link_id: nil
        )
      end

      it 'places a new order to fill the gap' do
        worker.perform(bot.id)

        expect(client).to have_received(:place_order).with(
          hash_including(
            side: 'Buy',
            price: '2400.0',
            symbol: 'ETHUSDT'
          )
        )
      end

      it 'creates an Order record for the gap repair' do
        expect { worker.perform(bot.id) }.to change(Order, :count).by(1)

        new_order = Order.last
        expect(new_order.side).to eq('buy')
        expect(new_order.grid_level).to eq(buy_level)
        expect(new_order.status).to eq('open')
      end

      it 'updates the grid level to active' do
        worker.perform(bot.id)
        expect(buy_level.reload.status).to eq('active')
        expect(buy_level.current_order_id).to eq('new-order-123')
      end

      it 'increments cycle_count' do
        worker.perform(bot.id)
        expect(buy_level.reload.cycle_count).to eq(1)
      end
    end

    context 'when level expects a sell order' do
      before do
        sell_level.update!(
          status: 'filled', current_order_id: nil, current_order_link_id: nil
        )
      end

      it 'places a sell order' do
        worker.perform(bot.id)

        expect(client).to have_received(:place_order).with(
          hash_including(side: 'Sell', price: '2500.0')
        )
      end
    end

    context 'when bot is stopped before gap repair' do
      before do
        buy_level.update!(status: 'filled', current_order_id: nil)
      end

      it 'does not repair gaps' do
        allow(client).to receive(:get_open_orders) do
          bot.update!(status: 'stopped')
          empty_open_orders
        end

        worker.perform(bot.id)
        expect(client).not_to have_received(:place_order)
      end
    end

    context 'when level is skipped' do
      before do
        buy_level.update!(status: 'skipped', current_order_id: nil)
      end

      it 'does not attempt to repair skipped levels' do
        worker.perform(bot.id)
        expect(client).not_to have_received(:place_order)
      end
    end
  end

  describe 'pagination' do
    it 'fetches all pages of open orders' do
      buy_level
      buy_order

      page1_order = exchange_order(
        orderId: 'ex-0', orderLinkId: buy_order.order_link_id
      )
      page2_order = exchange_order(
        orderId: 'ex-page2', orderLinkId: "g#{bot.id}-L0-B-99"
      )

      page1 = Exchange::Response.new(
        success: true,
        data: { list: [page1_order], nextPageCursor: 'cursor123' }
      )
      page2 = Exchange::Response.new(
        success: true,
        data: { list: [page2_order], nextPageCursor: nil }
      )

      call_count = 0
      allow(client).to receive(:get_open_orders) do |**_args|
        call_count += 1
        call_count == 1 ? page1 : page2
      end

      worker.perform(bot.id)
      expect(client).to have_received(:get_open_orders).twice
    end
  end

  describe 'partial fill handling' do
    context 'when order is partially filled > 10 min with >= 95% fill' do
      before { buy_level }

      let!(:partial_order) do
        create(
          :order, bot:, grid_level: buy_level, side: 'buy', price: 2400,
                  quantity: BigDecimal('0.1'), status: 'open',
                  exchange_order_id: 'ex-partial',
                  order_link_id: "g#{bot.id}-L0-B-0",
                  placed_at: 11.minutes.ago
        )
      end

      it 'cancels the order and enqueues fill processing' do
        partial_data = exchange_order(
          orderId: 'ex-partial',
          orderLinkId: partial_order.order_link_id,
          orderStatus: 'PartiallyFilled',
          cumExecQty: '0.097',
          qty: '0.1',
          avgPrice: '2400.00',
          cumExecFee: '0.0001',
          feeCurrency: 'ETH'
        )

        allow(client).to receive(:get_open_orders).and_return(
          Exchange::Response.new(
            success: true,
            data: { list: [partial_data], nextPageCursor: nil }
          )
        )
        allow(OrderFillWorker).to receive(:perform_async)

        worker.perform(bot.id)

        expect(client).to have_received(:cancel_order).with(
          hash_including(order_id: 'ex-partial')
        )
        expect(OrderFillWorker).to have_received(:perform_async).with(anything)
      end
    end

    context 'when partial fill is < 95%' do
      before { buy_level }

      let!(:partial_order) do
        create(
          :order, bot:, grid_level: buy_level, side: 'buy', price: 2400,
                  quantity: BigDecimal('0.1'), status: 'open',
                  exchange_order_id: 'ex-partial-low',
                  order_link_id: "g#{bot.id}-L0-B-0",
                  placed_at: 11.minutes.ago
        )
      end

      it 'does not cancel the order' do
        partial_data = exchange_order(
          orderId: 'ex-partial-low',
          orderLinkId: partial_order.order_link_id,
          orderStatus: 'PartiallyFilled',
          cumExecQty: '0.05',
          qty: '0.1'
        )

        allow(client).to receive(:get_open_orders).and_return(
          Exchange::Response.new(
            success: true,
            data: { list: [partial_data], nextPageCursor: nil }
          )
        )

        worker.perform(bot.id)

        expect(client).not_to have_received(:cancel_order)
      end
    end

    context 'when partial fill is recent (< 10 min)' do
      before { buy_level }

      let!(:recent_partial) do
        create(
          :order, bot:, grid_level: buy_level, side: 'buy', price: 2400,
                  quantity: BigDecimal('0.1'), status: 'open',
                  exchange_order_id: 'ex-recent',
                  order_link_id: "g#{bot.id}-L0-B-0",
                  placed_at: 5.minutes.ago
        )
      end

      it 'does not cancel the order' do
        partial_data = exchange_order(
          orderId: 'ex-recent',
          orderLinkId: recent_partial.order_link_id,
          orderStatus: 'PartiallyFilled',
          cumExecQty: '0.097',
          qty: '0.1'
        )

        allow(client).to receive(:get_open_orders).and_return(
          Exchange::Response.new(
            success: true,
            data: { list: [partial_data], nextPageCursor: nil }
          )
        )

        worker.perform(bot.id)

        expect(client).not_to have_received(:cancel_order)
      end
    end
  end

  describe 'Redis hot state refresh' do
    it 'refreshes Redis state after reconciliation' do
      buy_level
      buy_order

      open_orders = Exchange::Response.new(
        success: true,
        data: { list: [exchange_order], nextPageCursor: nil }
      )
      allow(client).to receive(:get_open_orders).and_return(open_orders)

      worker.perform(bot.id)

      level_data = redis.hget("grid:#{bot.id}:levels", '0')
      expect(level_data).to be_present

      parsed = Oj.load(level_data, symbol_keys: true)
      expect(parsed[:status]).to eq('active')
    end
  end

  describe 'Redis mutex for self-scheduling' do
    it 'only schedules once when mutex is held' do
      bot
      allow(described_class).to receive(:perform_in)

      worker.perform(nil)
      expect(described_class).to have_received(:perform_in).once
    end

    it 'does not schedule if mutex is already held' do
      allow(described_class).to receive(:perform_in)
      redis.set(
        'grid:reconciliation:scheduled', Time.current.to_i, nx: true, ex: 30
      )

      worker.perform(nil)
      expect(described_class).not_to have_received(:perform_in)
    end

    it 'does not schedule if no running bots exist' do
      allow(described_class).to receive(:perform_in)
      bot.update!(status: 'stopped')

      worker.perform(nil)
      expect(described_class).not_to have_received(:perform_in)
    end
  end

  describe 'error handling' do
    it 'continues processing other bots when one fails' do
      create(
        :bot, exchange_account:, status: 'running',
              quantity_per_level: BigDecimal('0.1')
      )

      allow(client).to receive(:get_open_orders)
        .and_raise(StandardError, 'API error')

      expect { worker.perform(nil) }.not_to raise_error
    end
  end
end
