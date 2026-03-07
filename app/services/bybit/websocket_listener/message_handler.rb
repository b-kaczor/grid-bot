# frozen_string_literal: true

module Bybit
  class WebsocketListener
    module MessageHandler
      def process_message(data)
        case data[:topic]
        when 'order.spot'
          data[:data]&.each { |order_data| process_order_event(order_data) }
        when 'execution.spot'
          Rails.logger.debug { "[WS] Execution event: #{data[:data]&.length} entries" }
        when 'wallet'
          Rails.logger.debug { '[WS] Wallet update received' }
        else
          handle_system_message(data)
        end
      end

      def process_order_event(order_data)
        return unless order_data[:orderStatus] == 'Filled'

        publish_to_redis_stream(order_data)
        OrderFillWorker.perform_async(Oj.dump(order_data))
        Rails.logger.info("[WS] Fill detected: #{order_data[:orderLinkId]} (#{order_data[:side]})")
      end

      def publish_to_redis_stream(order_data)
        @redis.xadd(STREAM_KEY, stream_entry(order_data), maxlen: STREAM_MAXLEN, approximate: true)
      end

      def stream_entry(order_data)
        {
          order_id: order_data[:orderId],
          order_link_id: order_data[:orderLinkId],
          symbol: order_data[:symbol],
          side: order_data[:side],
          status: order_data[:orderStatus],
          qty: order_data[:qty],
          price: order_data[:avgPrice],
          timestamp: Time.now.to_i.to_s,
        }
      end

      def handle_system_message(data)
        case data[:op]
        when 'pong'
          Rails.logger.debug { '[WS] Pong received' }
        when 'auth'
          log_auth_result(data)
        when 'subscribe'
          Rails.logger.info("[WS] Subscription confirmed: #{data[:conn_id]}")
        end
      end

      def log_auth_result(data)
        if data[:success]
          Rails.logger.info('[WS] Authentication successful')
        else
          Rails.logger.error("[WS] Authentication failed: #{data[:ret_msg]}")
        end
      end
    end
  end
end
