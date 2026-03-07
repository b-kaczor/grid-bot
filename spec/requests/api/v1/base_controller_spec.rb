# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::BaseController, type: :request do
  before do
    stub_const(
      'Api::V1::TestController', Class.new(described_class) do
                                   def test_not_found
                                     raise ActiveRecord::RecordNotFound, 'Bot not found'
                                   end

                                   def test_invalid
                                     bot = Bot.new
                                     bot.errors.add(:pair, 'is required')
                                     raise ActiveRecord::RecordInvalid, bot
                                   end

                                   def test_missing_param
                                     params.require(:bot)
                                   end

                                   def test_exchange_account
                                     account = default_exchange_account
                                     return unless account

                                     render json: { id: account.id }
                                   end

                                   def test_paginate
                                     result = paginate(Bot.all, default_per: 2)
                                     render json: result.except(:records).merge(ids: result[:records].map(&:id))
                                   end
                                 end
    )

    Rails.application.routes.draw do
      namespace :api do
        namespace :v1 do
          get 'test_not_found', to: 'test#test_not_found'
          get 'test_invalid', to: 'test#test_invalid'
          get 'test_missing_param', to: 'test#test_missing_param'
          get 'test_exchange_account', to: 'test#test_exchange_account'
          get 'test_paginate', to: 'test#test_paginate'
        end
      end
    end
  end

  after do
    Rails.application.reload_routes!
  end

  describe 'error handling' do
    it 'returns 404 for RecordNotFound' do
      get '/api/v1/test_not_found'
      expect(response).to have_http_status(:not_found)
      expect(Oj.load(response.body)['error']).to eq('Bot not found')
    end

    it 'returns 422 for RecordInvalid' do
      get '/api/v1/test_invalid'
      expect(response).to have_http_status(:unprocessable_content)
      expect(Oj.load(response.body)['error']).to include('Pair is required')
    end

    it 'returns 400 for ParameterMissing' do
      get '/api/v1/test_missing_param'
      expect(response).to have_http_status(:bad_request)
      expect(Oj.load(response.body)['error']).to include('bot')
    end
  end

  describe '#default_exchange_account' do
    context 'when an exchange account exists' do
      let!(:account) { create(:exchange_account) }

      it 'returns the account' do
        get '/api/v1/test_exchange_account'
        expect(response).to have_http_status(:ok)
        expect(Oj.load(response.body)['id']).to eq(account.id)
      end
    end

    context 'when no exchange account exists' do
      it 'returns 503 with setup_required' do
        get '/api/v1/test_exchange_account'
        expect(response).to have_http_status(:service_unavailable)
        body = Oj.load(response.body)
        expect(body['setup_required']).to be true
        expect(body['error']).to include('No exchange account')
      end
    end
  end

  describe '#paginate' do
    let!(:exchange_account) { create(:exchange_account) }

    before do
      3.times { create(:bot, exchange_account:) }
    end

    it 'paginates with defaults' do
      get '/api/v1/test_paginate'
      body = Oj.load(response.body)
      expect(body['page']).to eq(1)
      expect(body['per_page']).to eq(2)
      expect(body['total']).to eq(3)
      expect(body['total_pages']).to eq(2)
      expect(body['ids'].size).to eq(2)
    end

    it 'respects page parameter' do
      get '/api/v1/test_paginate', params: { page: 2 }
      body = Oj.load(response.body)
      expect(body['page']).to eq(2)
      expect(body['ids'].size).to eq(1)
    end

    it 'clamps page to minimum 1' do
      get '/api/v1/test_paginate', params: { page: -1 }
      body = Oj.load(response.body)
      expect(body['page']).to eq(1)
    end
  end
end
