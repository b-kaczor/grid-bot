# frozen_string_literal: true

module Bybit
  class WebsocketListener
    module Connection
      def connect_and_listen(parent_task)
        account = ExchangeAccount.first
        return unless account

        urls = Bybit::Urls.for(account.environment)
        private_url = ENV.fetch('BYBIT_WS_URL') { urls[:ws_private] }
        public_url = urls[:ws_public]

        public_task = start_public_connection(public_url, parent_task)
        start_private_connection(private_url, account, parent_task)
      ensure
        public_task&.stop
      end

      def start_private_connection(url, account, parent_task)
        endpoint = ws_endpoint(url)
        Async::WebSocket::Client.connect(endpoint) do |ws|
          authenticate(ws, account)
          subscribe_private(ws)
          register_dcp(account)
          run_with_heartbeat(ws, parent_task)
        end
      end

      def start_public_connection(url, parent_task)
        pairs = Bot.running.pluck(:pair).uniq
        return if pairs.empty?

        parent_task.async do
          Async::WebSocket::Client.connect(ws_endpoint(url)) do |ws|
            subscribe_public(ws, pairs)
            run_with_heartbeat(ws, parent_task)
          end
        rescue StandardError => e
          Rails.logger.error("[WS] Public connection error: #{e.message}")
        end
      end

      def run_with_heartbeat(connection, parent_task)
        heartbeat_task = start_heartbeat(connection, parent_task)
        read_loop(connection, parent_task)
      ensure
        heartbeat_task&.stop
      end

      def start_heartbeat(connection, parent_task)
        parent_task.async do
          loop do
            break if @shutdown

            sleep HEARTBEAT_INTERVAL
            Rails.logger.info('[WS] Heartbeat message sent')
            connection.send_text(Oj.dump({ op: 'ping' }))
          end
        end
      end

      def authenticate(connection, account)
        expires = ((Time.now.to_f * 1000).to_i + 5000).to_s
        signature = OpenSSL::HMAC.hexdigest('SHA256', account.api_secret, "GET/realtime#{expires}")

        connection.send_text(Oj.dump({ op: 'auth', args: [account.api_key, expires, signature] }))
        Rails.logger.info('[WS] Authentication message sent')
      end

      def subscribe_private(connection)
        topics = %w[order.spot execution.spot wallet]
        connection.send_text(Oj.dump({ op: 'subscribe', args: topics }))
        Rails.logger.info("[WS] Private subscribed to: #{topics.join(', ')}")
      end

      def subscribe_public(connection, pairs)
        topics = pairs.map { |pair| "tickers.#{pair}" }
        connection.send_text(Oj.dump({ op: 'subscribe', args: topics }))
        Rails.logger.info("[WS] Public subscribed to: #{topics.join(', ')}")
      end

      def ws_endpoint(url)
        Async::HTTP::Endpoint.parse(url, alpn_protocols: Async::HTTP::Protocol::HTTP11.names)
      end

      def register_dcp(account)
        if account.environment == 'demo'
          Rails.logger.info('[WS] DCP skipped (not supported on demo)')
          return
        end
        response = dcp_client(account).set_dcp(time_window: 40)
        if response.success?
          Rails.logger.info('[WS] DCP registered (40s window)')
          @redis.set('grid:dcp:registered_at', Time.current.to_i.to_s)
        else
          Rails.logger.warn("[WS] DCP registration failed: #{response.error_message}")
        end
      end

      def dcp_client(acct)
        Bybit::RestClient.new(api_key: acct.api_key, api_secret: acct.api_secret, environment: acct.environment)
      end

      def read_loop(connection, parent_task)
        loop do
          break if @shutdown

          message = parent_task.with_timeout(WS_READ_TIMEOUT) { connection.read }
          break unless message

          data = Oj.load(message.buffer, symbol_keys: true)
          process_message(data)
        end
        connection.send_close if @shutdown
      rescue StandardError => e
        Rails.logger.warn("[WS] Error during shutdown: #{e.message}")
      end
    end
  end
end
