# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::ExchangeAccounts', type: :request do
  describe 'GET /api/v1/exchange_account/current' do
    context 'when no account exists' do
      it 'returns 404 with setup_required' do
        get '/api/v1/exchange_account/current'

        expect(response).to have_http_status(:not_found)
        body = Oj.load(response.body)
        expect(body['setup_required']).to be true
      end
    end

    context 'when an account exists' do
      let!(:account) { create(:exchange_account, name: 'My Demo', api_key: 'key_abcdef1234', api_secret: 'secret_xyz') }

      it 'returns 200 with masked key' do
        get '/api/v1/exchange_account/current'

        expect(response).to have_http_status(:ok)
        body = Oj.load(response.body)
        expect(body['account']['id']).to eq(account.id)
        expect(body['account']['name']).to eq('My Demo')
        expect(body['account']['exchange']).to eq('bybit')
        expect(body['account']['environment']).to eq('testnet')
        expect(body['account']['api_key_hint']).to eq('********1234')
      end

      it 'never exposes full api_key or api_secret in response' do
        get '/api/v1/exchange_account/current'

        body = response.body
        expect(body).not_to include('key_abcdef1234')
        expect(body).not_to include('secret_xyz')
        parsed = Oj.load(body)
        expect(parsed['account']).not_to have_key('api_key')
        expect(parsed['account']).not_to have_key('api_secret')
      end
    end
  end

  describe 'POST /api/v1/exchange_account' do
    let(:valid_params) do
      {
        exchange_account: {
          name: 'My Account',
          exchange: 'bybit',
          environment: 'demo',
          api_key: 'new_api_key_9999',
          api_secret: 'new_api_secret_8888',
        },
      }
    end

    context 'when no account exists' do
      it 'creates the account and returns 201' do
        expect { post '/api/v1/exchange_account', params: valid_params }
          .to change(ExchangeAccount, :count).by(1)

        expect(response).to have_http_status(:created)
        body = Oj.load(response.body)
        expect(body['account']['name']).to eq('My Account')
        expect(body['account']['environment']).to eq('demo')
        expect(body['account']['api_key_hint']).to eq('********9999')
      end

      it 'never exposes full secrets in the create response' do
        post '/api/v1/exchange_account', params: valid_params

        body = response.body
        expect(body).not_to include('new_api_key_9999')
        expect(body).not_to include('new_api_secret_8888')
      end
    end

    context 'when an account already exists' do
      before { create(:exchange_account) }

      it 'returns 422' do
        post '/api/v1/exchange_account', params: valid_params

        expect(response).to have_http_status(:unprocessable_content)
        body = Oj.load(response.body)
        expect(body['error']).to include('already exists')
      end
    end

    context 'with invalid params' do
      it 'returns 422 for missing required fields' do
        post '/api/v1/exchange_account', params: { exchange_account: { name: '' } }

        expect(response).to have_http_status(:unprocessable_content)
      end
    end
  end

  describe 'PATCH /api/v1/exchange_account/current' do
    context 'when no account exists' do
      it 'returns 404' do
        patch '/api/v1/exchange_account/current', params: { exchange_account: { name: 'Updated' } }

        expect(response).to have_http_status(:not_found)
      end
    end

    context 'when an account exists' do
      let!(:account) do
        create(
          :exchange_account, name: 'Original', environment: 'testnet',
                             api_key: 'original_key_1234', api_secret: 'original_secret_5678'
        )
      end

      it 'updates the account fields' do
        patch '/api/v1/exchange_account/current', params: {
          exchange_account: { name: 'Updated Name', environment: 'demo' },
        }

        expect(response).to have_http_status(:ok)
        body = Oj.load(response.body)
        expect(body['account']['name']).to eq('Updated Name')
        expect(body['account']['environment']).to eq('demo')
      end

      it 'keeps existing secrets when not provided in params' do
        patch '/api/v1/exchange_account/current', params: {
          exchange_account: { name: 'New Name' },
        }

        expect(response).to have_http_status(:ok)
        account.reload
        expect(account.api_key).to eq('original_key_1234')
        expect(account.api_secret).to eq('original_secret_5678')
      end

      it 'updates secrets when provided' do
        patch '/api/v1/exchange_account/current', params: {
          exchange_account: { api_key: 'brand_new_key_abcd', api_secret: 'brand_new_secret_efgh' },
        }

        expect(response).to have_http_status(:ok)
        account.reload
        expect(account.api_key).to eq('brand_new_key_abcd')
        expect(account.api_secret).to eq('brand_new_secret_efgh')
      end

      it 'never exposes full secrets in the update response' do
        patch '/api/v1/exchange_account/current', params: {
          exchange_account: { name: 'Test' },
        }

        body = response.body
        expect(body).not_to include('original_key_1234')
        expect(body).not_to include('original_secret_5678')
      end
    end
  end

  describe 'POST /api/v1/exchange_account/test' do
    let(:rate_limiter) { instance_double(Bybit::RateLimiter, check!: nil, update_from_headers: nil) }

    before do
      allow(Bybit::RateLimiter).to receive(:new).and_return(rate_limiter)
    end

    context 'with valid credentials' do
      before do
        stub_request(:get, 'https://api-demo.bybit.com/v5/account/wallet-balance')
          .with(query: hash_including(accountType: 'UNIFIED'))
          .to_return(
            status: 200,
            body: {
              retCode: 0,
              retMsg: 'OK',
              result: { list: [{ coin: [{ coin: 'USDT', walletBalance: '10000.50' }] }] },
            }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )
      end

      it 'returns success with balance' do
        post '/api/v1/exchange_account/test', params: {
          api_key: 'test_key', api_secret: 'test_secret', environment: 'demo'
        }

        expect(response).to have_http_status(:ok)
        body = Oj.load(response.body)
        expect(body['success']).to be true
        expect(body['balance']).to include('USDT')
      end
    end

    context 'with invalid credentials' do
      before do
        stub_request(:get, 'https://api-testnet.bybit.com/v5/account/wallet-balance')
          .with(query: hash_including(accountType: 'UNIFIED'))
          .to_return(
            status: 200,
            body: { retCode: 10_003, retMsg: 'Invalid API key', result: {} }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )
      end

      it 'returns failure with error message' do
        post '/api/v1/exchange_account/test', params: {
          api_key: 'bad_key', api_secret: 'bad_secret', environment: 'testnet'
        }

        expect(response).to have_http_status(:ok)
        body = Oj.load(response.body)
        expect(body['success']).to be false
        expect(body['error']).to be_present
      end
    end

    context 'when authentication fails with HTTP 401' do
      before do
        stub_request(:get, 'https://api-testnet.bybit.com/v5/account/wallet-balance')
          .with(query: hash_including(accountType: 'UNIFIED'))
          .to_return(
            status: 401,
            body: { retCode: 10_003, retMsg: 'Invalid apiKey' }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )
      end

      it 'returns failure with error message' do
        post '/api/v1/exchange_account/test', params: {
          api_key: 'bad_key', api_secret: 'bad_secret', environment: 'testnet'
        }

        expect(response).to have_http_status(:ok)
        body = Oj.load(response.body)
        expect(body['success']).to be false
        expect(body['error']).to be_present
      end
    end
  end
end
