# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Grid::TrailingManager do
  let(:exchange_account) { create(:exchange_account) }
  let(:bot) do
    create(
      :bot,
      exchange_account:,
      status: 'running',
      lower_price: BigDecimal('2000'),
      upper_price: BigDecimal('3000'),
      grid_count: 5,
      spacing_type: 'arithmetic',
      quantity_per_level: BigDecimal('0.1'),
      trailing_up_enabled: true,
      tick_size: BigDecimal('0.01')
    )
  end
  let(:client) { instance_double(Bybit::RestClient) }
  let(:redis_state) { instance_double(Grid::RedisState) }

  let!(:bottom_level) do
    create(
      :grid_level, bot:, level_index: 0, price: BigDecimal('2000'),
                   expected_side: 'buy', status: 'active',
                   current_order_id: 'ord-0'
    )
  end
  let!(:second_level) do
    create(
      :grid_level, bot:, level_index: 1, price: BigDecimal('2200'),
                   expected_side: 'buy', status: 'active',
                   current_order_id: 'ord-1'
    )
  end
  let!(:mid_level) do
    create(
      :grid_level, bot:, level_index: 2, price: BigDecimal('2400'),
                   expected_side: 'sell', status: 'active',
                   current_order_id: 'ord-2'
    )
  end
  let!(:fourth_level) do
    create(
      :grid_level, bot:, level_index: 3, price: BigDecimal('2600'),
                   expected_side: 'sell', status: 'active',
                   current_order_id: 'ord-3'
    )
  end
  let!(:top_level) do
    create(
      :grid_level, bot:, level_index: 4, price: BigDecimal('3000'),
                   expected_side: 'sell', status: 'filled',
                   current_order_id: 'ord-4'
    )
  end

  let!(:lowest_order) do
    create(
      :order, bot:, grid_level: bottom_level, status: 'open',
              side: 'buy', price: BigDecimal('2000')
    )
  end

  let(:success_response) { Exchange::Response.new(success: true, data: {}) }
  let(:place_order_response) do
    Exchange::Response.new(success: true, data: { orderId: 'new-ord-5' })
  end

  before do
    allow(Grid::RedisState).to receive(:new).and_return(redis_state)
    allow(redis_state).to receive(:seed)
    allow(client).to receive_messages(cancel_order: success_response, place_order: place_order_response)
  end

  subject(:manager) { described_class.new(bot, filled_level: top_level, client:) }

  describe '#maybe_trail!' do
    context 'when trailing is applicable (top sell filled, trailing enabled)' do
      it 'returns true' do
        expect(manager.maybe_trail!).to be true
      end

      it 'cancels the lowest buy order on exchange' do
        manager.maybe_trail!
        expect(client).to have_received(:cancel_order).with(
          symbol: 'ETHUSDT', order_id: 'ord-0'
        )
      end

      it 'places a new sell at the new top price' do
        manager.maybe_trail!
        expect(client).to have_received(:place_order).with(
          symbol: 'ETHUSDT',
          side: 'Sell',
          order_type: 'Limit',
          qty: '0.1',
          price: '3200.0',
          order_link_id: "g#{bot.id}-L5-S-0"
        )
      end

      it 'destroys the lowest level' do
        manager.maybe_trail!
        expect(GridLevel.find_by(id: bottom_level.id)).to be_nil
      end

      it 're-indexes remaining levels (shifted down by 1)' do
        manager.maybe_trail!
        expect(second_level.reload.level_index).to eq(0)
        expect(mid_level.reload.level_index).to eq(1)
        expect(fourth_level.reload.level_index).to eq(2)
        expect(top_level.reload.level_index).to eq(3)
      end

      it 'creates a new top GridLevel' do
        manager.maybe_trail!
        new_level = bot.grid_levels.reload.order(:level_index).last
        expect(new_level.price).to eq(BigDecimal('3200'))
        expect(new_level.expected_side).to eq('sell')
        expect(new_level.status).to eq('active')
        expect(new_level.current_order_id).to eq('new-ord-5')
      end

      it 'creates a new Order for the top level' do
        manager.maybe_trail!
        new_level = bot.grid_levels.reload.order(:level_index).last
        new_order = new_level.orders.last
        expect(new_order.side).to eq('sell')
        expect(new_order.price).to eq(BigDecimal('3200'))
        expect(new_order.status).to eq('open')
        expect(new_order.exchange_order_id).to eq('new-ord-5')
      end

      it 'destroys the old lowest buy order with its level' do
        manager.maybe_trail!
        expect(Order.find_by(id: lowest_order.id)).to be_nil
      end

      it 'updates bot price boundaries' do
        manager.maybe_trail!
        bot.reload
        expect(bot.lower_price).to eq(second_level.price)
        expect(bot.upper_price).to eq(BigDecimal('3200'))
      end

      it 'reseeds Redis' do
        manager.maybe_trail!
        expect(redis_state).to have_received(:seed)
      end
    end

    context 'when trailing_up_enabled is false' do
      let(:bot) do
        create(
          :bot,
          exchange_account:,
          status: 'running',
          lower_price: BigDecimal('2000'),
          upper_price: BigDecimal('3000'),
          grid_count: 5,
          spacing_type: 'arithmetic',
          quantity_per_level: BigDecimal('0.1'),
          trailing_up_enabled: false,
          tick_size: BigDecimal('0.01')
        )
      end

      it 'returns false' do
        expect(manager.maybe_trail!).to be false
      end

      it 'does not call exchange' do
        manager.maybe_trail!
        expect(client).not_to have_received(:cancel_order)
        expect(client).not_to have_received(:place_order)
      end
    end

    context 'when bot is not running' do
      let(:bot) do
        create(
          :bot,
          exchange_account:,
          status: 'stopping',
          lower_price: BigDecimal('2000'),
          upper_price: BigDecimal('3000'),
          grid_count: 5,
          spacing_type: 'arithmetic',
          quantity_per_level: BigDecimal('0.1'),
          trailing_up_enabled: true,
          tick_size: BigDecimal('0.01')
        )
      end

      it 'returns false' do
        expect(manager.maybe_trail!).to be false
      end
    end

    context 'when filled level is not the top level' do
      subject(:manager) { described_class.new(bot, filled_level: mid_level, client:) }

      it 'returns false' do
        expect(manager.maybe_trail!).to be false
      end
    end

    context 'when lowest level is already filled' do
      before do
        bottom_level.update!(status: 'filled')
      end

      it 'raises TrailError' do
        expect { manager.maybe_trail! }.to raise_error(
          described_class::TrailError, /already filled/
        )
      end
    end

    context 'when cancel returns order-already-filled error' do
      before do
        allow(client).to receive(:cancel_order).and_return(
          Exchange::Response.new(success: false, error_code: '110001', error_message: 'Order not found')
        )
      end

      it 'raises TrailError' do
        expect { manager.maybe_trail! }.to raise_error(
          described_class::TrailError, /already filled on exchange/
        )
      end
    end

    context 'when place_order fails' do
      before do
        allow(client).to receive(:place_order).and_return(
          Exchange::Response.new(success: false, error_message: 'Rejected')
        )
      end

      it 'raises TrailError' do
        expect { manager.maybe_trail! }.to raise_error(
          described_class::TrailError, /Failed to place trailing sell/
        )
      end

      it 'does not modify DB (lowest level still exists)' do
        manager.maybe_trail!
      rescue described_class::TrailError
        # expected
      ensure
        expect(GridLevel.find_by(id: bottom_level.id)).to be_present
        expect(bottom_level.reload.level_index).to eq(0)
      end
    end

    context 'with geometric spacing' do
      let(:bot) do
        create(
          :bot,
          exchange_account:,
          status: 'running',
          lower_price: BigDecimal('2000'),
          upper_price: BigDecimal('3000'),
          grid_count: 5,
          spacing_type: 'geometric',
          quantity_per_level: BigDecimal('0.1'),
          trailing_up_enabled: true,
          tick_size: BigDecimal('0.01')
        )
      end

      it 'computes geometric step and returns true' do
        expect(manager.maybe_trail!).to be true
        bot.reload
        expect(bot.upper_price).to be > BigDecimal('3000')
      end
    end
  end
end
