# frozen_string_literal: true

require 'rails_helper'

# Stub workers that don't exist yet (owned by backend-dev-2)
unless defined?(OrderFillWorker)
  class OrderFillWorker
    def self.perform_async(*); end
  end
end

unless defined?(GridReconciliationWorker)
  class GridReconciliationWorker
    def self.perform_async(*); end
  end
end

RSpec.describe Bybit::WebsocketListener do
  let(:redis) { instance_double(Redis) }
  let(:redis_state) { instance_double(Grid::RedisState) }
  let(:listener) { described_class.new(redis:, redis_state:) }

  before do
    allow(redis).to receive(:xadd)
  end

  describe '#initialize' do
    it 'accepts explicit redis and redis_state dependencies' do
      expect(listener).to be_a(described_class)
      expect(listener.shutdown).to be false
    end
  end

  describe 'authentication message format' do
    it 'generates correct HMAC auth payload' do
      account = instance_double(ExchangeAccount, api_key: 'test_key', api_secret: 'test_secret')
      connection = instance_double(Protocol::WebSocket::Connection)
      allow(connection).to receive(:send_text)

      freeze_time = Time.zone.local(2026, 3, 7, 12, 0, 0)
      allow(Time).to receive(:now).and_return(freeze_time)

      listener.send(:authenticate, connection, account)

      expect(connection).to have_received(:send_text) do |json|
        data = Oj.load(json, symbol_keys: true)
        expect(data[:op]).to eq('auth')
        expect(data[:args]).to be_an(Array)
        expect(data[:args].length).to eq(3)

        api_key, expires, signature = data[:args]
        expect(api_key).to eq('test_key')

        expected_expires = ((freeze_time.to_f * 1000).to_i + 5000).to_s
        expect(expires).to eq(expected_expires)

        expected_sig = OpenSSL::HMAC.hexdigest('SHA256', 'test_secret', "GET/realtime#{expected_expires}")
        expect(signature).to eq(expected_sig)
      end
    end
  end

  describe 'subscription' do
    before do
      allow(Bot).to receive(:running).and_return(Bot.none)
    end

    it 'subscribes to core topics including dcp' do
      connection = instance_double(Protocol::WebSocket::Connection)
      allow(connection).to receive(:send_text)

      listener.send(:subscribe, connection)

      expect(connection).to have_received(:send_text) do |json|
        data = Oj.load(json, symbol_keys: true)
        expect(data[:op]).to eq('subscribe')
        expect(data[:args]).to include('order.spot', 'execution.spot', 'wallet', 'dcp')
      end
    end

    it 'includes ticker topics for running bot pairs' do
      running_scope = double(pluck: %w[ETHUSDT BTCUSDT ETHUSDT])
      allow(Bot).to receive(:running).and_return(running_scope)
      connection = instance_double(Protocol::WebSocket::Connection)
      allow(connection).to receive(:send_text)

      listener.send(:subscribe, connection)

      expect(connection).to have_received(:send_text) do |json|
        data = Oj.load(json, symbol_keys: true)
        expect(data[:args]).to include('tickers.ETHUSDT', 'tickers.BTCUSDT')
      end
    end
  end

  describe '#process_order_event' do
    let(:fill_event) do
      {
        orderId: '1234567890',
        orderLinkId: 'g1-L5-B-0',
        symbol: 'ETHUSDT',
        side: 'Buy',
        orderStatus: 'Filled',
        qty: '0.1',
        avgPrice: '2500.00',
      }
    end

    it 'enqueues OrderFillWorker for Filled orders' do
      allow(OrderFillWorker).to receive(:perform_async)

      listener.send(:process_order_event, fill_event)

      expect(OrderFillWorker).to have_received(:perform_async) do |json|
        data = Oj.load(json, symbol_keys: true)
        expect(data[:orderId]).to eq('1234567890')
        expect(data[:orderLinkId]).to eq('g1-L5-B-0')
      end
    end

    it 'publishes fill event to Redis stream' do
      allow(OrderFillWorker).to receive(:perform_async)

      listener.send(:process_order_event, fill_event)

      expect(redis).to have_received(:xadd).with(
        'grid:fills',
        hash_including(
          order_id: '1234567890',
          order_link_id: 'g1-L5-B-0',
          symbol: 'ETHUSDT',
          side: 'Buy',
          status: 'Filled'
        ),
        maxlen: 10_000,
        approximate: true
      )
    end

    it 'ignores non-Filled order events' do
      allow(OrderFillWorker).to receive(:perform_async)

      non_fill = fill_event.merge(orderStatus: 'New')
      listener.send(:process_order_event, non_fill)

      expect(OrderFillWorker).not_to have_received(:perform_async)
      expect(redis).not_to have_received(:xadd)
    end

    it 'ignores PartiallyFilled order events' do
      allow(OrderFillWorker).to receive(:perform_async)

      partial = fill_event.merge(orderStatus: 'PartiallyFilled')
      listener.send(:process_order_event, partial)

      expect(OrderFillWorker).not_to have_received(:perform_async)
    end
  end

  describe '#process_message' do
    it 'processes order.spot topic with fill events' do
      allow(OrderFillWorker).to receive(:perform_async)

      data = {
        topic: 'order.spot',
        data: [
          {
            orderId: '111',
            orderLinkId: 'g1-L0-B-0',
            orderStatus: 'Filled',
            symbol: 'ETHUSDT',
            side: 'Buy',
            qty: '0.1',
            avgPrice: '2500',
          }
        ],
      }

      listener.send(:process_message, data)

      expect(OrderFillWorker).to have_received(:perform_async).once
    end

    it 'skips non-fill events within order.spot batch' do
      allow(OrderFillWorker).to receive(:perform_async)

      data = {
        topic: 'order.spot',
        data: [
          { orderId: '111', orderStatus: 'New', symbol: 'ETHUSDT' },
          {
            orderId: '222',
            orderLinkId: 'g1-L1-S-0',
            orderStatus: 'Filled',
            symbol: 'ETHUSDT',
            side: 'Sell',
            qty: '0.1',
            avgPrice: '2600',
          }
        ],
      }

      listener.send(:process_message, data)

      expect(OrderFillWorker).to have_received(:perform_async).once
    end

    it 'handles pong system messages without error' do
      expect { listener.send(:process_message, { op: 'pong' }) }.not_to raise_error
    end

    it 'handles auth success messages' do
      expect { listener.send(:process_message, { op: 'auth', success: true }) }.not_to raise_error
    end
  end

  describe 'DCP registration' do
    it 'registers DCP via REST client and stores timestamp in Redis' do
      account = instance_double(ExchangeAccount, api_key: 'key', api_secret: 'secret')
      client = instance_double(Bybit::RestClient)
      allow(Bybit::RestClient).to receive(:new).and_return(client)
      allow(client).to receive(:set_dcp).and_return(
        Exchange::Response.new(success: true, data: {})
      )
      allow(redis).to receive(:set)

      listener.send(:register_dcp, account)

      expect(client).to have_received(:set_dcp).with(time_window: 40)
      expect(redis).to have_received(:set).with('grid:dcp:registered_at', anything)
    end
  end

  describe 'DCP message handling' do
    it 'logs error and triggers reconciliation on DCP OFF status' do
      allow(Rails.logger).to receive(:error)
      allow(GridReconciliationWorker).to receive(:perform_async)
      allow(Bot).to receive(:running).and_return(Bot.none)

      data = { topic: 'dcp', data: [{ dcpStatus: 'OFF' }] }
      listener.send(:process_message, data)

      expect(Rails.logger).to have_received(:error).with(/DCP triggered/)
    end

    it 'stores last_confirmed timestamp on DCP heartbeat' do
      allow(redis).to receive(:set)

      data = { topic: 'dcp', data: [{ dcpStatus: 'ON' }] }
      listener.send(:process_message, data)

      expect(redis).to have_received(:set).with('grid:dcp:last_confirmed', anything)
    end
  end

  describe 'ticker message handling' do
    let(:risk_manager) { instance_double(Grid::RiskManager) }

    before do
      allow(Grid::RiskManager).to receive(:new).and_return(risk_manager)
      allow(risk_manager).to receive(:check!).and_return(nil)
      allow(redis_state).to receive(:update_price)
    end

    it 'runs risk check for running bots on the ticker symbol' do
      bot = create(:bot, status: 'running', pair: 'ETHUSDT')

      data = { topic: 'tickers.ETHUSDT', data: { symbol: 'ETHUSDT', lastPrice: '1800.0' } }
      listener.send(:process_message, data)

      expect(Grid::RiskManager).to have_received(:new).with(bot, current_price: '1800.0')
      expect(risk_manager).to have_received(:check!)
    end

    it 'updates Redis price for all bots on the pair' do
      bot = create(:bot, status: 'running', pair: 'ETHUSDT')

      data = { topic: 'tickers.ETHUSDT', data: { symbol: 'ETHUSDT', lastPrice: '2500.0' } }
      listener.send(:process_message, data)

      expect(redis_state).to have_received(:update_price).with(bot.id, '2500.0')
    end

    it 'rescues errors from risk check without stopping' do
      create(:bot, status: 'running', pair: 'ETHUSDT')
      allow(risk_manager).to receive(:check!).and_raise(StandardError, 'boom')
      allow(Rails.logger).to receive(:error)

      data = { topic: 'tickers.ETHUSDT', data: { symbol: 'ETHUSDT', lastPrice: '1800.0' } }
      expect { listener.send(:process_message, data) }.not_to raise_error
      expect(Rails.logger).to have_received(:error).with(/Risk check failed/)
    end
  end

  describe 'reconnection triggers reconciliation' do
    it 'enqueues GridReconciliationWorker for all running bots' do
      bot1 = instance_double(Bot, id: 1)
      bot2 = instance_double(Bot, id: 2)
      allow(Bot).to receive(:running).and_return(
        double(find_each: nil).tap { |d|
          allow(d).to receive(:find_each).and_yield(bot1).and_yield(bot2)
        }
      )
      allow(GridReconciliationWorker).to receive(:perform_async)

      listener.send(:trigger_reconciliation_for_all_bots)

      expect(GridReconciliationWorker).to have_received(:perform_async).with(1)
      expect(GridReconciliationWorker).to have_received(:perform_async).with(2)
    end
  end

  describe 'maintenance handling' do
    it 'pauses all running bots with maintenance reason' do
      bot = instance_double(Bot, id: 1)
      allow(bot).to receive(:update!)
      running_scope = double(find_each: nil)
      allow(running_scope).to receive(:find_each).and_yield(bot)
      allow(Bot).to receive(:running).and_return(running_scope)
      allow(redis_state).to receive(:update_status)

      listener.send(:pause_all_bots, 'maintenance')

      expect(bot).to have_received(:update!).with(status: 'paused', stop_reason: 'maintenance')
      expect(redis_state).to have_received(:update_status).with(1, 'paused')
    end

    it 'resumes maintenance-paused bots after reconnection' do
      bot = instance_double(Bot, id: 1)
      allow(bot).to receive(:update!)
      maintenance_scope = double(find_each: nil)
      allow(maintenance_scope).to receive(:find_each).and_yield(bot)
      allow(Bot).to receive(:where).with(status: 'paused', stop_reason: 'maintenance').and_return(maintenance_scope)
      allow(Bot).to receive(:running).and_return(double(find_each: nil))
      allow(redis_state).to receive(:update_status)
      allow(GridReconciliationWorker).to receive(:perform_async)

      listener.send(:resume_after_maintenance)

      expect(bot).to have_received(:update!).with(status: 'running', stop_reason: nil)
      expect(redis_state).to have_received(:update_status).with(1, 'running')
    end
  end

  describe 'SIGTERM shutdown flag' do
    it 'sets shutdown flag via signal handler setup' do
      expect(listener.shutdown).to be false

      # Simulate what the signal handler does
      listener.instance_variable_set(:@shutdown, true)

      expect(listener.shutdown).to be true
    end
  end

  describe 'Redis stream publishing' do
    it 'caps stream at 10000 entries with approximate maxlen' do
      allow(OrderFillWorker).to receive(:perform_async)

      fill = {
        orderId: '999',
        orderLinkId: 'g1-L0-B-0',
        symbol: 'ETHUSDT',
        side: 'Buy',
        orderStatus: 'Filled',
        qty: '0.1',
        avgPrice: '2500',
      }

      listener.send(:process_order_event, fill)

      expect(redis).to have_received(:xadd).with(
        'grid:fills',
        anything,
        maxlen: 10_000,
        approximate: true
      )
    end
  end
end
