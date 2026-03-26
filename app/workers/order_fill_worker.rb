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
    trade, counter_level = process_fill_transaction(order, order_data, bot, client)
    post_fill_updates(bot, order, trade, counter_level)
  end

  def process_fill_transaction(order, order_data, bot, client)
    trade = nil
    counter_level = nil
    ActiveRecord::Base.transaction do
      grid_level = order.grid_level
      grid_level.lock!
      update_order!(order, order_data, bot)
      grid_level.update!(status: 'filled')
      trade, counter_level = handle_fill(order, grid_level, bot, client)
    end
    [trade, counter_level]
  end

  def post_fill_updates(bot, order, trade, counter_level)
    redis_state = Grid::RedisState.new
    grid_level = order.grid_level.reload
    redis_state.update_on_fill(bot, grid_level, trade, counter_level:)
    broadcast_fill(bot, grid_level, trade, redis_state, counter_level)
    check_risk(bot, order.avg_fill_price)
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
      return [nil, nil]
    end

    if order.side == 'buy'
      counter_level = handle_buy_fill(order, grid_level, bot, client)
      [nil, counter_level]
    else
      handle_sell_fill(order, grid_level, bot, client)
    end
  end

  def handle_buy_fill(order, grid_level, bot, client)
    sell_level_index = grid_level.level_index + 1
    sell_level = bot.grid_levels.find_by(level_index: sell_level_index)

    unless sell_level
      Rails.logger.warn("[Fill] No sell level above #{grid_level.level_index} for bot #{bot.id}")
      return nil
    end

    place_counter_order(
      bot:, client:, level: sell_level, side: 'sell',
      qty: order.net_quantity.truncate(bot.base_precision || 8),
      paired_order: order
    )
    sell_level.reload
  end

  def handle_sell_fill(order, grid_level, bot, client)
    if try_trailing(bot, grid_level, client)
      return [record_trade(order, grid_level, bot), nil]
    end

    counter_level = place_counter_buy(order, grid_level, bot, client)
    return [nil, nil] unless counter_level

    grid_level.update!(cycle_count: grid_level.cycle_count + 1)
    [record_trade(order, grid_level, bot), counter_level]
  end

  def place_counter_buy(order, grid_level, bot, client)
    buy_level = bot.grid_levels.find_by(level_index: grid_level.level_index - 1)

    unless buy_level
      Rails.logger.warn("[Fill] No buy level below #{grid_level.level_index} for bot #{bot.id}")
      return nil
    end

    buy_qty = bot.quantity_per_level
    raise "Bot #{bot.id} has no quantity_per_level set" unless buy_qty

    place_counter_order(bot:, client:, level: buy_level, side: 'buy', qty: buy_qty, paired_order: order)
    buy_level.reload
  end

  def try_trailing(bot, grid_level, client)
    Grid::TrailingManager.new(bot, filled_level: grid_level, client:).maybe_trail!
  rescue Grid::TrailingManager::TrailError => e
    Rails.logger.warn("[Fill] Trailing skipped for bot #{bot.id}: #{e.message}")
    false
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
      Rails.logger.error(
        "[Fill] Failed to place #{side} counter-order for bot #{bot.id} " \
        "level #{level.level_index} (#{level.price}): " \
        "[#{response.error_code}] #{response.error_message}"
      )
      level.update!(status: 'error')
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

  def check_risk(bot, price)
    return unless price

    Grid::RiskManager.new(bot, current_price: price).check!
  rescue StandardError => e
    Rails.logger.error("[Fill] Risk check failed for bot #{bot.id}: #{e.message}")
  end

  def broadcast_fill(bot, grid_level, trade, redis_state, counter_level)
    stats = redis_state.read_stats(bot.id)
    ActionCable.server.broadcast(
      "bot_#{bot.id}", {
        type: 'fill',
        grid_level: serialize_grid_level(grid_level),
        counter_level: counter_level ? serialize_grid_level(counter_level) : nil,
        trade: trade ? serialize_trade(trade) : nil,
        realized_profit: stats['realized_profit'] || '0',
        trade_count: (stats['trade_count'] || '0').to_i,
      }
    )
  end

  def serialize_grid_level(level)
    {
      level_index: level.level_index,
      price: level.price.to_s,
      expected_side: level.expected_side,
      status: level.status,
      cycle_count: level.cycle_count,
    }
  end

  def serialize_trade(trade)
    {
      id: trade.id,
      buy_price: trade.buy_price.to_s,
      sell_price: trade.sell_price.to_s,
      quantity: trade.quantity.to_s,
      net_profit: trade.net_profit.to_s,
      completed_at: trade.completed_at&.iso8601,
    }
  end
end
