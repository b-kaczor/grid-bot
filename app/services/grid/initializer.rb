# frozen_string_literal: true

module Grid
  class Initializer # rubocop:disable Metrics/ClassLength
    class Error < StandardError; end

    ORDER_LINK_ID_PATTERN = /\Ag(\d+)-L(\d+)-(B|S)-(\d+)\z/
    BATCH_SIZE = 20

    def initialize(bot)
      @bot = bot
    end

    def call
      validate_pending!
      transition_to!('initializing')

      @client = Bybit::RestClient.new(exchange_account: @bot.exchange_account)

      execute_initialization!

      @bot
    end

    private

    def execute_initialization! # rubocop:disable Metrics/AbcSize
      fetch_and_store_instrument_info!
      current_price = fetch_current_price!
      levels, classification, qty = calculate_grid(current_price)

      ensure_base_balance!(classification, qty, current_price)
      grid_levels = persist_grid_levels(levels, classification)
      place_orders_in_batches(grid_levels, classification, qty)

      transition_to!('running')
      seed_redis
      kick_off_reconciliation
    rescue StandardError => e
      transition_to!('error') unless @bot.status == 'error'
      Rails.logger.error("[Initializer] Bot #{@bot.id} failed: #{e.message}")
      raise Error, e.message unless e.is_a?(Error)

      raise
    end

    def validate_pending!
      raise Error, "Bot must be in pending status, got: #{@bot.status}" unless @bot.status == 'pending'
    end

    def transition_to!(status)
      @bot.update!(status:)
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
        min_order_qty: @bot.min_order_qty
      )
    end

    def ensure_base_balance!(classification, qty, _current_price) # rubocop:disable Metrics/AbcSize
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

      placeable.each_slice(BATCH_SIZE) do |batch|
        orders = batch.map do |gl, _index|
          build_order_request(gl, classification[gl.level_index], qty)
        end

        response = @client.batch_place_orders(symbol: @bot.pair, orders:)

        if response.success?
          failed_count += process_batch_response(response, batch)
        else
          Rails.logger.error("[Initializer] Batch failed entirely: #{response.error_message}")
          failed_count += batch.size
        end
      end

      check_failure_threshold!(failed_count, total_count)
    end

    def build_order_request(grid_level, side, qty)
      {
        side: side.to_s.capitalize,
        order_type: 'Limit',
        qty:,
        price: grid_level.price,
        order_link_id: generate_order_link_id(grid_level, side),
        time_in_force: 'GTC',
      }
    end

    def process_batch_response(response, batch)
      failed = 0
      result_list = response.data[:list] || []

      result_list.each_with_index do |entry, i|
        gl, _index = batch[i]
        next unless gl

        if entry[:code].to_s == '0'
          record_successful_order(gl, entry)
        else
          Rails.logger.warn(
            "[Initializer] Order failed for level #{gl.level_index}: #{entry[:msg]} (code: #{entry[:code]})"
          )
          failed += 1
        end
      end

      failed
    end

    def record_successful_order(grid_level, entry)
      link_id = entry[:orderLinkId]

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

    def generate_order_link_id(grid_level, side)
      side_char = side == :buy ? 'B' : 'S'
      "g#{@bot.id}-L#{grid_level.level_index}-#{side_char}-#{grid_level.cycle_count}"
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
      accounts = response.data[:list] || []
      accounts.each do |account|
        coins = account[:coin] || []
        coins.each do |c|
          return BigDecimal(c[:availableToWithdraw] || '0') if c[:coin] == coin
        end
      end
      BigDecimal('0')
    end

    def decimal_precision(value)
      return nil unless value

      str = value.to_s
      return 0 unless str.include?('.')

      str.split('.').last.length
    end
  end
end
