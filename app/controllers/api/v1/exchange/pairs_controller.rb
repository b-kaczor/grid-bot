# frozen_string_literal: true

module Api
  module V1
    module Exchange
      class PairsController < BaseController
        CACHE_TTL = 5.minutes.to_i

        def show
          quote = params.fetch(:quote, 'USDT')
          cache_key = "exchange:pairs:#{quote}"

          cached = redis.get(cache_key)
          if cached
            render json: Oj.load(cached)
            return
          end

          pairs = fetch_and_filter_pairs(quote)
          payload = { pairs: }

          redis.set(cache_key, Oj.dump(payload, mode: :compat), ex: CACHE_TTL)
          render json: payload
        end

        private

        def fetch_and_filter_pairs(quote) # rubocop:disable Metrics/AbcSize
          client = Bybit::RestClient.new
          instruments_response = client.get_instruments_info
          tickers_response = client.get_tickers

          return [] unless instruments_response.success? && tickers_response.success?

          ticker_map = build_ticker_map(tickers_response.data[:list] || [])
          instruments = instruments_response.data[:list] || []

          instruments
            .select { |i| i[:quoteCoin] == quote }
            .map { |i| build_pair(i, ticker_map) }
        end

        def build_ticker_map(tickers)
          tickers.to_h { |t| [t[:symbol], t[:usdIndexPrice] || t[:lastPrice]] }
        end

        def build_pair(instrument, ticker_map)
          lot = instrument[:lotSizeFilter] || {}
          price = instrument[:priceFilter] || {}
          {
            symbol: instrument[:symbol],
            base_coin: instrument[:baseCoin],
            quote_coin: instrument[:quoteCoin],
            last_price: ticker_map[instrument[:symbol]],
            tick_size: price[:tickSize],
            min_order_qty: lot[:minOrderQty],
            min_order_amt: lot[:minOrderAmt],
          }
        end

        def redis
          @redis ||= Redis.new(url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0'))
        end
      end
    end
  end
end
