# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Bots', type: :request do
  let(:exchange_account) { create(:exchange_account) }
  let(:redis_state) { instance_double(Grid::RedisState) }

  before do
    allow(Grid::RedisState).to receive(:new).and_return(redis_state)
    allow(redis_state).to receive_messages(
      read_stats: { 'realized_profit' => '10.5', 'trade_count' => '3', 'uptime_start' => '1709800000' },
      read_levels: { '0' => { 'status' => 'active' }, '1' => { 'status' => 'active' } },
      read_price: '2500.00',
      update_status: nil,
      cleanup: nil
    )
  end

  describe 'GET /api/v1/bots' do
    let!(:bot) { create(:bot, exchange_account:, status: 'running') }
    let!(:discarded_bot) { create(:bot, exchange_account:, status: 'stopped', discarded_at: Time.current) }

    it 'returns kept bots only' do
      get '/api/v1/bots'
      expect(response).to have_http_status(:ok)
      body = Oj.load(response.body)
      expect(body['bots'].length).to eq(1)
      expect(body['bots'][0]['id']).to eq(bot.id)
    end

    it 'includes live stats from Redis' do
      get '/api/v1/bots'
      body = Oj.load(response.body)
      bot_data = body['bots'][0]
      expect(bot_data['current_price']).to eq('2500.00')
      expect(bot_data['realized_profit']).to eq('10.5')
      expect(bot_data['trade_count']).to eq(3)
      expect(bot_data['active_levels']).to eq(2)
    end
  end

  describe 'GET /api/v1/bots/:id' do
    let!(:bot) { create(:bot, exchange_account:, status: 'running') }
    let!(:grid_level) { create(:grid_level, bot:, level_index: 0, price: 2400) }

    it 'returns bot detail with recent trades' do
      get "/api/v1/bots/#{bot.id}"
      expect(response).to have_http_status(:ok)
      body = Oj.load(response.body)
      expect(body['bot']['id']).to eq(bot.id)
      expect(body['bot']['recent_trades']).to be_an(Array)
      expect(body['bot']['unrealized_pnl']).to eq('0.0')
    end

    it 'returns 404 for non-existent bot' do
      get '/api/v1/bots/999999'
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'POST /api/v1/bots' do
    let(:valid_params) do
      {
        bot: {
          pair: 'ETHUSDT',
          base_coin: 'ETH',
          quote_coin: 'USDT',
          lower_price: '2000.00',
          upper_price: '3000.00',
          grid_count: 10,
          spacing_type: 'arithmetic',
          investment_amount: '1000.00',
        },
      }
    end

    before do
      exchange_account
      allow(BotInitializerJob).to receive(:perform_async)
    end

    it 'creates a bot and enqueues initializer job' do
      post '/api/v1/bots', params: valid_params
      expect(response).to have_http_status(:created)
      body = Oj.load(response.body)
      expect(body['bot']['pair']).to eq('ETHUSDT')
      expect(body['bot']['status']).to eq('pending')
      expect(BotInitializerJob).to have_received(:perform_async)
    end

    it 'returns 422 for invalid params' do
      post '/api/v1/bots', params: { bot: { pair: '' } }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'creates a bot with risk params' do
      risk_params = valid_params.deep_merge(
        bot: { stop_loss_price: '1900.00', take_profit_price: '3500.00', trailing_up_enabled: true }
      )
      post '/api/v1/bots', params: risk_params
      expect(response).to have_http_status(:created)
      body = Oj.load(response.body)
      expect(body['bot']['stop_loss_price']).to eq('1900.0')
      expect(body['bot']['take_profit_price']).to eq('3500.0')
      expect(body['bot']['trailing_up_enabled']).to be true
    end

    it 'rejects stop_loss_price >= lower_price' do
      bad_params = valid_params.deep_merge(bot: { stop_loss_price: '2500.00' })
      post '/api/v1/bots', params: bad_params
      expect(response).to have_http_status(:unprocessable_content)
    end

    context 'when no exchange account exists' do
      before { ExchangeAccount.destroy_all }

      it 'returns 503 with setup_required' do
        post '/api/v1/bots', params: valid_params
        expect(response).to have_http_status(:service_unavailable)
      end
    end
  end

  describe 'PATCH /api/v1/bots/:id' do
    let!(:bot) { create(:bot, exchange_account:, status: 'running') }

    it 'pauses a running bot' do
      patch "/api/v1/bots/#{bot.id}", params: { bot: { status: 'paused' } }
      expect(response).to have_http_status(:ok)
      expect(bot.reload.status).to eq('paused')
    end

    it 'resumes a paused bot' do
      bot.update!(status: 'paused')
      patch "/api/v1/bots/#{bot.id}", params: { bot: { status: 'running' } }
      expect(response).to have_http_status(:ok)
      expect(bot.reload.status).to eq('running')
    end

    context 'when stopping a bot' do
      let(:stopper) { instance_double(Grid::Stopper) }

      before do
        allow(Grid::Stopper).to receive(:new).and_return(stopper)
        allow(stopper).to receive(:call) do
          bot.update!(status: 'stopped', stop_reason: 'user')
        end
      end

      it 'invokes Grid::Stopper' do
        patch "/api/v1/bots/#{bot.id}", params: { bot: { status: 'stopped' } }
        expect(response).to have_http_status(:ok)
        expect(stopper).to have_received(:call)
      end
    end

    it 'returns 400 for invalid status' do
      patch "/api/v1/bots/#{bot.id}", params: { bot: { status: 'invalid' } }
      expect(response).to have_http_status(:bad_request)
    end

    it 'updates risk params on a running bot' do
      patch "/api/v1/bots/#{bot.id}", params: {
        bot: { stop_loss_price: '1800.00', take_profit_price: '3500.00', trailing_up_enabled: true },
      }
      expect(response).to have_http_status(:ok)
      bot.reload
      expect(bot.stop_loss_price).to eq(BigDecimal('1800'))
      expect(bot.take_profit_price).to eq(BigDecimal('3500'))
      expect(bot.trailing_up_enabled).to be true
    end

    it 'returns risk fields in JSON response' do
      bot.update!(stop_loss_price: BigDecimal('1800'), take_profit_price: BigDecimal('3500'))
      patch "/api/v1/bots/#{bot.id}", params: { bot: { trailing_up_enabled: true } }
      body = Oj.load(response.body)
      expect(body['bot']['stop_loss_price']).to eq('1800.0')
      expect(body['bot']['take_profit_price']).to eq('3500.0')
      expect(body['bot']['trailing_up_enabled']).to be true
      expect(body['bot']).to have_key('stop_reason')
    end
  end

  describe 'DELETE /api/v1/bots/:id' do
    context 'with a stopped bot' do
      let!(:bot) { create(:bot, exchange_account:, status: 'stopped') }

      it 'soft-deletes the bot' do
        delete "/api/v1/bots/#{bot.id}"
        expect(response).to have_http_status(:ok)
        expect(bot.reload.discarded_at).to be_present
      end
    end

    context 'with a running bot' do
      let!(:bot) { create(:bot, exchange_account:, status: 'running') }
      let(:stopper) { instance_double(Grid::Stopper) }

      before do
        allow(Grid::Stopper).to receive(:new).and_return(stopper)
        allow(stopper).to receive(:call) do
          bot.update!(status: 'stopped', stop_reason: 'user')
        end
      end

      it 'stops then soft-deletes the bot' do
        delete "/api/v1/bots/#{bot.id}"
        expect(response).to have_http_status(:ok)
        expect(stopper).to have_received(:call)
        expect(bot.reload.discarded_at).to be_present
      end
    end
  end
end
