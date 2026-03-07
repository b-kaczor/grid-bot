# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Bots::TradesController', type: :request do
  let(:exchange_account) { create(:exchange_account) }
  let(:bot) { create(:bot, exchange_account:, status: 'running') }
  let(:grid_level) { create(:grid_level, bot:, level_index: 0) }

  let!(:trades) do
    Array.new(5) do |i|
      buy = create(:order, bot:, grid_level:, side: 'buy', status: 'filled')
      sell = create(:order, bot:, grid_level:, side: 'sell', status: 'filled')
      create(
        :trade,
        bot:,
        grid_level:,
        buy_order: buy,
        sell_order: sell,
        net_profit: BigDecimal('1.5'),
        completed_at: i.hours.ago
      )
    end
  end

  describe 'GET /api/v1/bots/:bot_id/trades' do
    it 'returns paginated trades' do
      get "/api/v1/bots/#{bot.id}/trades", params: { per_page: 2 }
      expect(response).to have_http_status(:ok)

      body = Oj.load(response.body)
      expect(body['trades'].size).to eq(2)
      expect(body['pagination']['total']).to eq(5)
      expect(body['pagination']['total_pages']).to eq(3)
    end

    it 'returns trades ordered by completed_at desc' do
      get "/api/v1/bots/#{bot.id}/trades"
      body = Oj.load(response.body)
      dates = body['trades'].pluck('completed_at')
      expect(dates).to eq(dates.sort.reverse)
    end

    it 'serializes trade fields correctly' do
      get "/api/v1/bots/#{bot.id}/trades"
      body = Oj.load(response.body)
      trade = body['trades'].first
      expect(trade).to have_key('id')
      expect(trade).to have_key('level_index')
      expect(trade).to have_key('buy_price')
      expect(trade).to have_key('sell_price')
      expect(trade).to have_key('quantity')
      expect(trade).to have_key('gross_profit')
      expect(trade).to have_key('total_fees')
      expect(trade).to have_key('net_profit')
      expect(trade).to have_key('completed_at')
    end

    it 'respects page parameter' do
      get "/api/v1/bots/#{bot.id}/trades", params: { page: 2, per_page: 2 }
      body = Oj.load(response.body)
      expect(body['trades'].size).to eq(2)
      expect(body['pagination']['page']).to eq(2)
    end

    it 'returns 404 for non-existent bot' do
      get '/api/v1/bots/-1/trades'
      expect(response).to have_http_status(:not_found)
    end

    it 'returns empty trades for bot with no trades' do
      new_bot = create(:bot, exchange_account:)
      get "/api/v1/bots/#{new_bot.id}/trades"
      body = Oj.load(response.body)
      expect(body['trades']).to eq([])
      expect(body['pagination']['total']).to eq(0)
    end
  end
end
