# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Bots::GridController', type: :request do
  let(:exchange_account) { create(:exchange_account) }
  let(:bot) { create(:bot, exchange_account:, status: 'running') }
  let(:redis_state) { instance_double(Grid::RedisState) }

  before do
    allow(Grid::RedisState).to receive(:new).and_return(redis_state)
  end

  describe 'GET /api/v1/bots/:bot_id/grid' do
    context 'with grid levels in DB' do
      before do
        allow(redis_state).to receive(:read_price).with(bot.id).and_return('2450.0')

        create(:grid_level, bot:, level_index: 0, price: 2400, expected_side: 'buy', status: 'active',
                            cycle_count: 2)
        create(:grid_level, bot:, level_index: 1, price: 2500, expected_side: 'sell', status: 'active',
                            cycle_count: 1)
      end

      it 'returns grid levels from DB' do
        get "/api/v1/bots/#{bot.id}/grid"
        expect(response).to have_http_status(:ok)

        body = Oj.load(response.body)
        grid = body['grid']
        expect(grid['current_price']).to eq('2450.0')
        expect(grid['levels'].size).to eq(2)
        expect(grid['levels'].first['level_index']).to eq(0)
        expect(grid['levels'].first['price']).to eq('2400.0')
      end

      it 'orders levels by level_index' do
        get "/api/v1/bots/#{bot.id}/grid"
        body = Oj.load(response.body)
        indices = body['grid']['levels'].pluck('level_index')
        expect(indices).to eq([0, 1])
      end
    end

    context 'when Redis has no price' do
      before do
        allow(redis_state).to receive(:read_price).with(bot.id).and_return(nil)

        create(:grid_level, bot:, level_index: 0, price: 2400, expected_side: 'buy', status: 'active')
      end

      it 'falls back to snapshot price' do
        create(:balance_snapshot, bot:, current_price: BigDecimal('2450'), snapshot_at: 1.hour.ago)
        get "/api/v1/bots/#{bot.id}/grid"
        body = Oj.load(response.body)
        expect(body['grid']['current_price']).to eq('2450.0')
      end
    end

    it 'returns 404 for non-existent bot' do
      allow(redis_state).to receive(:read_price).and_return(nil)
      get '/api/v1/bots/-1/grid'
      expect(response).to have_http_status(:not_found)
    end
  end
end
