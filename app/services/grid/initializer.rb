# frozen_string_literal: true

module Grid
  class Initializer # rubocop:disable Metrics/ClassLength
    class Error < StandardError; end

    ORDER_LINK_ID_PATTERN = /\Ag(\d+)-L(\d+)-(B|S)-(\d+)\z/
    BATCH_SIZE = 10

    def initialize(bot)
      @bot = bot
    end

    def call
      validate_pending!

      @client = Bybit::RestClient.new(exchange_account: @bot.exchange_account)

      execute_initialization!

      @bot
    end

    private

    def execute_initialization! # rubocop:disable Metrics/AbcSize
      @placed_order_link_ids = []
      fetch_and_store_instrument_info!
      current_price = fetch_current_price!
      levels, classification, qty = calculate_grid(current_price)

      ensure_base_balance!(classification, qty)
      grid_levels = persist_grid_levels(levels, classification)
      place_orders_in_batches(grid_levels, classification, qty)

      transition_to!('running')
      register_dcp!
      seed_redis
      kick_off_reconciliation
    rescue StandardError => e
      rollback_exchange_orders!
      transition_to!('error') unless @bot.status == 'error'
      Rails.logger.error("[Initializer] Bot #{@bot.id} failed: #{e.message}")
      raise Error, e.message unless e.is_a?(Error)

      raise
    end

    def validate_pending!
      raise Error, "Bot must be in initializing status, got: #{@bot.status}" unless @bot.status == 'initializing'
    end

    def transition_to!(status)
      @bot.update!(status:)
      broadcast_status(status)
    end

    def broadcast_status(status)
      ActionCable.server.broadcast("bot_#{@bot.id}", { type: 'status', status: })
    end

    def fetch_and_store_instrument_info! # rubocop:disable Metrics/AbcSize
      response = @client.get_instruments_info(symbol: @bot.pair)
      raise Error, "Failed to fetch instrument info: #{response.error_message}" unless response.success?

      instrument = response.data[:list]&.first
      raise Error, 'Instrument not found' unless instrument

      lot_filter = instrument[:lotSizeFilter] || {}
      price_filter = instrument[:priceFilter] || {}

      @bot.update!(
        tick_size: price_filter[:tickSize],
        base_precision: decimal_precision(lot_filter[:basePrecision]),
        quote_precision: decimal_precision(price_filter[:tickSize]),
        min_order_qty: lot_filter[:minOrderQty],
        max_order_qty: lot_filter[:maxOrderQty],
        min_order_amt: lot_filter[:minOrderAmt]
      )
    end

    def fetch_current_price!
      response = @client.get_tickers(symbol: @bot.pair)
      raise Error, "Failed to fetch ticker: #{response.error_message}" unless response.success?

      BigDecimal(response.data[:list].first[:lastPrice])
    end

    def calculate_grid(current_price)
      calculator = build_calculator
      calculator.validate!(investment: @bot.investment_amount, current_price:)
      levels = calculator.levels
      classification = calculator.classify_levels(current_price:)
      qty = calculator.quantity_per_level(investment: @bot.investment_amount, current_price:)
      @bot.update!(quantity_per_level: qty)
      [levels, classification, qty]
    end

    def build_calculator
      Grid::Calculator.new(
        lower: @bot.lower_price,
        upper: @bot.upper_price,
        count: @bot.grid_count,
        spacing: @bot.spacing_type,
        tick_size: @bot.tick_size,
        base_precision: @bot.base_precision,
        min_order_amt: @bot.min_order_amt,
        min_order_qty: @bot.min_order_qty,
        max_order_qty: @bot.max_order_qty
      )
    end

    def ensure_base_balance!(classification, qty) # rubocop:disable Metrics/AbcSize
      sell_count = classification.count { |_, side| side == :sell }
      return if sell_count.zero?

      total_base_needed = qty * sell_count

      response = @client.get_wallet_balance(coin: @bot.base_coin)
      raise Error, "Failed to fetch wallet balance: #{response.error_message}" unless response.success?

      available = extract_available_balance(response, @bot.base_coin)
      deficit = total_base_needed - available
      return unless deficit.positive?

      buy_qty = @bot.base_precision ? deficit.ceil(@bot.base_precision) : deficit
      market_response = @client.place_order(
        symbol: @bot.pair,
        side: 'Buy',
        order_type: 'Market',
        qty: buy_qty.to_s
      )
      raise Error, "Market buy for base asset failed: #{market_response.error_message}" unless market_response.success?
    end

    def persist_grid_levels(levels, classification)
      levels.each_with_index.map do |price, index|
        side = classification[index]
        status = side == :skip ? 'skipped' : 'pending'
        expected_side = side == :skip ? 'buy' : side.to_s

        GridLevel.create!(
          bot: @bot,
          level_index: index,
          price:,
          expected_side:,
          status:
        )
      end
    end

    def place_orders_in_batches(grid_levels, classification, qty) # rubocop:disable Metrics/AbcSize
      placeable = grid_levels.each_with_index.reject { |_gl, i| classification[i] == :skip }
      total_count = placeable.size
      failed_count = 0
      failure_details = []

      placeable.each do |(gl, _)|
        side = classification[gl.level_index]
        link_id = generate_order_link_id(gl, side)

        response = @client.place_order(
          symbol: @bot.pair, side: side.to_s.capitalize, order_type: 'Limit',
          qty: qty.to_s, price: gl.price.to_s, order_link_id: link_id
        )

        if response.success? && response.data[:orderId].present?
          record_successful_order(gl, response.data.merge(orderLinkId: link_id))
        else
          Rails.logger.error(
            "[Initializer] Order failed for bot #{@bot.id} level #{gl.level_index} " \
            "(#{side}/#{gl.price}): [#{response.error_code}] #{response.error_message}"
          )
          failure_details << { code: response.error_code, msg: response.error_message, level: gl.level_index }
          failed_count += 1
        end
      end

      check_failure_threshold!(failed_count, total_count)
    end

    def record_successful_order(grid_level, entry)
      link_id = entry[:orderLinkId]
      @placed_order_link_ids << link_id

      grid_level.update!(
        status: 'active',
        current_order_id: entry[:orderId],
        current_order_link_id: link_id
      )

      Order.create!(
        bot: @bot,
        grid_level:,
        exchange_order_id: entry[:orderId],
        order_link_id: link_id,
        side: grid_level.expected_side,
        price: grid_level.price,
        quantity: @bot.quantity_per_level,
        status: 'open',
        placed_at: Time.current
      )
    end

    def check_failure_threshold!(failed_count, total_count)
      return if failed_count.zero? || total_count.zero?

      failure_rate = failed_count.to_f / total_count
      return unless failure_rate > 0.5

      transition_to!('error')
      raise Error, "Too many order failures: #{failed_count}/#{total_count} (#{(failure_rate * 100).round}%)"
    end

    def rollback_exchange_orders!
      return unless @client
      return if @placed_order_link_ids.blank?

      @placed_order_link_ids.each { |link_id| cancel_placed_order(link_id) }
      Rails.logger.info("[Initializer] Rollback: cancelled #{@placed_order_link_ids.size} orders for bot #{@bot.id}")
    rescue StandardError => e
      Rails.logger.warn("[Initializer] Rollback failed for bot #{@bot.id}: #{e.message}")
    end

    def cancel_placed_order(link_id)
      response = @client.cancel_order(symbol: @bot.pair, order_link_id: link_id)
      return if response.success?

      Rails.logger.warn("[Initializer] Rollback: cancel #{link_id} failed: #{response.error_message}")
    rescue StandardError => e
      Rails.logger.warn("[Initializer] Rollback exception cancelling #{link_id}: #{e.message}")
    end

    def generate_order_link_id(grid_level, side)
      side_char = side == :buy ? 'B' : 'S'
      "g#{@bot.id}-L#{grid_level.level_index}-#{side_char}-#{grid_level.cycle_count}"
    end

    def register_dcp!
      response = @client.set_dcp(time_window: 40)
      if response.success?
        Rails.logger.info("[Initializer] DCP registered with 40s window for bot #{@bot.id}")
      else
        Rails.logger.warn("[Initializer] DCP registration failed: #{response.error_message}")
      end
    end

    def seed_redis
      Grid::RedisState.new.seed(@bot.reload)
    end

    def kick_off_reconciliation
      redis = Redis.new(url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0'))
      lock_key = 'grid:reconciliation:scheduled'
      return unless redis.set(lock_key, Time.current.to_i, nx: true, ex: 30)

      GridReconciliationWorker.perform_in(15, nil)
    rescue NameError
      # GridReconciliationWorker may not exist yet during development
      Rails.logger.info('[Initializer] GridReconciliationWorker not available, skipping reconciliation kickoff')
    end

    def extract_available_balance(response, coin)
      coin_entry = find_coin_entry(response.data, coin)
      return BigDecimal('0') unless coin_entry

      val = coin_entry[:availableToWithdraw].presence || coin_entry[:walletBalance].presence || '0'
      BigDecimal(val)
    end

    def find_coin_entry(data, coin)
      (data[:list] || []).flat_map { |a| a[:coin] || [] }.find { |c| c[:coin] == coin }
    end

    def decimal_precision(value)
      return nil unless value

      str = value.to_s
      return 0 unless str.include?('.')

      str.split('.').last.length
    end
  end
end
