# frozen_string_literal: true

class GridReconciliationWorker # rubocop:disable Metrics/ClassLength
  include Sidekiq::Worker

  sidekiq_options queue: :default, retry: 0

  ORDER_LINK_ID_PATTERN = Grid::Initializer::ORDER_LINK_ID_PATTERN
  SCHEDULE_LOCK_KEY = 'grid:reconciliation:scheduled'
  SCHEDULE_LOCK_TTL = 30
  PARTIAL_FILL_AGE = 10.minutes
  PARTIAL_FILL_THRESHOLD = BigDecimal('0.95')

  def perform(bot_id = nil)
    bots = bot_id ? [Bot.find_by!(id: bot_id)] : Bot.running.to_a
    bots.each do |bot|
      bot.reload
      next unless bot.status == 'running'

      reconcile(bot)
    rescue StandardError => e
      Rails.logger.error("[Reconciliation] Bot #{bot.id} failed: #{e.message}")
    end
  ensure
    schedule_next if bot_id.nil?
  end

  private

  def reconcile(bot)
    client = Bybit::RestClient.new(exchange_account: bot.exchange_account)
    exchange_orders = fetch_all_open_orders(client, bot.pair)
    exchange_map = build_exchange_map(exchange_orders)
    local_orders = bot.orders.active.to_a

    handle_missing_orders(local_orders, exchange_map, bot, client)
    handle_partial_fills(exchange_orders, bot, client)
    handle_orphans(exchange_map, local_orders, bot, client)
    detect_and_repair_gaps(bot, exchange_map, client)
    refresh_redis(bot)
  end

  def fetch_all_open_orders(client, symbol)
    orders = []
    cursor = nil

    loop do
      response = client.get_open_orders(symbol:, cursor:, limit: 50)
      break unless response.success?

      orders.concat(response.data[:list] || [])
      cursor = response.data[:nextPageCursor]
      break if cursor.blank?
    end

    orders
  end

  def build_exchange_map(exchange_orders)
    exchange_orders.each_with_object({}) do |order, map|
      map[order[:orderLinkId]] = order if order[:orderLinkId].present?
      map[order[:orderId]] = order if order[:orderId].present?
    end
  end

  def handle_missing_orders(local_orders, exchange_map, bot, client)
    local_orders.each do |order|
      next if exchange_map[order.exchange_order_id]
      next if exchange_map[order.order_link_id]

      resolve_missing_order(order, bot, client)
    end
  end

  def resolve_missing_order(order, bot, client)
    response = client.get_order_history(
      symbol: bot.pair,
      order_link_id: order.order_link_id
    )

    if response.success? && response.data[:list].present?
      history_entry = response.data[:list].first
      process_history_entry(history_entry, order)
    else
      Rails.logger.warn("[Reconciliation] Order #{order.order_link_id} not found in history, marking cancelled")
      order.update!(status: 'cancelled')
    end
  end

  def process_history_entry(entry, order)
    case entry[:orderStatus]
    when 'Filled'
      Rails.logger.info("[Reconciliation] Missed fill detected for #{order.order_link_id}")
      OrderFillWorker.perform_async(Oj.dump(build_fill_data(entry)))
    when 'Cancelled', 'Deactivated', 'Rejected'
      order.update!(status: 'cancelled')
    else
      Rails.logger.warn("[Reconciliation] Unexpected status #{entry[:orderStatus]} for #{order.order_link_id}")
    end
  end

  def handle_partial_fills(exchange_orders, bot, client)
    exchange_orders
      .select { |o| o[:orderStatus] == 'PartiallyFilled' }
      .each { |ex_order| process_stale_partial(ex_order, bot, client) }
  end

  def process_stale_partial(ex_order, bot, client)
    db_order = find_db_order(ex_order, bot)
    return unless db_order&.placed_at && db_order.placed_at < PARTIAL_FILL_AGE.ago
    return unless stale_partial_fill?(ex_order)

    Rails.logger.info(
      "[Reconciliation] Cancelling stale partial fill #{db_order.order_link_id}"
    )
    cancel_response = client.cancel_order(symbol: bot.pair, order_id: ex_order[:orderId])
    return unless cancel_response.success?

    OrderFillWorker.perform_async(Oj.dump(build_fill_data(ex_order)))
  end

  def stale_partial_fill?(ex_order)
    filled_qty = BigDecimal(ex_order[:cumExecQty].to_s)
    total_qty = BigDecimal(ex_order[:qty].to_s)
    total_qty.positive? && (filled_qty / total_qty) >= PARTIAL_FILL_THRESHOLD
  end

  def handle_orphans(exchange_map, local_orders, bot, client)
    local_link_ids = local_orders.to_set(&:order_link_id)
    local_exchange_ids = local_orders.to_set(&:exchange_order_id)

    exchange_map.each_value.uniq { |o| o[:orderId] }.each do |ex_order|
      next if local_exchange_ids.include?(ex_order[:orderId])
      next if local_link_ids.include?(ex_order[:orderLinkId])

      process_orphan(ex_order, bot, client)
    end
  end

  def process_orphan(ex_order, bot, client)
    link_id = ex_order[:orderLinkId]
    match = link_id&.match(ORDER_LINK_ID_PATTERN)

    if match && match[1].to_i == bot.id
      adopt_orphan(ex_order, match, bot)
    else
      Rails.logger.warn("[Reconciliation] Cancelling foreign order #{ex_order[:orderId]} (link: #{link_id})")
      client.cancel_order(symbol: bot.pair, order_id: ex_order[:orderId])
    end
  end

  def adopt_orphan(ex_order, match, bot)
    level_index = match[2].to_i
    side = match[3] == 'B' ? 'buy' : 'sell'

    grid_level = bot.grid_levels.find_by(level_index:)
    unless grid_level
      Rails.logger.warn(
        "[Reconciliation] No grid level #{level_index} for orphan #{ex_order[:orderId]}"
      )
      return
    end

    Rails.logger.info("[Reconciliation] Adopting orphan #{ex_order[:orderId]} at level #{level_index}")
    create_adopted_order(bot, grid_level, ex_order, side)
    grid_level.update!(
      status: 'active',
      current_order_id: ex_order[:orderId],
      current_order_link_id: ex_order[:orderLinkId],
      expected_side: side
    )
  end

  def create_adopted_order(bot, grid_level, ex_order, side)
    Order.create!(
      bot:,
      grid_level:,
      exchange_order_id: ex_order[:orderId],
      order_link_id: ex_order[:orderLinkId],
      side:,
      price: BigDecimal(ex_order[:price].to_s),
      quantity: BigDecimal(ex_order[:qty].to_s),
      status: 'open',
      placed_at: Time.current
    )
  end

  def detect_and_repair_gaps(bot, exchange_map, client)
    return unless bot.reload.status == 'running'

    bot.grid_levels.where.not(status: 'skipped').find_each do |level|
      next if level_has_active_order?(level, exchange_map)
      next if level.status == 'active' # Still active in DB but checked via exchange_map above

      repair_gap(level, bot, client)
    end
  end

  def level_has_active_order?(level, exchange_map)
    level.current_order_id.present? && exchange_map[level.current_order_id].present?
  end

  def repair_gap(level, bot, client)
    qty = bot.quantity_per_level
    return unless qty

    link_id = generate_gap_link_id(level, bot)
    response = place_gap_order(level, bot, client, qty, link_id)
    return unless response

    record_gap_repair(level, bot, qty, link_id, response)
  end

  def generate_gap_link_id(level, bot)
    level.update!(cycle_count: level.cycle_count + 1)
    side_char = level.expected_side == 'buy' ? 'B' : 'S'
    "g#{bot.id}-L#{level.level_index}-#{side_char}-#{level.cycle_count}"
  end

  def place_gap_order(level, bot, client, qty, link_id)
    response = client.place_order(
      symbol: bot.pair,
      side: level.expected_side.capitalize,
      order_type: 'Limit',
      qty: qty.to_s,
      price: level.price.to_s,
      order_link_id: link_id
    )

    unless response.success?
      Rails.logger.error(
        "[Reconciliation] Failed to repair gap at level #{level.level_index}: #{response.error_message}"
      )
      return nil
    end

    response
  end

  def record_gap_repair(level, bot, qty, link_id, response)
    Order.create!(
      bot:,
      grid_level: level,
      exchange_order_id: response.data[:orderId],
      order_link_id: link_id,
      side: level.expected_side,
      price: level.price,
      quantity: qty,
      status: 'open',
      placed_at: Time.current
    )

    level.update!(
      status: 'active',
      current_order_id: response.data[:orderId],
      current_order_link_id: link_id
    )
  end

  def refresh_redis(bot)
    redis_state = Grid::RedisState.new
    redis_state.seed(bot.reload)
  end

  def build_fill_data(entry)
    {
      orderId: entry[:orderId],
      orderLinkId: entry[:orderLinkId],
      cumExecQty: entry[:cumExecQty],
      avgPrice: entry[:avgPrice],
      cumExecFee: entry[:cumExecFee] || '0',
      feeCurrency: entry[:feeCurrency] || '',
      updatedTime: entry[:updatedTime] || (Time.current.to_f * 1000).to_i.to_s,
    }
  end

  def find_db_order(ex_order, bot)
    bot.orders.find_by(exchange_order_id: ex_order[:orderId]) ||
      bot.orders.find_by(order_link_id: ex_order[:orderLinkId])
  end

  def schedule_next
    return unless Bot.running.exists?

    redis = Redis.new(url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0'))
    return unless redis.set(SCHEDULE_LOCK_KEY, Time.current.to_i, nx: true, ex: SCHEDULE_LOCK_TTL)

    GridReconciliationWorker.perform_in(15, nil)
  end
end
