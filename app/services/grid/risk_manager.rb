# frozen_string_literal: true

module Grid
  class RiskManager # rubocop:disable Metrics/ClassLength
    class MarketSellError < StandardError; end

    def initialize(bot, current_price:)
      @bot = bot
      @current_price = BigDecimal(current_price.to_s)
    end

    def check!
      return nil if triggered_reason.nil?
      return nil unless claim_stop!

      execute_emergency_stop!(triggered_reason)
      triggered_reason
    rescue MarketSellError => e
      log_market_sell_failure(e)
      broadcast_risk_error(e.message)
      triggered_reason
    end

    private

    def claim_stop!
      rows = Bot.where(id: @bot.id, status: 'running')
        .update_all(status: 'stopping') # rubocop:disable Rails/SkipsModelValidations
      return false if rows.zero?

      @bot.reload
      true
    end

    def log_market_sell_failure(error)
      Rails.logger.error(
        "[RiskManager] Bot #{@bot.id}: market sell failed after #{triggered_reason}: #{error.message}. " \
        'Orders cancelled, base asset remains. User must sell manually.'
      )
    end

    def triggered_reason
      @triggered_reason ||= if @bot.stop_loss_price && @current_price <= @bot.stop_loss_price
                              :stop_loss
                            elsif @bot.take_profit_price && @current_price >= @bot.take_profit_price
                              :take_profit
                            end
    end

    def execute_emergency_stop!(reason)
      client = Bybit::RestClient.new(exchange_account: @bot.exchange_account)

      Grid::RedisState.new.update_status(@bot.id, 'stopping')
      broadcast_status('stopping')

      client.cancel_all_orders(symbol: @bot.pair, emergency: true)
      market_sell_base!(client)

      finalize_stop!(reason)
    end

    def finalize_stop!(reason)
      ActiveRecord::Base.transaction do
        @bot.orders.where(status: 'open').update_all(status: 'cancelled') # rubocop:disable Rails/SkipsModelValidations
        @bot.grid_levels.where(status: 'active').update_all(status: 'filled') # rubocop:disable Rails/SkipsModelValidations
        @bot.update!(status: 'stopped', stop_reason: reason.to_s)
      end

      BalanceSnapshotWorker.perform_async
      Grid::RedisState.new.cleanup(@bot.id)
      broadcast_status('stopped', stop_reason: reason.to_s)
    end

    def market_sell_base!(client)
      base_held = fetch_exchange_base_balance(client)
      return unless base_held.positive?

      qty = base_held.truncate(@bot.base_precision || 8)
      return unless qty.positive?

      response = client.place_order(
        symbol: @bot.pair,
        side: 'Sell',
        order_type: 'Market',
        qty: qty.to_s,
        emergency: true
      )

      return if response.success?

      raise MarketSellError,
            "Failed to market-sell #{qty} #{@bot.base_coin}: #{response.error_message}"
    end

    def fetch_exchange_base_balance(client)
      response = client.get_wallet_balance(coin: @bot.base_coin)
      unless response.success?
        Rails.logger.warn('[RiskManager] Failed to fetch balance, falling back to DB estimate')
        return calculate_base_held_from_db
      end

      extract_available_balance(response, @bot.base_coin)
    end

    def extract_available_balance(response, coin)
      accounts = response.data[:list] || []
      accounts.each do |account|
        coins = account[:coin] || []
        coins.each do |c|
          return BigDecimal(c[:availableToWithdraw] || '0') if c[:coin] == coin
        end
      end
      BigDecimal('0')
    end

    def calculate_base_held_from_db
      bought = @bot.orders.where(side: 'buy', status: 'filled').sum(:net_quantity)
      sold = @bot.orders.where(side: 'sell', status: 'filled').sum(:net_quantity)
      bought - sold
    end

    def broadcast_status(status, extra = {})
      ActionCable.server.broadcast(
        "bot_#{@bot.id}", {
          type: 'status',
          status:,
          trigger_price: @current_price.to_s,
        }.merge(extra)
      )
    end

    def broadcast_risk_error(message)
      ActionCable.server.broadcast(
        "bot_#{@bot.id}", {
          type: 'risk_error',
          message:,
          trigger_price: @current_price.to_s,
        }
      )
    end
  end
end
