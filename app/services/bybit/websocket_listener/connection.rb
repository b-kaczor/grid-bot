# frozen_string_literal: true

module Bybit
  class WebsocketListener
    module Connection
      def connect_and_listen(parent_task)
        account = ExchangeAccount.first
        return unless account

        url = ENV.fetch('BYBIT_WS_URL') { Bybit::Urls.for(account.environment)[:ws_private] }
        endpoint = Async::HTTP::Endpoint.parse(url, alpn_protocols: Async::HTTP::Protocol::HTTP11.names)

        Async::WebSocket::Client.connect(endpoint) do |ws|
          setup_connection(ws, account)
          run_with_heartbeat(ws, parent_task)
        end
      end

      def setup_connection(connection, account)
        authenticate(connection, account)
        subscribe(connection)
        register_dcp(account)
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

      def subscribe(connection)
        topics = %w[order.spot execution.spot wallet dcp]
        Bot.running.pluck(:pair).uniq.each { |pair| topics << "tickers.#{pair}" }
        connection.send_text(Oj.dump({ op: 'subscribe', args: topics }))
        Rails.logger.info("[WS] Subscribed to: #{topics.join(', ')}")
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

      def dcp_client(account)
        Bybit::RestClient.new(
          api_key: account.api_key,
          api_secret: account.api_secret,
          environment: account.environment
        )
      end

      def read_loop(connection, parent_task)
        loop do
          break if @shutdown

          message = parent_task.with_timeout(WS_READ_TIMEOUT) { connection.read }
          break unless message

          data = Oj.load(message.buffer, symbol_keys: true)
          process_message(data)
        end

        graceful_shutdown(connection) if @shutdown
      end

      def graceful_shutdown(connection)
        Rails.logger.info('[WS] Graceful shutdown initiated')
        connection.send_close
      rescue StandardError => e
        Rails.logger.warn("[WS] Error during shutdown: #{e.message}")
      end
    end
  end
end
