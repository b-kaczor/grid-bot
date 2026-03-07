# frozen_string_literal: true

module BotSerialization
  private

  def bot_summary(bot, redis)
    bot_response(bot).merge(live_stats(bot, redis))
  end

  def bot_detail(bot, redis, recent_trades)
    snapshot = bot.balance_snapshots.order(snapshot_at: :desc).first

    bot_response(bot).merge(
      live_stats(bot, redis),
      unrealized_pnl: snapshot&.unrealized_pnl&.to_s || '0.0',
      tick_size: bot.tick_size&.to_s,
      base_precision: bot.base_precision,
      quote_precision: bot.quote_precision,
      recent_trades: recent_trades.map { |t| trade_response(t) }
    )
  end

  def bot_response(bot) # rubocop:disable Metrics/AbcSize
    {
      id: bot.id,
      pair: bot.pair,
      base_coin: bot.base_coin,
      quote_coin: bot.quote_coin,
      status: bot.status,
      lower_price: bot.lower_price.to_s,
      upper_price: bot.upper_price.to_s,
      grid_count: bot.grid_count,
      spacing_type: bot.spacing_type,
      investment_amount: bot.investment_amount.to_s,
      created_at: bot.created_at&.iso8601,
      stop_loss_price: bot.stop_loss_price&.to_s,
      take_profit_price: bot.take_profit_price&.to_s,
      trailing_up_enabled: bot.trailing_up_enabled,
      stop_reason: bot.stop_reason,
    }
  end

  def live_stats(bot, redis) # rubocop:disable Metrics/AbcSize
    stats = redis.read_stats(bot.id)
    levels = redis.read_levels(bot.id)
    uptime_start = stats['uptime_start']
    {
      current_price: redis.read_price(bot.id),
      realized_profit: stats['realized_profit'] || '0.0',
      trade_count: (stats['trade_count'] || '0').to_i,
      active_levels: levels.count { |_, v| v['status'] == 'active' },
      uptime_seconds: uptime_start ? (Time.current.to_i - uptime_start.to_i) : 0,
    }
  end

  def trade_response(trade)
    {
      id: trade.id,
      level_index: trade.grid_level.level_index,
      buy_price: trade.buy_price.to_s,
      sell_price: trade.sell_price.to_s,
      quantity: trade.quantity.to_s,
      net_profit: trade.net_profit.to_s,
      total_fees: trade.total_fees.to_s,
      completed_at: trade.completed_at.iso8601,
    }
  end
end
