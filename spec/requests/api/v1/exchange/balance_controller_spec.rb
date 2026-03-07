# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Exchange::BalanceController', type: :request do
  let(:exchange_account) { create(:exchange_account) }
  let(:client) { instance_double(Bybit::RestClient) }

  before do
    allow(Bybit::RestClient).to receive(:new).and_return(client)
  end

  describe 'GET /api/v1/exchange/balance' do
    context 'with a configured exchange account' do
      before do
        exchange_account
        allow(client).to receive(:get_wallet_balance).and_return(wallet_response)
      end

      let(:wallet_response) do
        Exchange::Response.new(
          success: true,
          data: {
            list: [
              {
                coin: [
                  { coin: 'USDT', availableToWithdraw: '5000.00', locked: '1000.00', walletBalance: '6000.00' },
                  { coin: 'ETH', availableToWithdraw: '0.5', locked: '2.0', walletBalance: '2.5' }
                ],
              }
            ],
          }
        )
      end

      it 'returns wallet balance' do
        get '/api/v1/exchange/balance'
        expect(response).to have_http_status(:ok)

        body = Oj.load(response.body)
        coins = body['balance']['coins']
        expect(coins.size).to eq(2)
      end

      it 'serializes coin fields correctly' do
        get '/api/v1/exchange/balance'
        body = Oj.load(response.body)
        usdt = body['balance']['coins'].find { |c| c['coin'] == 'USDT' }
        expect(usdt['available']).to eq('5000.00')
        expect(usdt['locked']).to eq('1000.00')
        expect(usdt['total']).to eq('6000.00')
      end

      it 'returns 502 when API call fails' do
        allow(client).to receive(:get_wallet_balance).and_return(
          Exchange::Response.new(success: false, error_message: 'Exchange timeout')
        )
        get '/api/v1/exchange/balance'
        expect(response).to have_http_status(:bad_gateway)
        body = Oj.load(response.body)
        expect(body['error']).to eq('Exchange timeout')
      end
    end

    context 'without exchange account configured' do
      it 'returns 503 with setup_required' do
        get '/api/v1/exchange/balance'
        expect(response).to have_http_status(:service_unavailable)
        body = Oj.load(response.body)
        expect(body['setup_required']).to be true
      end
    end
  end
end
