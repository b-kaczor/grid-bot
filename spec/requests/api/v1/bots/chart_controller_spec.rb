# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Bots::ChartController', type: :request do
  let(:exchange_account) { create(:exchange_account) }
  let(:bot) { create(:bot, exchange_account:, status: 'running') }

  describe 'GET /api/v1/bots/:bot_id/chart' do
    context 'with fine-grained snapshots (default 24h)' do
      before do
        create(:balance_snapshot, bot:, granularity: 'fine', snapshot_at: 2.hours.ago)
        create(:balance_snapshot, bot:, granularity: 'fine', snapshot_at: 1.hour.ago)
      end

      it 'returns snapshots with fine granularity' do
        get "/api/v1/bots/#{bot.id}/chart"
        expect(response).to have_http_status(:ok)

        body = Oj.load(response.body)
        expect(body['granularity']).to eq('fine')
        expect(body['snapshots'].size).to eq(2)
      end

      it 'serializes snapshot fields correctly' do
        get "/api/v1/bots/#{bot.id}/chart"
        body = Oj.load(response.body)
        snapshot = body['snapshots'].first
        expect(snapshot).to have_key('snapshot_at')
        expect(snapshot).to have_key('total_value_quote')
        expect(snapshot).to have_key('realized_profit')
        expect(snapshot).to have_key('unrealized_pnl')
        expect(snapshot).to have_key('current_price')
      end
    end

    context 'with custom time range selecting hourly granularity' do
      let(:from_time) { 10.days.ago }
      let(:to_time) { Time.current }

      before do
        create(:balance_snapshot, bot:, granularity: 'hourly', snapshot_at: 8.days.ago)
        create(:balance_snapshot, bot:, granularity: 'fine', snapshot_at: 8.days.ago + 1.minute)
      end

      it 'returns hourly granularity for 7-30 day range' do
        get "/api/v1/bots/#{bot.id}/chart", params: { from: from_time.iso8601, to: to_time.iso8601 }
        body = Oj.load(response.body)
        expect(body['granularity']).to eq('hourly')
        expect(body['snapshots'].size).to eq(1)
      end
    end

    context 'with daily granularity for 30+ day range' do
      before do
        create(:balance_snapshot, bot:, granularity: 'daily', snapshot_at: 35.days.ago)
      end

      it 'returns daily granularity' do
        get "/api/v1/bots/#{bot.id}/chart",
            params: { from: 40.days.ago.iso8601, to: Time.current.iso8601 }
        body = Oj.load(response.body)
        expect(body['granularity']).to eq('daily')
      end
    end

    it 'returns 404 for non-existent bot' do
      get '/api/v1/bots/-1/chart'
      expect(response).to have_http_status(:not_found)
    end

    it 'returns empty snapshots for bot with no data' do
      get "/api/v1/bots/#{bot.id}/chart"
      body = Oj.load(response.body)
      expect(body['snapshots']).to eq([])
    end
  end
end
