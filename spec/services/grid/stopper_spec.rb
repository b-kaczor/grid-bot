# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Grid::Stopper do
  let(:exchange_account) { create(:exchange_account) }
  let(:bot) { create(:bot, exchange_account:, status: 'running') }
  let(:client) { instance_double(Bybit::RestClient) }
  let(:redis_state) { instance_double(Grid::RedisState) }

  before do
    allow(Bybit::RestClient).to receive(:new).and_return(client)
    allow(client).to receive(:cancel_all_orders).and_return(
      Exchange::Response.new(success: true, data: {})
    )
    allow(Grid::RedisState).to receive(:new).and_return(redis_state)
    allow(redis_state).to receive(:update_status)
    allow(redis_state).to receive(:cleanup)
    allow(ActionCable.server).to receive(:broadcast)
  end

  subject(:stopper) { described_class.new(bot) }

  describe '#call' do
    context 'with a running bot' do
      let!(:active_order) { create(:order, bot:, grid_level: active_level, status: 'open') }
      let!(:active_level) { create(:grid_level, bot:, status: 'active', level_index: 0) }
      let!(:filled_order) { create(:order, bot:, grid_level: filled_level, status: 'filled') }
      let!(:filled_level) { create(:grid_level, bot:, status: 'filled', level_index: 1) }

      it 'transitions bot to stopped' do
        stopper.call
        expect(bot.reload.status).to eq('stopped')
      end

      it 'sets stop_reason to user' do
        stopper.call
        expect(bot.reload.stop_reason).to eq('user')
      end

      it 'cancels exchange orders' do
        stopper.call
        expect(client).to have_received(:cancel_all_orders).with(symbol: bot.pair)
      end

      it 'marks active orders as cancelled' do
        stopper.call
        expect(active_order.reload.status).to eq('cancelled')
      end

      it 'does not change already-filled orders' do
        stopper.call
        expect(filled_order.reload.status).to eq('filled')
      end

      it 'marks active grid levels as filled' do
        stopper.call
        expect(active_level.reload.status).to eq('filled')
      end

      it 'broadcasts stopping status first' do
        stopper.call
        expect(ActionCable.server).to have_received(:broadcast).with(
          "bot_#{bot.id}", { type: 'status', status: 'stopping' }
        ).ordered
      end

      it 'broadcasts stopped status last' do
        stopper.call
        expect(ActionCable.server).to have_received(:broadcast).with(
          "bot_#{bot.id}", { type: 'status', status: 'stopped' }
        )
      end

      it 'updates Redis status to stopping' do
        stopper.call
        expect(redis_state).to have_received(:update_status).with(bot.id, 'stopping')
      end

      it 'cleans up Redis state' do
        stopper.call
        expect(redis_state).to have_received(:cleanup).with(bot.id)
      end
    end

    context 'with a paused bot' do
      let(:bot) { create(:bot, exchange_account:, status: 'paused') }

      it 'transitions to stopped' do
        stopper.call
        expect(bot.reload.status).to eq('stopped')
      end
    end

    context 'with a stopping bot' do
      let(:bot) { create(:bot, exchange_account:, status: 'stopping') }

      it 'transitions to stopped' do
        stopper.call
        expect(bot.reload.status).to eq('stopped')
      end
    end

    context 'with a pending bot' do
      let(:bot) { create(:bot, exchange_account:, status: 'pending') }

      it 'raises Error' do
        expect { stopper.call }.to raise_error(described_class::Error, /cannot be stopped/)
      end
    end

    context 'with a stopped bot' do
      let(:bot) { create(:bot, exchange_account:, status: 'stopped') }

      it 'raises Error' do
        expect { stopper.call }.to raise_error(described_class::Error, /cannot be stopped/)
      end
    end

    context 'when cancel_all_orders fails' do
      before do
        allow(client).to receive(:cancel_all_orders).and_return(
          Exchange::Response.new(success: false, error_message: 'Exchange error')
        )
      end

      it 'still transitions to stopped (best-effort cancel)' do
        stopper.call
        expect(bot.reload.status).to eq('stopped')
      end

      it 'logs a warning' do
        allow(Rails.logger).to receive(:warn)
        stopper.call
        expect(Rails.logger).to have_received(:warn).with(/cancel_all_orders failed/)
      end
    end
  end
end
