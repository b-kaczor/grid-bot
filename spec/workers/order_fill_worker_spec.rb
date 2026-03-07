# frozen_string_literal: true

require 'rails_helper'

RSpec.describe OrderFillWorker do
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
  let(:redis_state) { instance_double(Grid::RedisState) }

  let(:buy_level) { create(:grid_level, bot:, level_index: 0, price: 2400, expected_side: 'buy', status: 'active') }
  let(:sell_level) { create(:grid_level, bot:, level_index: 1, price: 2500, expected_side: 'sell', status: 'active') }
  let(:top_level) { create(:grid_level, bot:, level_index: 2, price: 2600, expected_side: 'sell', status: 'active') }

  let(:buy_order) do
    create(
      :order, bot:, grid_level: buy_level, side: 'buy', price: 2400,
              quantity: 0.1, status: 'open', exchange_order_id: 'ex-buy-1',
              order_link_id: "g#{bot.id}-L0-B-0",
              avg_fill_price: 2400, filled_quantity: 0.1, net_quantity: 0.0999,
              fee: 0.0001, fee_coin: 'ETH'
    )
  end

  let(:sell_order) do
    create(
      :order, bot:, grid_level: sell_level, side: 'sell', price: 2500,
              quantity: 0.1, status: 'open', exchange_order_id: 'ex-sell-1',
              order_link_id: "g#{bot.id}-L1-S-0",
              paired_order_id: buy_order.id
    )
  end

  before do
    allow(Bybit::RestClient).to receive(:new).and_return(client)
    allow(Grid::RedisState).to receive(:new).and_return(redis_state)
    allow(redis_state).to receive(:update_on_fill)
    allow(redis_state).to receive(:read_stats).and_return({ 'realized_profit' => '10.5', 'trade_count' => '3' })
    allow(ActionCable.server).to receive(:broadcast)
  end

  subject(:worker) { described_class.new }

  def fill_data(order, extra = {})
    {
      orderId: order.exchange_order_id,
      orderLinkId: order.order_link_id,
      cumExecQty: '0.1',
      avgPrice: order.price.to_s,
      cumExecFee: '0.0001',
      feeCurrency: 'ETH',
      updatedTime: (Time.current.to_f * 1000).to_i.to_s,
    }.merge(extra)
  end

  describe '#perform' do
    context 'when a buy order fills' do
      before do
        buy_level
        sell_level
        buy_order

        allow(client).to receive(:place_order).and_return(
          Exchange::Response.new(success: true, data: { orderId: 'counter-sell-1' })
        )
      end

      it 'marks the buy order as filled' do
        worker.perform(Oj.dump(fill_data(buy_order)))
        expect(buy_order.reload.status).to eq('filled')
      end

      it 'places a sell counter-order at the next level' do
        worker.perform(Oj.dump(fill_data(buy_order)))
        expect(client).to have_received(:place_order).with(
          hash_including(side: 'Sell', price: '2500.0')
        )
      end

      it 'creates a sell Order record with paired_order_id' do
        worker.perform(Oj.dump(fill_data(buy_order)))
        counter = Order.find_by(exchange_order_id: 'counter-sell-1')
        expect(counter).to be_present
        expect(counter.side).to eq('sell')
        expect(counter.paired_order_id).to eq(buy_order.id)
      end

      it 'does not create a trade' do
        expect { worker.perform(Oj.dump(fill_data(buy_order))) }.not_to change(Trade, :count)
      end

      it 'updates Redis hot state' do
        worker.perform(Oj.dump(fill_data(buy_order)))
        expect(redis_state).to have_received(:update_on_fill).with(bot, buy_level, nil)
      end

      it 'broadcasts fill event via ActionCable' do
        worker.perform(Oj.dump(fill_data(buy_order)))
        expect(ActionCable.server).to have_received(:broadcast).with(
          "bot_#{bot.id}",
          hash_including(type: 'fill', trade: nil, realized_profit: '10.5', trade_count: 3)
        )
      end
    end

    context 'when a sell order fills' do
      before do
        buy_level
        sell_level
        buy_order
        sell_order

        allow(client).to receive(:place_order).and_return(
          Exchange::Response.new(success: true, data: { orderId: 'counter-buy-1' })
        )
      end

      it 'marks the sell order as filled' do
        worker.perform(Oj.dump(fill_data(sell_order)))
        expect(sell_order.reload.status).to eq('filled')
      end

      it 'places a buy counter-order at the previous level' do
        worker.perform(Oj.dump(fill_data(sell_order)))
        expect(client).to have_received(:place_order).with(
          hash_including(side: 'Buy', price: '2400.0')
        )
      end

      it 'creates a Trade record with correct profit' do
        worker.perform(Oj.dump(fill_data(sell_order)))
        trade = Trade.last
        expect(trade).to be_present
        expect(trade.buy_order).to eq(buy_order)
        expect(trade.sell_order).to eq(sell_order)
        expect(trade.net_profit).to be_present
      end

      it 'increments cycle_count on the sell level' do
        worker.perform(Oj.dump(fill_data(sell_order)))
        expect(sell_level.reload.cycle_count).to eq(1)
      end

      it 'updates Redis hot state with the trade' do
        worker.perform(Oj.dump(fill_data(sell_order)))
        expect(redis_state).to have_received(:update_on_fill) do |_bot, _level, trade|
          expect(trade).to be_a(Trade) if trade
        end
      end

      it 'broadcasts fill event with trade data via ActionCable' do
        worker.perform(Oj.dump(fill_data(sell_order)))
        expect(ActionCable.server).to have_received(:broadcast).with(
          "bot_#{bot.id}",
          hash_including(
            type: 'fill',
            trade: hash_including(:id, :buy_price, :sell_price, :net_profit),
            realized_profit: '10.5',
            trade_count: 3
          )
        )
      end
    end

    context 'with idempotency' do
      before do
        buy_level
        sell_level
        buy_order

        allow(client).to receive(:place_order).and_return(
          Exchange::Response.new(success: true, data: { orderId: 'counter-sell-1' })
        )
      end

      it 'skips already-filled orders' do
        worker.perform(Oj.dump(fill_data(buy_order)))
        expect { worker.perform(Oj.dump(fill_data(buy_order))) }.not_to change(Order, :count)
      end
    end

    context 'with fee in base coin (buy order)' do
      before do
        buy_level
        sell_level
        buy_order

        allow(client).to receive(:place_order).and_return(
          Exchange::Response.new(success: true, data: { orderId: 'counter-sell-2' })
        )
      end

      it 'calculates net_quantity as filled_quantity minus fee' do
        data = fill_data(buy_order, cumExecQty: '0.1', cumExecFee: '0.0001', feeCurrency: 'ETH')
        worker.perform(Oj.dump(data))
        expect(buy_order.reload.net_quantity).to eq(BigDecimal('0.0999'))
      end
    end

    context 'with fee in quote coin (sell order)' do
      before do
        buy_level
        sell_level
        buy_order
        sell_order

        allow(client).to receive(:place_order).and_return(
          Exchange::Response.new(success: true, data: { orderId: 'counter-buy-2' })
        )
      end

      it 'sets net_quantity equal to filled_quantity' do
        data = fill_data(sell_order, cumExecFee: '0.25', feeCurrency: 'USDT')
        worker.perform(Oj.dump(data))
        expect(sell_order.reload.net_quantity).to eq(BigDecimal('0.1'))
      end
    end

    context 'with rapid-fill race (order not found, matches pattern)' do
      it 're-enqueues with delay' do
        data = {
          orderId: 'unknown-id',
          orderLinkId: "g#{bot.id}-L5-B-0",
          cumExecQty: '0.1',
          avgPrice: '2500',
          cumExecFee: '0.0001',
          feeCurrency: 'ETH',
          updatedTime: (Time.current.to_f * 1000).to_i.to_s,
        }
        allow(described_class).to receive(:perform_in)
        worker.perform(Oj.dump(data), 0)
        expect(described_class).to have_received(:perform_in).with(5, anything, 1)
      end

      it 'logs error after max retries' do
        data = {
          orderId: 'unknown-id',
          orderLinkId: "g#{bot.id}-L5-B-0",
          cumExecQty: '0.1',
          avgPrice: '2500',
          cumExecFee: '0.0001',
          feeCurrency: 'ETH',
          updatedTime: (Time.current.to_f * 1000).to_i.to_s,
        }
        allow(described_class).to receive(:perform_in)
        allow(Rails.logger).to receive(:error)
        worker.perform(Oj.dump(data), 3)
        expect(described_class).not_to have_received(:perform_in)
        expect(Rails.logger).to have_received(:error).with(/not found after/)
      end
    end

    context 'when bot is stopping' do
      before do
        buy_level
        sell_level
        buy_order
        bot.update!(status: 'stopping')
        allow(client).to receive(:place_order)
      end

      it 'marks the order as filled but does not place a counter-order' do
        worker.perform(Oj.dump(fill_data(buy_order)))
        expect(buy_order.reload.status).to eq('filled')
        expect(client).not_to have_received(:place_order)
      end

      it 'does not create new orders' do
        expect { worker.perform(Oj.dump(fill_data(buy_order))) }.not_to change(Order, :count)
      end
    end

    context 'when bot is stopped' do
      before do
        buy_level
        sell_level
        buy_order
        bot.update!(status: 'stopped')
        allow(client).to receive(:place_order)
      end

      it 'marks the order as filled but does not place a counter-order' do
        worker.perform(Oj.dump(fill_data(buy_order)))
        expect(buy_order.reload.status).to eq('filled')
        expect(client).not_to have_received(:place_order)
      end
    end

    context 'with risk check after fill' do
      let(:risk_manager) { instance_double(Grid::RiskManager) }

      before do
        buy_level
        sell_level
        buy_order

        allow(client).to receive(:place_order).and_return(
          Exchange::Response.new(success: true, data: { orderId: 'counter-sell-1' })
        )
        allow(Grid::RiskManager).to receive(:new).and_return(risk_manager)
        allow(risk_manager).to receive(:check!).and_return(nil)
      end

      it 'calls RiskManager.check! with the fill price' do
        worker.perform(Oj.dump(fill_data(buy_order)))
        expect(Grid::RiskManager).to have_received(:new).with(bot, current_price: buy_order.price)
        expect(risk_manager).to have_received(:check!)
      end

      it 'does not interrupt fill processing when risk check raises' do
        allow(risk_manager).to receive(:check!).and_raise(StandardError, 'test error')
        allow(Rails.logger).to receive(:error)
        worker.perform(Oj.dump(fill_data(buy_order)))
        expect(buy_order.reload.status).to eq('filled')
        expect(Rails.logger).to have_received(:error).with(/Risk check failed/)
      end
    end

    context 'with boundary levels' do
      before do
        buy_level.update!(level_index: 0)
        buy_order.update!(grid_level: buy_level, order_link_id: "g#{bot.id}-L0-B-0")
      end

      it 'logs warning when no sell level above top level' do
        # Only level 0 exists — no level 1 to sell at
        GridLevel.where.not(id: buy_level.id).destroy_all
        allow(Rails.logger).to receive(:warn)
        allow(redis_state).to receive(:update_on_fill)
        worker.perform(Oj.dump(fill_data(buy_order)))
        expect(Rails.logger).to have_received(:warn).with(/No sell level/)
      end
    end
  end
end
