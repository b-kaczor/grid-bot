# frozen_string_literal: true

module Bybit
  class WebsocketListener
    module Connection
      def connect_and_listen(parent_task)
        account = ExchangeAccount.first
        return unless account

        url = ENV.fetch('BYBIT_WS_URL', 'wss://stream-testnet.bybit.com/v5/private')
        endpoint = Async::HTTP::Endpoint.parse(url)

        Async::WebSocket::Client.connect(endpoint) do |ws|
          setup_connection(ws, account)
          run_with_heartbeat(ws, parent_task)
        end
      end

      def setup_connection(connection, account)
        authenticate(connection, account)
        subscribe(connection)
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
        topics = %w[order.spot execution.spot wallet]
        connection.send_text(Oj.dump({ op: 'subscribe', args: topics }))
        Rails.logger.info('[WS] Subscribed to order.spot, execution.spot, wallet')
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
