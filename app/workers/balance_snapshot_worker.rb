# frozen_string_literal: true

class BalanceSnapshotWorker
  include Sidekiq::Worker

  sidekiq_options queue: :default, retry: 3

  def perform
    Bot.running.find_each do |bot|
      create_snapshot(bot)
    rescue StandardError => e
      Rails.logger.error("[Snapshot] Failed for bot #{bot.id}: #{e.message}")
    end
  end

  private

  def create_snapshot(bot)
    current_price = fetch_current_price(bot)
    return unless current_price

    snapshot_data = build_snapshot_data(bot, current_price)

    BalanceSnapshot.create!(bot:, granularity: 'fine', snapshot_at: Time.current, **snapshot_data)
    Grid::RedisState.new.update_price(bot.id, current_price)
  end

  def fetch_current_price(bot)
    client = Bybit::RestClient.new(exchange_account: bot.exchange_account)
    ticker = client.get_tickers(symbol: bot.pair)
    return unless ticker.success?

    BigDecimal(ticker.data[:list].first[:lastPrice])
  end

  def build_snapshot_data(bot, current_price)
    base_held = calculate_base_held(bot)
    quote_balance = calculate_quote_balance(bot)
    avg_buy_price = calculate_avg_buy_price(bot)

    {
      base_balance: base_held,
      quote_balance:,
      total_value_quote: quote_balance + (base_held * current_price),
      current_price:,
      realized_profit: bot.trades.sum(:net_profit),
      unrealized_pnl: calculate_unrealized_pnl(current_price, avg_buy_price, base_held),
    }
  end

  def calculate_unrealized_pnl(current_price, avg_buy_price, base_held)
    avg_buy_price.positive? ? (current_price - avg_buy_price) * base_held : BigDecimal('0')
  end

  def calculate_base_held(bot)
    bought = bot.orders.buys.filled.sum(:net_quantity)
    sold = bot.orders.sells.filled.sum(:net_quantity)
    bought - sold
  end

  def calculate_quote_balance(bot)
    bot.investment_amount -
      bot.orders.buys.filled.sum('avg_fill_price * filled_quantity') +
      bot.orders.sells.filled.sum('avg_fill_price * filled_quantity') -
      quote_fees(bot)
  end

  def quote_fees(bot)
    buy_quote_fees = bot.orders.buys.filled.where(fee_coin: bot.quote_coin).sum(:fee)
    sell_quote_fees = bot.orders.sells.filled.where(fee_coin: bot.quote_coin).sum(:fee)
    buy_quote_fees + sell_quote_fees
  end

  def calculate_avg_buy_price(bot)
    active_buys = bot.orders.buys.filled
      .where.not(id: bot.trades.select(:buy_order_id))
    return BigDecimal('0') if active_buys.empty?

    total_cost = active_buys.sum('avg_fill_price * net_quantity')
    total_qty = active_buys.sum(:net_quantity)
    total_qty.positive? ? total_cost / total_qty : BigDecimal('0')
  end
end
