# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Grid::RiskManager do
  let(:exchange_account) { create(:exchange_account) }
  let(:bot) do
    create(
      :bot,
      exchange_account:,
      status: 'running',
      stop_loss_price: 1800,
      take_profit_price: 3200,
      base_coin: 'ETH',
      pair: 'ETHUSDT'
    )
  end
  let(:client) { instance_double(Bybit::RestClient) }
  let(:redis_state) { instance_double(Grid::RedisState) }

  # rubocop:disable RSpec/ReceiveMessages -- need individual stubs for argument matchers
  before do
    allow(Bybit::RestClient).to receive(:new).and_return(client)
    allow(client).to receive(:cancel_all_orders)
      .and_return(Exchange::Response.new(success: true, data: {}))
    allow(client).to receive(:place_order)
      .and_return(Exchange::Response.new(success: true, data: { orderId: 'mkt-123' }))
    allow(client).to receive(:get_wallet_balance).and_return(
      Exchange::Response.new(
        success: true,
        data: { list: [{ coin: [{ coin: 'ETH', availableToWithdraw: '0.5' }] }] }
      )
    )
    allow(Grid::RedisState).to receive(:new).and_return(redis_state)
    allow(redis_state).to receive(:update_status)
    allow(redis_state).to receive(:cleanup)
    allow(ActionCable.server).to receive(:broadcast)
    allow(BalanceSnapshotWorker).to receive(:perform_async)
  end
  # rubocop:enable RSpec/ReceiveMessages

  describe '#check!' do
    context 'when stop-loss triggers' do
      subject(:result) { described_class.new(bot, current_price: '1750').check! }

      let!(:active_order) { create(:order, bot:, grid_level: active_level, status: 'open') }
      let!(:active_level) { create(:grid_level, bot:, status: 'active', level_index: 0) }

      it 'returns :stop_loss' do
        expect(result).to eq(:stop_loss)
      end

      it 'transitions bot to stopped with stop_loss reason' do
        result
        expect(bot.reload.status).to eq('stopped')
        expect(bot.reload.stop_reason).to eq('stop_loss')
      end

      it 'cancels all orders with emergency flag' do
        result
        expect(client).to have_received(:cancel_all_orders)
          .with(symbol: 'ETHUSDT', emergency: true)
      end

      it 'market-sells base asset with emergency flag' do
        result
        expect(client).to have_received(:place_order).with(
          symbol: 'ETHUSDT',
          side: 'Sell',
          order_type: 'Market',
          qty: '0.5',
          emergency: true
        )
      end

      it 'marks active orders as cancelled' do
        result
        expect(active_order.reload.status).to eq('cancelled')
      end

      it 'marks active grid levels as filled' do
        result
        expect(active_level.reload.status).to eq('filled')
      end

      it 'broadcasts stopping then stopped status' do
        result
        expect(ActionCable.server).to have_received(:broadcast).with(
          "bot_#{bot.id}",
          hash_including(type: 'status', status: 'stopping')
        ).ordered
        expect(ActionCable.server).to have_received(:broadcast).with(
          "bot_#{bot.id}",
          hash_including(type: 'status', status: 'stopped', stop_reason: 'stop_loss')
        ).ordered
      end

      it 'kicks off async balance snapshot' do
        result
        expect(BalanceSnapshotWorker).to have_received(:perform_async)
      end

      it 'cleans up Redis state' do
        result
        expect(redis_state).to have_received(:cleanup).with(bot.id)
      end
    end

    context 'when take-profit triggers' do
      subject(:result) { described_class.new(bot, current_price: '3200').check! }

      it 'returns :take_profit' do
        expect(result).to eq(:take_profit)
      end

      it 'stops the bot with take_profit reason' do
        result
        expect(bot.reload.status).to eq('stopped')
        expect(bot.reload.stop_reason).to eq('take_profit')
      end
    end

    context 'when price is within range (no trigger)' do
      subject(:result) { described_class.new(bot, current_price: '2500').check! }

      it 'returns nil' do
        expect(result).to be_nil
      end

      it 'does not change bot status' do
        result
        expect(bot.reload.status).to eq('running')
      end
    end

    context 'when stop_loss_price and take_profit_price are nil' do
      let(:bot) do
        create(
          :bot,
          exchange_account:,
          status: 'running',
          stop_loss_price: nil,
          take_profit_price: nil
        )
      end

      it 'returns nil for any price' do
        expect(described_class.new(bot, current_price: '1').check!).to be_nil
      end
    end

    context 'when bot is already stopping (idempotency)' do
      before do
        # Simulate another thread already claimed the stop
        Bot.where(id: bot.id).update_all(status: 'stopping') # rubocop:disable Rails/SkipsModelValidations
      end

      it 'returns nil without executing emergency stop' do
        result = described_class.new(bot, current_price: '1750').check!
        expect(result).to be_nil
        expect(client).not_to have_received(:cancel_all_orders)
      end
    end

    context 'when price is exactly at stop_loss boundary' do
      it 'triggers stop_loss' do
        result = described_class.new(bot, current_price: '1800').check!
        expect(result).to eq(:stop_loss)
      end
    end

    context 'when price is exactly at take_profit boundary' do
      it 'triggers take_profit' do
        result = described_class.new(bot, current_price: '3200').check!
        expect(result).to eq(:take_profit)
      end
    end

    context 'when market sell fails' do
      before do
        allow(client).to receive(:place_order).and_return(
          Exchange::Response.new(success: false, error_message: 'Insufficient balance')
        )
        allow(Rails.logger).to receive(:error)
      end

      it 'returns the triggered reason' do
        result = described_class.new(bot, current_price: '1750').check!
        expect(result).to eq(:stop_loss)
      end

      it 'leaves bot in stopping state' do
        described_class.new(bot, current_price: '1750').check!
        expect(bot.reload.status).to eq('stopping')
      end

      it 'logs error with bot id and failure details' do
        described_class.new(bot, current_price: '1750').check!
        expect(Rails.logger).to have_received(:error)
          .with(/RiskManager.*Bot #{bot.id}.*market sell failed/)
      end

      it 'broadcasts risk_error' do
        described_class.new(bot, current_price: '1750').check!
        expect(ActionCable.server).to have_received(:broadcast).with(
          "bot_#{bot.id}",
          hash_including(type: 'risk_error')
        )
      end
    end

    context 'when wallet balance fetch fails' do
      before do
        allow(client).to receive(:get_wallet_balance).and_return(
          Exchange::Response.new(success: false, error_message: 'API error')
        )
        allow(Rails.logger).to receive(:warn)
      end

      it 'falls back to DB estimate and still stops' do
        described_class.new(bot, current_price: '1750').check!
        expect(bot.reload.status).to eq('stopped')
      end
    end

    context 'when exchange base balance is zero' do
      before do
        allow(client).to receive(:get_wallet_balance).and_return(
          Exchange::Response.new(
            success: true,
            data: { list: [{ coin: [{ coin: 'ETH', availableToWithdraw: '0' }] }] }
          )
        )
      end

      it 'skips market sell and still stops' do
        described_class.new(bot, current_price: '1750').check!
        expect(client).not_to have_received(:place_order)
        expect(bot.reload.status).to eq('stopped')
      end
    end
  end
end
