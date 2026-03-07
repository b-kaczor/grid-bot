# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Bybit::RestClient do
  let(:api_key) { 'test_api_key' }
  let(:api_secret) { 'test_api_secret' }
  let(:rate_limiter) { instance_double(Bybit::RateLimiter) }
  let(:base_url) { 'https://api-testnet.bybit.com' }

  let(:client) do
    described_class.new(api_key:, api_secret:, rate_limiter:)
  end

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with('BYBIT_BASE_URL', anything).and_return(base_url)
    allow(rate_limiter).to receive(:check!)
    allow(rate_limiter).to receive(:update_from_headers)
  end

  def success_body(result = {})
    { retCode: 0, retMsg: 'OK', result: }
  end

  def error_body(code = 10_001, msg = 'Something went wrong')
    { retCode: code, retMsg: msg, result: {} }
  end

  describe '#get_tickers' do
    it 'returns a successful Exchange::Response' do
      stub_request(:get, "#{base_url}/v5/market/tickers")
        .with(query: { category: 'spot', symbol: 'ETHUSDT' })
        .to_return(status: 200, body: success_body({ list: [{ lastPrice: '2500.00' }] }).to_json,
                   headers: { 'Content-Type' => 'application/json' }
        )

      response = client.get_tickers(symbol: 'ETHUSDT')

      expect(response).to be_success
      expect(response.data[:list].first[:lastPrice]).to eq('2500.00')
    end

    it 'returns failure response on Bybit error retCode' do
      stub_request(:get, "#{base_url}/v5/market/tickers")
        .with(query: { category: 'spot', symbol: 'INVALID' })
        .to_return(status: 200, body: error_body(10_001, 'Invalid symbol').to_json,
                   headers: { 'Content-Type' => 'application/json' }
        )

      response = client.get_tickers(symbol: 'INVALID')

      expect(response).not_to be_success
      expect(response.error_code).to eq('10001')
      expect(response.error_message).to eq('Invalid symbol')
    end

    it 'does not include auth headers' do
      request_headers = nil
      stub_request(:get, "#{base_url}/v5/market/tickers")
        .with(query: { category: 'spot', symbol: 'ETHUSDT' })
        .to_return(status: 200, body: success_body.to_json,
                   headers: { 'Content-Type' => 'application/json' }
        )
        .with do |req|
        request_headers = req.headers
        true
      end

      client.get_tickers(symbol: 'ETHUSDT')

      expect(request_headers).not_to have_key('X-Bapi-Api-Key')
    end

    it 'calls rate limiter check! before request' do
      stub_request(:get, "#{base_url}/v5/market/tickers")
        .with(query: { category: 'spot', symbol: 'ETHUSDT' })
        .to_return(status: 200, body: success_body.to_json,
                   headers: { 'Content-Type' => 'application/json' }
        )

      client.get_tickers(symbol: 'ETHUSDT')

      expect(rate_limiter).to have_received(:check!).with(:ip_global)
    end

    it 'updates rate limiter from response headers' do
      stub_request(:get, "#{base_url}/v5/market/tickers")
        .with(query: { category: 'spot', symbol: 'ETHUSDT' })
        .to_return(status: 200, body: success_body.to_json,
                   headers: {
                     'Content-Type' => 'application/json',
                     'X-Bapi-Limit-Status' => '599',
                   }
        )

      client.get_tickers(symbol: 'ETHUSDT')

      expect(rate_limiter).to have_received(:update_from_headers).with(:ip_global, anything)
    end
  end

  describe '#get_instruments_info' do
    it 'returns instrument data' do
      stub_request(:get, "#{base_url}/v5/market/instruments-info")
        .with(query: { category: 'spot', symbol: 'ETHUSDT' })
        .to_return(status: 200, body: success_body({ list: [{ basePrecision: '0.000001' }] }).to_json,
                   headers: { 'Content-Type' => 'application/json' }
        )

      response = client.get_instruments_info(symbol: 'ETHUSDT')

      expect(response).to be_success
      expect(response.data[:list].first[:basePrecision]).to eq('0.000001')
    end
  end

  describe '#get_wallet_balance' do
    it 'includes auth headers and accountType param' do
      stub_request(:get, "#{base_url}/v5/account/wallet-balance")
        .with(query: hash_including(accountType: 'UNIFIED'),
              headers: { 'X-BAPI-API-KEY' => api_key }
             )
        .to_return(status: 200, body: success_body.to_json,
                   headers: { 'Content-Type' => 'application/json' }
        )

      response = client.get_wallet_balance

      expect(response).to be_success
    end

    it 'passes coin parameter when provided' do
      stub_request(:get, "#{base_url}/v5/account/wallet-balance")
        .with(query: { accountType: 'UNIFIED', coin: 'USDT' })
        .to_return(status: 200, body: success_body.to_json,
                   headers: { 'Content-Type' => 'application/json' }
        )

      response = client.get_wallet_balance(coin: 'USDT')

      expect(response).to be_success
    end
  end

  describe '#place_order' do
    it 'POSTs to /v5/order/create with correct params' do
      stub_request(:post, "#{base_url}/v5/order/create")
        .to_return(status: 200, body: success_body({ orderId: '123' }).to_json,
                   headers: { 'Content-Type' => 'application/json' }
        )

      response = client.place_order(
        symbol: 'ETHUSDT',
        side: 'Buy',
        order_type: 'Limit',
        qty: 0.1,
        price: 2500,
        order_link_id: 'g1L0B0'
      )

      expect(response).to be_success
      expect(response.data[:orderId]).to eq('123')
      expect(WebMock).to(
        have_requested(:post, "#{base_url}/v5/order/create")
                .with do |req|
                  body = JSON.parse(req.body, symbolize_names: true)
                  body[:category] == 'spot' &&
                    body[:symbol] == 'ETHUSDT' &&
                    body[:side] == 'Buy' &&
                    body[:orderType] == 'Limit' &&
                    body[:qty] == '0.1' &&
                    body[:price] == '2500' &&
                    body[:orderLinkId] == 'g1L0B0'
                end
      )
    end

    it 'includes auth headers' do
      stub_request(:post, "#{base_url}/v5/order/create")
        .to_return(status: 200, body: success_body.to_json,
                   headers: { 'Content-Type' => 'application/json' }
        )

      client.place_order(symbol: 'ETHUSDT', side: 'Buy', order_type: 'Limit', qty: 0.1, price: 2500)

      expect(WebMock).to(
        have_requested(:post, "#{base_url}/v5/order/create")
                .with { |req| req.headers['X-Bapi-Api-Key'] == api_key && req.headers['X-Bapi-Sign'].present? }
      )
    end

    it 'calls rate limiter with order_write bucket' do
      stub_request(:post, "#{base_url}/v5/order/create")
        .to_return(status: 200, body: success_body.to_json,
                   headers: { 'Content-Type' => 'application/json' }
        )

      client.place_order(symbol: 'ETHUSDT', side: 'Buy', order_type: 'Limit', qty: 0.1, price: 2500)

      expect(rate_limiter).to have_received(:check!).with(:order_write)
      expect(rate_limiter).to have_received(:check!).with(:ip_global)
    end
  end

  describe '#batch_place_orders' do
    it 'POSTs to /v5/order/create-batch' do
      stub_request(:post, "#{base_url}/v5/order/create-batch")
        .to_return(status: 200, body: success_body.to_json,
                   headers: { 'Content-Type' => 'application/json' }
        )

      orders = [
        { side: 'Buy', order_type: 'Limit', qty: 0.1, price: 2400 },
        { side: 'Buy', order_type: 'Limit', qty: 0.1, price: 2300 }
      ]

      response = client.batch_place_orders(symbol: 'ETHUSDT', orders:)

      expect(response).to be_success
      expect(WebMock).to(
        have_requested(:post, "#{base_url}/v5/order/create-batch")
                .with do |req|
                  body = JSON.parse(req.body, symbolize_names: true)
                  body[:category] == 'spot' && body[:request].length == 2
                end
      )
    end
  end

  describe '#cancel_order' do
    it 'POSTs to /v5/order/cancel' do
      stub_request(:post, "#{base_url}/v5/order/cancel")
        .to_return(status: 200, body: success_body.to_json,
                   headers: { 'Content-Type' => 'application/json' }
        )

      response = client.cancel_order(symbol: 'ETHUSDT', order_id: '123')

      expect(response).to be_success
      expect(WebMock).to(
        have_requested(:post, "#{base_url}/v5/order/cancel")
                .with do |req|
                  body = JSON.parse(req.body, symbolize_names: true)
                  body[:orderId] == '123' && body[:category] == 'spot'
                end
      )
    end

    it 'supports cancel by order_link_id' do
      stub_request(:post, "#{base_url}/v5/order/cancel")
        .to_return(status: 200, body: success_body.to_json,
                   headers: { 'Content-Type' => 'application/json' }
        )

      client.cancel_order(symbol: 'ETHUSDT', order_link_id: 'g1L0B0')

      expect(WebMock).to(
        have_requested(:post, "#{base_url}/v5/order/cancel")
                .with do |req|
                  body = JSON.parse(req.body, symbolize_names: true)
                  body[:orderLinkId] == 'g1L0B0'
                end
      )
    end
  end

  describe '#cancel_all_orders' do
    it 'POSTs to /v5/order/cancel-all' do
      stub_request(:post, "#{base_url}/v5/order/cancel-all")
        .to_return(status: 200, body: success_body.to_json,
                   headers: { 'Content-Type' => 'application/json' }
        )

      response = client.cancel_all_orders(symbol: 'ETHUSDT')

      expect(response).to be_success
    end
  end

  describe '#get_order_history' do
    it 'GETs /v5/order/history with auth headers' do
      stub_request(:get, "#{base_url}/v5/order/history")
        .with(query: hash_including(category: 'spot', symbol: 'ETHUSDT'),
              headers: { 'X-BAPI-API-KEY' => api_key }
             )
        .to_return(status: 200, body: success_body({ list: [{ orderId: '999', orderStatus: 'Filled' }] }).to_json,
                   headers: { 'Content-Type' => 'application/json' }
        )

      response = client.get_order_history(symbol: 'ETHUSDT')

      expect(response).to be_success
      expect(response.data[:list].first[:orderId]).to eq('999')
    end

    it 'passes order_id filter' do
      stub_request(:get, "#{base_url}/v5/order/history")
        .with(query: hash_including(orderId: '123'))
        .to_return(status: 200, body: success_body({ list: [] }).to_json,
                   headers: { 'Content-Type' => 'application/json' }
        )

      response = client.get_order_history(symbol: 'ETHUSDT', order_id: '123')

      expect(response).to be_success
    end

    it 'passes order_link_id filter' do
      stub_request(:get, "#{base_url}/v5/order/history")
        .with(query: hash_including(orderLinkId: 'g1-L0-B-0'))
        .to_return(status: 200, body: success_body({ list: [] }).to_json,
                   headers: { 'Content-Type' => 'application/json' }
        )

      response = client.get_order_history(symbol: 'ETHUSDT', order_link_id: 'g1-L0-B-0')

      expect(response).to be_success
    end

    it 'passes cursor for pagination' do
      stub_request(:get, "#{base_url}/v5/order/history")
        .with(query: hash_including(cursor: 'page2'))
        .to_return(status: 200, body: success_body({ list: [] }).to_json,
                   headers: { 'Content-Type' => 'application/json' }
        )

      response = client.get_order_history(symbol: 'ETHUSDT', cursor: 'page2')

      expect(response).to be_success
    end

    it 'calls rate limiter with order_batch bucket' do
      stub_request(:get, "#{base_url}/v5/order/history")
        .with(query: hash_including(category: 'spot'))
        .to_return(status: 200, body: success_body({ list: [] }).to_json,
                   headers: { 'Content-Type' => 'application/json' }
        )

      client.get_order_history(symbol: 'ETHUSDT')

      expect(rate_limiter).to have_received(:check!).with(:order_batch)
      expect(rate_limiter).to have_received(:check!).with(:ip_global)
    end
  end

  describe '#get_open_orders' do
    it 'GETs /v5/order/realtime with auth headers' do
      stub_request(:get, "#{base_url}/v5/order/realtime")
        .with(query: hash_including(category: 'spot', symbol: 'ETHUSDT'),
              headers: { 'X-BAPI-API-KEY' => api_key }
             )
        .to_return(status: 200, body: success_body({ list: [] }).to_json,
                   headers: { 'Content-Type' => 'application/json' }
        )

      response = client.get_open_orders(symbol: 'ETHUSDT')

      expect(response).to be_success
    end

    it 'passes cursor for pagination' do
      stub_request(:get, "#{base_url}/v5/order/realtime")
        .with(query: hash_including(cursor: 'abc123'))
        .to_return(status: 200, body: success_body({ list: [] }).to_json,
                   headers: { 'Content-Type' => 'application/json' }
        )

      response = client.get_open_orders(symbol: 'ETHUSDT', cursor: 'abc123')

      expect(response).to be_success
    end
  end

  describe '#set_dcp' do
    it 'POSTs to /v5/order/disconnected-cancel-all' do
      stub_request(:post, "#{base_url}/v5/order/disconnected-cancel-all")
        .to_return(status: 200, body: success_body.to_json,
                   headers: { 'Content-Type' => 'application/json' }
        )

      response = client.set_dcp(time_window: 10)

      expect(response).to be_success
      expect(WebMock).to(
        have_requested(:post, "#{base_url}/v5/order/disconnected-cancel-all")
                .with do |req|
                  body = JSON.parse(req.body, symbolize_names: true)
                  body[:timeWindow] == 10
                end
      )
    end
  end

  describe 'error handling' do
    it 'raises Bybit::NetworkError on timeout' do
      stub_request(:get, "#{base_url}/v5/market/tickers")
        .with(query: { category: 'spot', symbol: 'ETHUSDT' })
        .to_timeout

      expect { client.get_tickers(symbol: 'ETHUSDT') }
        .to raise_error(Bybit::NetworkError)
    end

    it 'raises Bybit::AuthenticationError on HTTP 401' do
      stub_request(:get, "#{base_url}/v5/account/wallet-balance")
        .with(query: hash_including(accountType: 'UNIFIED'))
        .to_return(status: 401, body: { retCode: 10_003, retMsg: 'Invalid apiKey' }.to_json,
                   headers: { 'Content-Type' => 'application/json' }
        )

      expect { client.get_wallet_balance }
        .to raise_error(Bybit::AuthenticationError, /401/)
    end

    it 'raises Bybit::AuthenticationError on HTTP 403' do
      stub_request(:get, "#{base_url}/v5/account/wallet-balance")
        .with(query: hash_including(accountType: 'UNIFIED'))
        .to_return(status: 403, body: { retCode: 10_004, retMsg: 'Forbidden' }.to_json,
                   headers: { 'Content-Type' => 'application/json' }
        )

      expect { client.get_wallet_balance }
        .to raise_error(Bybit::AuthenticationError, /403/)
    end

    it 'returns error response on non-200 HTTP status' do
      stub_request(:get, "#{base_url}/v5/market/tickers")
        .with(query: { category: 'spot', symbol: 'ETHUSDT' })
        .to_return(status: 500, body: 'Internal Server Error',
                   headers: { 'Content-Type' => 'text/plain' }
        )

      response = client.get_tickers(symbol: 'ETHUSDT')

      expect(response).not_to be_success
      expect(response.error_code).to eq('HTTP_ERROR')
    end

    it 'raises Bybit::RateLimitError when rate limiter blocks' do
      allow(rate_limiter).to receive(:check!).with(:ip_global)
        .and_raise(Bybit::RateLimitError, 'Rate limit exceeded for ip_global')

      expect { client.get_tickers(symbol: 'ETHUSDT') }
        .to raise_error(Bybit::RateLimitError)
    end
  end

  describe 'constructor' do
    it 'accepts exchange_account model' do
      account = instance_double(ExchangeAccount, api_key: 'model_key', api_secret: 'model_secret')

      stub_request(:get, "#{base_url}/v5/market/tickers")
        .with(query: { category: 'spot', symbol: 'ETHUSDT' })
        .to_return(status: 200, body: success_body.to_json,
                   headers: { 'Content-Type' => 'application/json' }
        )

      model_client = described_class.new(exchange_account: account, rate_limiter:)
      response = model_client.get_tickers(symbol: 'ETHUSDT')

      expect(response).to be_success
    end
  end
end
