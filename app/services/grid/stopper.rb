# frozen_string_literal: true

module Grid
  class Stopper
    class Error < StandardError; end

    def initialize(bot)
      @bot = bot
    end

    def call
      validate_stoppable!
      begin_stopping!
      cancel_exchange_orders!
      finalize_stop!
    end

    private

    def validate_stoppable!
      return if %w[running paused stopping].include?(@bot.status)

      raise Error, "Bot cannot be stopped from #{@bot.status} status"
    end

    def begin_stopping!
      @bot.update!(status: 'stopping')
      broadcast_status('stopping')
      Grid::RedisState.new.update_status(@bot.id, 'stopping')
    end

    def cancel_exchange_orders!
      client = Bybit::RestClient.new(exchange_account: @bot.exchange_account)
      response = client.cancel_all_orders(symbol: @bot.pair)

      Rails.logger.warn("[Stopper] cancel_all_orders failed: #{response.error_message}") unless response.success?
    end

    def finalize_stop!
      ActiveRecord::Base.transaction do
        @bot.orders.active.update_all(status: 'cancelled') # rubocop:disable Rails/SkipsModelValidations
        @bot.grid_levels.where(status: 'active').update_all(status: 'filled') # rubocop:disable Rails/SkipsModelValidations
        @bot.update!(status: 'stopped', stop_reason: 'user')
      end

      Grid::RedisState.new.cleanup(@bot.id)
      broadcast_status('stopped')
    end

    def broadcast_status(status)
      ActionCable.server.broadcast("bot_#{@bot.id}", { type: 'status', status: })
    end
  end
end
