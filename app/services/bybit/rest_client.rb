# frozen_string_literal: true

module Bybit
  class RestClient < Exchange::Adapter
    BUCKET_MAP = {
      place_order: :order_write,
      cancel_order: :order_write,
      batch_place_orders: :order_batch,
      cancel_all_orders: :order_batch,
      get_open_orders: :order_batch,
      get_wallet_balance: :ip_global,
      get_tickers: :ip_global,
      get_instruments_info: :ip_global,
      set_dcp: :order_write,
    }.freeze

    def initialize(exchange_account: nil, api_key: nil, api_secret: nil, rate_limiter: nil)
      super()
      @api_key = api_key || exchange_account&.api_key || ENV.fetch('BYBIT_API_KEY', nil)
      @api_secret = api_secret || exchange_account&.api_secret || ENV.fetch('BYBIT_API_SECRET', nil)
      @auth = Auth.new(api_key: @api_key, api_secret: @api_secret) if @api_key && @api_secret
      @rate_limiter = rate_limiter || RateLimiter.new
      @connection = build_connection
    end

    # Market data (no auth)

    def get_tickers(symbol:)
      get('/v5/market/tickers', { category: 'spot', symbol: }, authenticated: false, bucket: :get_tickers)
    end

    def get_instruments_info(symbol:)
      get(
        '/v5/market/instruments-info', { category: 'spot', symbol: }, authenticated: false,
                                                                      bucket: :get_instruments_info
      )
    end

    # Account (auth required)

    def get_wallet_balance(coin: nil)
      params = { accountType: 'UNIFIED' }
      params[:coin] = coin if coin
      get('/v5/account/wallet-balance', params, authenticated: true, bucket: :get_wallet_balance)
    end

    def get_open_orders(symbol:, cursor: nil, limit: 50)
      params = { category: 'spot', symbol: }
      params[:cursor] = cursor if cursor
      params[:limit] = limit
      get('/v5/order/realtime', params, authenticated: true, bucket: :get_open_orders)
    end

    # Orders (auth required)

    def place_order(symbol:, side:, order_type:, qty:, price: nil, order_link_id: nil, time_in_force: 'GTC')
      params = {
        category: 'spot',
        symbol:,
        side:,
        orderType: order_type,
        qty: qty.to_s,
      }
      params[:price] = price.to_s if price
      params[:orderLinkId] = order_link_id if order_link_id
      params[:timeInForce] = time_in_force
      post('/v5/order/create', params, bucket: :place_order)
    end

    def batch_place_orders(symbol:, orders:)
      params = {
        category: 'spot',
        request: orders.map { |o| build_order_params(symbol, o) },
      }
      post('/v5/order/create-batch', params, bucket: :batch_place_orders)
    end

    def cancel_order(symbol:, order_id: nil, order_link_id: nil)
      params = { category: 'spot', symbol: }
      params[:orderId] = order_id if order_id
      params[:orderLinkId] = order_link_id if order_link_id
      post('/v5/order/cancel', params, bucket: :cancel_order)
    end

    def cancel_all_orders(symbol:)
      post('/v5/order/cancel-all', { category: 'spot', symbol: }, bucket: :cancel_all_orders)
    end

    # Safety

    def set_dcp(time_window:)
      post('/v5/order/disconnected-cancel-all', { timeWindow: time_window }, bucket: :set_dcp)
    end

    private

    def build_connection
      base_url = ENV.fetch('BYBIT_BASE_URL', 'https://api-testnet.bybit.com')
      Faraday.new(url: base_url) do |f|
        f.request :json
        f.response :json, parser_options: { symbolize_names: true }
        f.request :retry, max: 2, interval: 0.5,
                          methods: [:get],
                          exceptions: [Faraday::TimeoutError, Faraday::ConnectionFailed]
        f.adapter Faraday.default_adapter
      end
    end

    def get(path, params, authenticated:, bucket:)
      rate_bucket = BUCKET_MAP[bucket]
      @rate_limiter.check!(rate_bucket)
      @rate_limiter.check!(:ip_global) unless rate_bucket == :ip_global

      query_string = URI.encode_www_form(params.compact)

      headers = {}
      if authenticated
        timestamp = (Time.now.to_f * 1000).to_i
        headers = @auth.sign_request(timestamp:, params_string: query_string)
      end

      response = @connection.get(path) do |req|
        req.params = params.compact
        headers.each { |k, v| req.headers[k] = v }
      end

      @rate_limiter.update_from_headers(rate_bucket, response.headers)
      handle_response(response)
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
      raise Bybit::NetworkError, e.message
    end

    def post(path, params, bucket:)
      rate_bucket = BUCKET_MAP[bucket]
      @rate_limiter.check!(rate_bucket)
      @rate_limiter.check!(:ip_global) unless rate_bucket == :ip_global

      timestamp = (Time.now.to_f * 1000).to_i
      json_body = Oj.dump(params, mode: :compat)
      headers = @auth.sign_request(timestamp:, params_string: json_body)

      response = @connection.post(path) do |req|
        req.body = params
        headers.each { |k, v| req.headers[k] = v }
      end

      @rate_limiter.update_from_headers(rate_bucket, response.headers)
      handle_response(response)
    rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
      raise Bybit::NetworkError, e.message
    end

    def handle_response(response)
      if [401, 403].include?(response.status)
        raise Bybit::AuthenticationError, "HTTP #{response.status}: #{response.body}"
      end

      body = response.body
      return error_response('HTTP_ERROR', "HTTP #{response.status}") unless response.success?
      return error_response('PARSE_ERROR', 'Invalid response body') unless body.is_a?(Hash)

      if body[:retCode].zero?
        Exchange::Response.new(success: true, data: body[:result])
      else
        Exchange::Response.new(
          success: false,
          data: body[:result],
          error_code: body[:retCode].to_s,
          error_message: body[:retMsg]
        )
      end
    end

    def error_response(code, message)
      Exchange::Response.new(success: false, error_code: code, error_message: message)
    end

    def build_order_params(symbol, order)
      {
        symbol:,
        side: order[:side],
        orderType: order[:order_type],
        qty: order[:qty].to_s,
        price: order[:price]&.to_s,
        orderLinkId: order[:order_link_id],
        timeInForce: order.fetch(:time_in_force, 'GTC'),
      }.compact
    end
  end
end
