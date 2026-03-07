# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Exchange::PairsController', type: :request do
  let(:client) { instance_double(Bybit::RestClient) }
  let(:mock_redis) { instance_double(Redis) }

  let(:instruments_response) do
    Exchange::Response.new(
      success: true,
      data: {
        list: [
          {
            symbol: 'ETHUSDT',
            baseCoin: 'ETH',
            quoteCoin: 'USDT',
            lotSizeFilter: { minOrderQty: '0.001', minOrderAmt: '1' },
            priceFilter: { tickSize: '0.01' },
          },
          {
            symbol: 'BTCUSDT',
            baseCoin: 'BTC',
            quoteCoin: 'USDT',
            lotSizeFilter: { minOrderQty: '0.0001', minOrderAmt: '5' },
            priceFilter: { tickSize: '0.1' },
          },
          {
            symbol: 'ETHBTC',
            baseCoin: 'ETH',
            quoteCoin: 'BTC',
            lotSizeFilter: { minOrderQty: '0.01', minOrderAmt: '0.001' },
            priceFilter: { tickSize: '0.00001' },
          }
        ],
      }
    )
  end

  let(:tickers_response) do
    Exchange::Response.new(
      success: true,
      data: {
        list: [
          { symbol: 'ETHUSDT', lastPrice: '2500.00' },
          { symbol: 'BTCUSDT', lastPrice: '65000.00' },
          { symbol: 'ETHBTC', lastPrice: '0.03846' }
        ],
      }
    )
  end

  before do
    allow(Bybit::RestClient).to receive(:new).and_return(client)
    allow(client).to receive_messages(get_instruments_info: instruments_response, get_tickers: tickers_response)
    allow(Redis).to receive(:new).and_return(mock_redis)
    allow(mock_redis).to receive(:get).and_return(nil)
    allow(mock_redis).to receive(:set)
  end

  describe 'GET /api/v1/exchange/pairs' do
    it 'returns USDT pairs by default' do
      get '/api/v1/exchange/pairs'
      expect(response).to have_http_status(:ok)

      body = Oj.load(response.body)
      symbols = body['pairs'].pluck('symbol')
      expect(symbols).to contain_exactly('ETHUSDT', 'BTCUSDT')
      expect(symbols).not_to include('ETHBTC')
    end

    it 'serializes pair fields correctly' do
      get '/api/v1/exchange/pairs'
      body = Oj.load(response.body)
      pair = body['pairs'].find { |p| p['symbol'] == 'ETHUSDT' }
      expect(pair['base_coin']).to eq('ETH')
      expect(pair['quote_coin']).to eq('USDT')
      expect(pair['last_price']).to eq('2500.00')
      expect(pair['tick_size']).to eq('0.01')
      expect(pair['min_order_qty']).to eq('0.001')
      expect(pair['min_order_amt']).to eq('1')
    end

    it 'filters by custom quote param' do
      get '/api/v1/exchange/pairs', params: { quote: 'BTC' }
      body = Oj.load(response.body)
      symbols = body['pairs'].pluck('symbol')
      expect(symbols).to eq(['ETHBTC'])
    end

    it 'caches results in Redis with 5-minute TTL' do
      get '/api/v1/exchange/pairs'
      expect(mock_redis).to have_received(:set).with(
        'exchange:pairs:USDT',
        anything,
        ex: 300
      )
    end

    it 'serves from cache on subsequent requests' do
      cached_payload = Oj.dump({ pairs: [{ symbol: 'CACHED' }] }, mode: :compat)
      allow(mock_redis).to receive(:get).with('exchange:pairs:USDT').and_return(cached_payload)

      get '/api/v1/exchange/pairs'
      body = Oj.load(response.body)
      expect(body['pairs'].first['symbol']).to eq('CACHED')
      expect(client).not_to have_received(:get_instruments_info)
    end

    it 'returns empty pairs when API fails' do
      allow(client).to receive(:get_instruments_info).and_return(
        Exchange::Response.new(success: false, error_message: 'API error')
      )
      get '/api/v1/exchange/pairs'
      body = Oj.load(response.body)
      expect(body['pairs']).to eq([])
    end
  end
end
