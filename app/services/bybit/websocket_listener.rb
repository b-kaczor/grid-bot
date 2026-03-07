# frozen_string_literal: true

require 'async'
require 'async/websocket/client'
require 'async/http/endpoint'

module Bybit
  class WebsocketListener
    include Connection
    include MessageHandler
    include BotManager

    WS_READ_TIMEOUT = 30
    HEARTBEAT_INTERVAL = 20
    MAX_BACKOFF = 30
    INITIAL_BACKOFF = 1
    MAINTENANCE_RETRY_INTERVAL = 30
    STREAM_KEY = 'grid:fills'
    STREAM_MAXLEN = 10_000
    MAINTENANCE_CLOSE_CODE = 1001

    attr_reader :shutdown

    def initialize(redis: nil, redis_state: nil)
      @redis = redis || Redis.new(url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0'))
      @redis_state = redis_state || Grid::RedisState.new(redis: @redis)
      @shutdown = false
    end

    def run
      setup_signal_handlers
      Async { |task| reconnect_loop(task) }
    end

    private

    def setup_signal_handlers
      %w[TERM INT].each do |signal|
        Signal.trap(signal) { @shutdown = true }
      end
    end

    def reconnect_loop(task)
      backoff = INITIAL_BACKOFF

      loop do
        break if @shutdown

        backoff = attempt_connection(task, backoff)
      end
    end

    def attempt_connection(task, backoff)
      connect_and_listen(task)
      INITIAL_BACKOFF
    rescue Protocol::WebSocket::ClosedError => e
      handle_close_error(e, task, backoff)
    rescue Async::TimeoutError, IOError, Errno::ECONNRESET, Errno::ECONNREFUSED => e
      handle_connection_error(e, backoff)
    end

    def handle_close_error(error, task, backoff)
      if error.code == MAINTENANCE_CLOSE_CODE
        Rails.logger.warn('[WS] Maintenance detected (close code 1001). Pausing all bots.')
        pause_all_bots('maintenance')
        maintenance_reconnect_loop(task)
        return INITIAL_BACKOFF
      end

      Rails.logger.error(
        "[WS] Closed (code #{error.code}): #{error.message}. Reconnecting in #{backoff}s..."
      )
      trigger_reconciliation_for_all_bots
      sleep backoff
      [backoff * 2, MAX_BACKOFF].min
    end

    def handle_connection_error(error, backoff)
      Rails.logger.error("[WS] Connection lost: #{error.message}. Reconnecting in #{backoff}s...")
      trigger_reconciliation_for_all_bots
      sleep backoff
      [backoff * 2, MAX_BACKOFF].min
    end

    def maintenance_reconnect_loop(parent_task)
      loop do
        break if @shutdown

        sleep MAINTENANCE_RETRY_INTERVAL
        Rails.logger.info('[WS] Attempting reconnection after maintenance...')

        return resume_after_maintenance if try_maintenance_reconnect(parent_task)
      end
    end

    def try_maintenance_reconnect(parent_task)
      connect_and_listen(parent_task)
      true
    rescue StandardError => e
      Rails.logger.warn("[WS] Still in maintenance: #{e.message}")
      false
    end
  end
end
