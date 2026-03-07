# frozen_string_literal: true

class OrderFillWorker # rubocop:disable Metrics/ClassLength
  include Sidekiq::Worker

  sidekiq_options queue: :critical, retry: 5

  ORDER_LINK_ID_PATTERN = Grid::Initializer::ORDER_LINK_ID_PATTERN
  MAX_RAPID_FILL_RETRIES = 3
  MAX_STALE_RETRIES = 3

  def perform(order_data_json, retry_count = 0)
    order_data = Oj.load(order_data_json, symbol_keys: true)
    process_fill(order_data, order_data_json, retry_count)
  end

  private

  def process_fill(order_data, order_data_json, retry_count)
    stale_retries = 0
    begin
      execute_fill(order_data, order_data_json, retry_count)
    rescue ActiveRecord::StaleObjectError
      stale_retries += 1
      raise if stale_retries > MAX_STALE_RETRIES

      order = Order.find_by(exchange_order_id: order_data[:orderId])
      retry unless order&.status == 'filled'
    end
  end

  def execute_fill(order_data, order_data_json, retry_count)
    order = find_order(order_data, order_data_json, retry_count)
    return unless order

    return if order.status == 'filled'

    bot = order.bot
    client = Bybit::RestClient.new(exchange_account: bot.exchange_account)
    redis_state = Grid::RedisState.new
    trade = nil

    ActiveRecord::Base.transaction do
      grid_level = order.grid_level
      grid_level.lock!

      update_order!(order, order_data, bot)
      grid_level.update!(status: 'filled')

      trade = handle_fill(order, grid_level, bot, client)
    end

    redis_state.update_on_fill(bot, order.grid_level.reload, trade)
  end

  def find_order(order_data, order_data_json, retry_count)
    order = Order.find_by(exchange_order_id: order_data[:orderId])
    order ||= Order.find_by(order_link_id: order_data[:orderLinkId])

    return order if order

    handle_missing_order(order_data, order_data_json, retry_count)
  end

  def handle_missing_order(order_data, order_data_json, retry_count)
    link_id = order_data[:orderLinkId]

    if link_id&.match?(ORDER_LINK_ID_PATTERN)
      if retry_count < MAX_RAPID_FILL_RETRIES
        Rails.logger.info(
          '[Fill] Order not found, rapid-fill race likely. ' \
          "Re-enqueueing (#{retry_count + 1}/#{MAX_RAPID_FILL_RETRIES})"
        )
        OrderFillWorker.perform_in(5, order_data_json, retry_count + 1)
      else
        Rails.logger.error("[Fill] Order not found after #{MAX_RAPID_FILL_RETRIES} retries: #{link_id}")
      end
    else
      Rails.logger.warn("[Fill] Foreign order, skipping: #{order_data[:orderId]}")
    end

    nil
  end

  def update_order!(order, order_data, bot) # rubocop:disable Metrics/AbcSize
    fee = BigDecimal(order_data[:cumExecFee].to_s)
    filled_qty = BigDecimal(order_data[:cumExecQty].to_s)
    fee_coin = order_data[:feeCurrency].to_s

    net_qty = if fee_coin == bot.base_coin && order.side == 'buy'
                filled_qty - fee
              else
                filled_qty
              end

    order.update!(
      status: 'filled',
      filled_quantity: filled_qty,
      avg_fill_price: order_data[:avgPrice],
      fee:,
      fee_coin:,
      net_quantity: net_qty,
      filled_at: Time.zone.at(order_data[:updatedTime].to_i / 1000)
    )
  end

  def handle_fill(order, grid_level, bot, client)
    if bot.status.in?(%w[stopping stopped])
      Rails.logger.info("[Fill] Bot #{bot.id} is #{bot.status}, skipping counter-order")
      return nil
    end

    if order.side == 'buy'
      handle_buy_fill(order, grid_level, bot, client)
      nil
    else
      handle_sell_fill(order, grid_level, bot, client)
    end
  end

  def handle_buy_fill(order, grid_level, bot, client)
    sell_level_index = grid_level.level_index + 1
    sell_level = bot.grid_levels.find_by(level_index: sell_level_index)

    unless sell_level
      Rails.logger.warn("[Fill] No sell level above #{grid_level.level_index} for bot #{bot.id}")
      return
    end

    place_counter_order(
      bot:, client:, level: sell_level, side: 'sell',
      qty: order.net_quantity.truncate(bot.base_precision || 8),
      paired_order: order
    )
  end

  def handle_sell_fill(order, grid_level, bot, client)
    buy_level_index = grid_level.level_index - 1
    buy_level = bot.grid_levels.find_by(level_index: buy_level_index)

    unless buy_level
      Rails.logger.warn("[Fill] No buy level below #{grid_level.level_index} for bot #{bot.id}")
      return
    end

    buy_qty = bot.quantity_per_level
    raise "Bot #{bot.id} has no quantity_per_level set" unless buy_qty

    place_counter_order(
      bot:, client:, level: buy_level, side: 'buy',
      qty: buy_qty, paired_order: order
    )

    grid_level.update!(cycle_count: grid_level.cycle_count + 1)
    record_trade(order, grid_level, bot)
  end

  def place_counter_order(bot:, client:, level:, side:, qty:, paired_order:) # rubocop:disable Metrics/AbcSize, Metrics/ParameterLists
    level.update!(cycle_count: level.cycle_count + 1)
    side_char = side == 'buy' ? 'B' : 'S'
    link_id = "g#{bot.id}-L#{level.level_index}-#{side_char}-#{level.cycle_count}"

    response = client.place_order(
      symbol: bot.pair,
      side: side.capitalize,
      order_type: 'Limit',
      qty: qty.to_s,
      price: level.price.to_s,
      order_link_id: link_id
    )

    if response.success?
      create_counter_order_records(bot, level, side, qty, link_id, response, paired_order)
    else
      Rails.logger.error("[Fill] Failed to place #{side} counter-order: #{response.error_message}")
    end
  end

  def create_counter_order_records(bot, level, side, qty, link_id, response, paired_order) # rubocop:disable Metrics/ParameterLists
    Order.create!(
      bot:,
      grid_level: level,
      exchange_order_id: response.data[:orderId],
      order_link_id: link_id,
      side:,
      price: level.price,
      quantity: qty,
      status: 'open',
      placed_at: Time.current,
      paired_order_id: paired_order.id
    )

    level.update!(
      status: 'active',
      expected_side: side,
      current_order_id: response.data[:orderId],
      current_order_link_id: link_id
    )
  end

  def record_trade(sell_order, grid_level, bot)
    buy_order = Order.find_by!(id: sell_order.paired_order_id)
    profit = calculate_profit(buy_order, sell_order, bot)

    Trade.create!(
      bot:,
      grid_level:,
      buy_order:,
      sell_order:,
      buy_price: buy_order.avg_fill_price,
      sell_price: sell_order.avg_fill_price,
      quantity: sell_order.net_quantity,
      **profit,
      completed_at: sell_order.filled_at
    )
  end

  def calculate_profit(buy_order, sell_order, bot)
    quantity = sell_order.net_quantity
    gross_profit = (sell_order.avg_fill_price - buy_order.avg_fill_price) * quantity
    total_fees = normalize_fee_to_quote(buy_order, bot) + normalize_fee_to_quote(sell_order, bot)

    { gross_profit:, total_fees:, net_profit: gross_profit - total_fees }
  end

  def normalize_fee_to_quote(order, bot)
    if order.fee_coin == bot.quote_coin
      order.fee
    elsif order.fee_coin == bot.base_coin
      order.fee * order.avg_fill_price
    else
      Rails.logger.warn("[Fill] Fee in unexpected coin #{order.fee_coin} for order #{order.id}")
      BigDecimal('0')
    end
  end
end
