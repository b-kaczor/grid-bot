# Phase 4: Safety & Production — ARCHITECTURE

## Overview

Phase 4 adds three backend services (RiskManager, TrailingManager, DCP integration), extends the existing BotsController and WebSocket listener, adds frontend risk settings UI, and provides systemd process management. No new database migrations are needed — all required columns exist from Phase 1.

---

## 1. Grid::RiskManager

**File:** `app/services/grid/risk_manager.rb`

### Purpose

Checks stop-loss and take-profit conditions on every price update. If triggered, executes an emergency exit: cancel all orders, market-sell base asset, stop the bot.

### Interface

```ruby
module Grid
  class RiskManager
    class MarketSellError < StandardError; end

    # Returns :stop_loss, :take_profit, or nil
    def initialize(bot, current_price:)
      @bot = bot
      @current_price = BigDecimal(current_price.to_s)
    end

    def check!
      return nil if triggered_reason.nil?

      # Atomic status transition: running -> stopping
      # If 0 rows updated, another thread already claimed it — bail out
      rows = Bot.where(id: @bot.id, status: 'running')
                .update_all(status: 'stopping') # rubocop:disable Rails/SkipsModelValidations
      return nil if rows.zero?

      @bot.reload
      execute_emergency_stop!(triggered_reason)
      triggered_reason
    rescue MarketSellError => e
      # Orders are cancelled but base asset is stranded.
      # Do NOT mark as stopped — leave as stopping so user knows to intervene.
      Rails.logger.error(
        "[RiskManager] Bot #{@bot.id}: market sell failed after #{triggered_reason}: #{e.message}. " \
        "Orders cancelled, base asset remains. User must sell manually."
      )
      broadcast_risk_error(e.message)
      triggered_reason
    end

    private

    def triggered_reason
      @triggered_reason ||= begin
        if @bot.stop_loss_price && @current_price <= @bot.stop_loss_price
          :stop_loss
        elsif @bot.take_profit_price && @current_price >= @bot.take_profit_price
          :take_profit
        end
      end
    end

    def execute_emergency_stop!(reason)
      client = Bybit::RestClient.new(exchange_account: @bot.exchange_account)

      # 1. Broadcast stopping state so frontend knows immediately
      Grid::RedisState.new.update_status(@bot.id, 'stopping')
      broadcast_status('stopping')

      # 2. Cancel all open orders (exempt from rate limiter — see Section 6c)
      client.cancel_all_orders(symbol: @bot.pair)

      # 3. Market-sell all held base asset (use exchange balance, not DB sum)
      market_sell_base!(client)

      # 4. Finalize stop in DB
      ActiveRecord::Base.transaction do
        @bot.orders.where(status: 'open').update_all(status: 'cancelled') # rubocop:disable Rails/SkipsModelValidations
        @bot.grid_levels.where(status: 'active').update_all(status: 'filled') # rubocop:disable Rails/SkipsModelValidations
        @bot.update!(status: 'stopped', stop_reason: reason.to_s)
      end

      # 5. Final balance snapshot (async — don't block the emergency stop)
      BalanceSnapshotWorker.perform_async

      # 6. Cleanup Redis + broadcast final state
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
        qty: qty.to_s
      )

      return if response.success?

      raise MarketSellError,
            "Failed to market-sell #{qty} #{@bot.base_coin}: #{response.error_message}"
    end

    def fetch_exchange_base_balance(client)
      response = client.get_wallet_balance(coin: @bot.base_coin)
      unless response.success?
        Rails.logger.warn("[RiskManager] Failed to fetch balance, falling back to DB estimate")
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
      ActionCable.server.broadcast("bot_#{@bot.id}", {
        type: 'status',
        status:,
        trigger_price: @current_price.to_s
      }.merge(extra))
    end

    def broadcast_risk_error(message)
      ActionCable.server.broadcast("bot_#{@bot.id}", {
        type: 'risk_error',
        message: message,
        trigger_price: @current_price.to_s
      })
    end
  end
end
```

### Where to Hook It

**Primary hook: WebSocket public ticker** — Subscribe to `tickers.{symbol}` on the existing private WebSocket connection (Bybit allows mixing public and private topics on the same connection). This gives sub-second price updates for all running bots. See Section 3d for details.

**Secondary hook: OrderFillWorker** — Every fill triggers a price check using the fill's `avgPrice`. Add a risk check at the end of `post_fill_updates`:

```ruby
# In OrderFillWorker#post_fill_updates, after broadcast_fill:
check_risk(bot, order_data[:avgPrice] || order_data[:price])
```

```ruby
def check_risk(bot, price)
  return unless price

  Grid::RiskManager.new(bot, current_price: price).check!
rescue StandardError => e
  Rails.logger.error("[Fill] Risk check failed for bot #{bot.id}: #{e.message}")
end
```

**Tertiary hook: BalanceSnapshotWorker** — Every 5 minutes, after fetching `current_price`, run the risk check as a final safety net:

```ruby
# In BalanceSnapshotWorker#create_snapshot, after fetch_current_price:
return if check_risk(bot, current_price)
# ... continue with normal snapshot logic

def check_risk(bot, price)
  result = Grid::RiskManager.new(bot, current_price: price).check!
  result.present?
rescue StandardError => e
  Rails.logger.error("[Snapshot] Risk check failed for bot #{bot.id}: #{e.message}")
  false
end
```

### Design Decisions

- **Atomic `running -> stopping` via `update_all` (#1 fix).** The `Bot.where(id:, status: 'running').update_all(status: 'stopping')` is an atomic SQL UPDATE with a WHERE clause. If two threads race (fill + snapshot, or two fills), only one gets `rows=1` and proceeds. The other sees `rows=0` and bails. This eliminates double market-sell entirely without pessimistic locking overhead.

- **Uses `stopping` state (#I-5 fix).** Transitioning to `stopping` before doing exchange work means the existing guard in `OrderFillWorker#handle_fill` (`return nil if bot.status.in?(%w[stopping stopped])`) prevents any new counter-orders during the emergency stop sequence.

- **Exchange balance for market sell (#5 fix).** `fetch_exchange_base_balance` calls `get_wallet_balance` to get the real available balance from Bybit, which accounts for fees, partial fills, and any manual trades. Falls back to DB-based estimate only if the API call fails.

- **Market sell failure handling (#2 fix).** If the market sell fails, the bot stays in `stopping` state (not `stopped`). A `MarketSellError` is caught, logged at ERROR level with bot ID and amount, and a `risk_error` message is broadcast to the frontend. The user must intervene manually. Orders are already cancelled, so no further loss accumulation.

- **Public ticker subscription (#I-1 fix).** Instead of relying on the 5-minute BalanceSnapshotWorker poll, we subscribe to `tickers.{symbol}` on the WebSocket connection. This gives sub-second price updates. The WS connection already exists and Bybit supports mixing public/private topics. Minimal additional code. See Section 3d.

- **`perform_async` for final snapshot (#WC-1 fix).** Uses `BalanceSnapshotWorker.perform_async` instead of `.new.perform` to avoid blocking the emergency stop path.

---

## 2. Grid::TrailingManager

**File:** `app/services/grid/trailing_manager.rb`

### Purpose

When the highest sell order fills and `trailing_up_enabled` is true, shift the grid upward by one step: cancel the lowest buy, place a new sell at top+1, adjust price boundaries.

### Interface

```ruby
module Grid
  class TrailingManager
    class TrailError < StandardError; end

    def initialize(bot, filled_level:, client:)
      @bot = bot
      @filled_level = filled_level
      @client = client
    end

    # Returns true if trailing was performed, false if not applicable
    def maybe_trail!
      return false unless should_trail?

      trail_up!
      true
    end

    private

    def should_trail?
      @bot.trailing_up_enabled &&
        @bot.status == 'running' &&
        @filled_level.level_index == max_level_index
    end

    def max_level_index
      @bot.grid_levels.maximum(:level_index)
    end

    def trail_up!
      step = grid_step
      new_top_price = round_to_tick(@bot.upper_price + step)

      lowest_level = @bot.grid_levels.order(:level_index).first
      validate_lowest_level!(lowest_level)

      # Phase 1: Exchange operation (outside transaction — if this fails, nothing changes)
      cancel_lowest_buy!(lowest_level)

      # Phase 2: Place new sell at the new top (outside transaction — must succeed before DB commit)
      new_sell_response = place_new_top_sell(new_top_price)
      raise TrailError, "Failed to place trailing sell: exchange rejected" unless new_sell_response

      # Phase 3: All exchange ops succeeded — now update DB atomically
      ActiveRecord::Base.transaction do
        # Cancel the order record for the old lowest
        lowest_level.orders.where(status: 'open').update_all(status: 'cancelled') # rubocop:disable Rails/SkipsModelValidations

        # Delete old lowest level
        lowest_level.destroy!

        # Shift remaining level_index values down by 1 using SQL to avoid
        # unique index [bot_id, level_index] violation.
        # Step A: shift all to negative temp values (no collision possible)
        @bot.grid_levels.reload
        ActiveRecord::Base.connection.execute(<<~SQL.squish)
          UPDATE grid_levels
          SET level_index = -(level_index)
          WHERE bot_id = #{@bot.id}
        SQL

        # Step B: shift from negative to final values (old_index - 1)
        ActiveRecord::Base.connection.execute(<<~SQL.squish)
          UPDATE grid_levels
          SET level_index = (-level_index) - 1
          WHERE bot_id = #{@bot.id}
        SQL

        # Create new top level at the end of the sequence
        new_level_index = @bot.grid_levels.reload.maximum(:level_index) + 1
        new_level = GridLevel.create!(
          bot: @bot,
          level_index: new_level_index,
          price: new_top_price,
          expected_side: 'sell',
          status: 'active',
          current_order_id: new_sell_response[:order_id],
          current_order_link_id: new_sell_response[:link_id]
        )

        Order.create!(
          bot: @bot,
          grid_level: new_level,
          exchange_order_id: new_sell_response[:order_id],
          order_link_id: new_sell_response[:link_id],
          side: 'sell',
          price: new_top_price,
          quantity: @bot.quantity_per_level,
          status: 'open',
          placed_at: Time.current
        )

        # Update bot price boundaries
        new_lower = @bot.grid_levels.reload.order(:level_index).first.price
        @bot.update!(
          lower_price: new_lower,
          upper_price: new_top_price
        )
      end

      # Phase 4: Update Redis (outside transaction — idempotent reseed)
      Grid::RedisState.new.seed(@bot.reload)

      Rails.logger.info(
        "[Trailing] Bot #{@bot.id} trailed up. " \
        "New range: #{@bot.lower_price}..#{@bot.upper_price}"
      )
    end

    def validate_lowest_level!(level)
      # Check if lowest buy is still active (has an open order)
      return if level.status == 'active' && level.expected_side == 'buy'

      # If the lowest level was already filled (e.g., rapid price swing),
      # don't trail — let OrderFillWorker process that fill first
      if level.status == 'filled'
        raise TrailError,
              "Lowest level #{level.level_index} already filled — skip trail, process fill first"
      end
    end

    def cancel_lowest_buy!(level)
      return unless level.current_order_id

      response = @client.cancel_order(
        symbol: @bot.pair,
        order_id: level.current_order_id
      )

      # If cancel fails because order was already filled, don't proceed with trail
      unless response.success?
        if response.error_code == '110001' # Order not found / already filled
          raise TrailError,
                "Lowest buy already filled on exchange (#{level.current_order_id}) — skip trail"
        end
        Rails.logger.warn("[Trailing] Cancel failed: #{response.error_message}, proceeding anyway")
      end
    end

    def place_new_top_sell(price)
      # Use a temporary level_index for the link_id — will be finalized in transaction
      temp_index = max_level_index + 1
      link_id = "g#{@bot.id}-L#{temp_index}-S-0"
      qty = @bot.quantity_per_level

      response = @client.place_order(
        symbol: @bot.pair,
        side: 'Sell',
        order_type: 'Limit',
        qty: qty.to_s,
        price: price.to_s,
        order_link_id: link_id
      )

      return nil unless response.success?

      { order_id: response.data[:orderId], link_id: link_id }
    end

    def grid_step
      if @bot.spacing_type == 'arithmetic'
        (@bot.upper_price - @bot.lower_price) / @bot.grid_count
      else
        # Geometric: ratio-based step at the top
        ratio = (@bot.upper_price / @bot.lower_price) ** (BigDecimal('1') / @bot.grid_count)
        @bot.upper_price * (ratio - 1)
      end
    end

    def round_to_tick(price)
      return price unless @bot.tick_size&.positive?

      (price / @bot.tick_size).floor * @bot.tick_size
    end
  end
end
```

### Where to Hook It

**In OrderFillWorker#handle_sell_fill**, before placing the normal counter buy order:

```ruby
def handle_sell_fill(order, grid_level, bot, client)
  # Try trailing first — if the top sell filled and trailing is on,
  # shift the grid instead of placing a normal counter buy.
  # Note: record_trade uses the original grid_level (before re-index)
  # so cycle_count is correct on the filled level, not the shifted one.
  begin
    if Grid::TrailingManager.new(bot, filled_level: grid_level, client: client).maybe_trail!
      return record_trade(order, grid_level, bot)
    end
  rescue Grid::TrailingManager::TrailError => e
    Rails.logger.warn("[Fill] Trailing skipped for bot #{bot.id}: #{e.message}")
    # Fall through to normal counter-buy logic
  end

  # ... existing counter-buy logic unchanged ...
  buy_level_index = grid_level.level_index - 1
  # ...
end
```

### Design Decisions

- **Two-phase negative index re-indexing (#3 fix).** The unique index `[bot_id, level_index]` prevents sequential re-assignment (updating index 2 to 1 when 1 still exists). The fix uses two SQL UPDATEs: first shift all indices to their negative values (guaranteed unique since originals were positive), then shift from negative to `(-index) - 1` (the final decremented values). This avoids deferred constraints (PostgreSQL-specific) and is portable.

- **Transaction wraps only DB mutations (#4 fix).** Exchange operations (cancel order, place order) happen BEFORE the transaction. If either fails, the DB is untouched — the grid stays un-trailed, which is safe. The exchange order is placed optimistically, and only if it succeeds does the transaction commit the DB changes.

- **Check lowest buy status before cancel (#I-2 fix).** `validate_lowest_level!` checks that the lowest level is still an active buy. If it's already filled (rapid price swing), trailing is aborted with a `TrailError` so `OrderFillWorker` can process the fill normally. Additionally, `cancel_lowest_buy!` checks the cancel response — if the order is already filled on exchange (error 110001), it raises `TrailError` to abort.

- **TrailError is non-fatal.** The `OrderFillWorker` hook catches `TrailError` and falls through to normal counter-buy logic. Trailing failure never breaks the grid.

- **cycle_count handled correctly (#I-3 fix).** The `record_trade` call in the trailing hook uses the original `grid_level` (the filled top sell level) — not any re-indexed level. The existing `handle_sell_fill` already increments `cycle_count` on the correct level inside `record_trade`. The trailing hook does NOT separately increment `cycle_count` (removed from original design).

- **Full Redis reseed after trail.** Since multiple levels change indices, it's simpler and safer to reseed all levels rather than surgically updating individual entries.

---

## 3. DCP Safety & Public Ticker Subscription

### Purpose

Register Bybit's Disconnected Cancel-All (DCP) so that if the WebSocket listener dies, all open orders are automatically cancelled within 40 seconds. Additionally, subscribe to the public ticker for real-time price updates (stop-loss/take-profit checks).

### Integration Points

**3a. On bot initialization** — In `Grid::Initializer#execute_initialization!`, after `transition_to!('running')`:

```ruby
def execute_initialization!
  # ... existing code ...
  transition_to!('running')
  register_dcp!          # NEW
  seed_redis
  kick_off_reconciliation
end

def register_dcp!
  response = @client.set_dcp(time_window: 40)
  if response.success?
    Rails.logger.info("[Initializer] DCP registered with 40s window for bot #{@bot.id}")
  else
    Rails.logger.warn("[Initializer] DCP registration failed: #{response.error_message}")
    # Non-fatal: bot still runs, just without DCP safety net
  end
end
```

**3b. On WebSocket reconnect** — In `Bybit::WebsocketListener::Connection#setup_connection`, after authenticate + subscribe:

```ruby
def setup_connection(connection, account)
  authenticate(connection, account)
  subscribe(connection)
  register_dcp(account)     # NEW
  subscribe_dcp(connection) # NEW
end

def register_dcp(account)
  client = Bybit::RestClient.new(
    api_key: account.api_key,
    api_secret: account.api_secret
  )
  response = client.set_dcp(time_window: 40)
  if response.success?
    Rails.logger.info('[WS] DCP registered (40s window)')
    @redis.set('grid:dcp:registered_at', Time.current.to_i.to_s)  # NEW: track DCP registration
  else
    Rails.logger.warn("[WS] DCP registration failed: #{response.error_message}")
  end
end

def subscribe_dcp(connection)
  connection.send_text(Oj.dump({ op: 'subscribe', args: ['dcp'] }))
  Rails.logger.info('[WS] Subscribed to DCP topic')
end
```

**3c. Handle DCP messages** — In `Bybit::WebsocketListener::MessageHandler#process_message`:

```ruby
def process_message(data)
  case data[:topic]
  when 'order.spot'
    data[:data]&.each { |order_data| process_order_event(order_data) }
  when 'dcp'
    handle_dcp_event(data)  # NEW
  when /\Atickers\./
    handle_ticker_event(data)  # NEW — public ticker for risk checks
  when 'execution.spot'
    Rails.logger.debug { "[WS] Execution event: #{data[:data]&.length} entries" }
  when 'wallet'
    Rails.logger.debug { '[WS] Wallet update received' }
  else
    handle_system_message(data)
  end
end

def handle_dcp_event(data)
  dcp_data = data[:data]&.first
  return unless dcp_data

  if dcp_data[:dcpStatus] == 'OFF'
    Rails.logger.error('[WS] DCP triggered -- orders may have been cancelled!')
    trigger_reconciliation_for_all_bots
  else
    Rails.logger.debug { '[WS] DCP heartbeat OK' }
    @redis.set('grid:dcp:last_confirmed', Time.current.to_i.to_s)
  end
end
```

**3d. Public ticker subscription for risk checks** — Subscribe to `tickers.{symbol}` for each running bot. Bybit's private WebSocket connection accepts public topic subscriptions on the same connection.

In `Bybit::WebsocketListener::Connection#subscribe`, extend the topic list:

```ruby
def subscribe(connection)
  topics = %w[order.spot execution.spot wallet dcp]

  # Add public ticker topics for all running bots (for real-time risk checks)
  Bot.running.pluck(:pair).uniq.each do |pair|
    topics << "tickers.#{pair}"
  end

  connection.send_text(Oj.dump({ op: 'subscribe', args: topics }))
  Rails.logger.info("[WS] Subscribed to: #{topics.join(', ')}")
end
```

In `Bybit::WebsocketListener::MessageHandler`, add the ticker handler:

```ruby
def handle_ticker_event(data)
  ticker = data[:data]
  return unless ticker

  symbol = ticker[:symbol]
  last_price = ticker[:lastPrice]
  return unless symbol && last_price

  # Run risk check for all running bots on this pair
  Bot.running.where(pair: symbol).find_each do |bot|
    Grid::RiskManager.new(bot, current_price: last_price).check!
  rescue StandardError => e
    Rails.logger.error("[WS] Risk check failed for bot #{bot.id}: #{e.message}")
  end

  # Update Redis price for all bots on this pair
  redis_state = @redis_state
  Bot.running.where(pair: symbol).pluck(:id).each do |bot_id|
    redis_state.update_price(bot_id, last_price)
  end
end
```

### DCP Visibility (#I-4 fix)

Store `dcp:registered_at` and `dcp:last_confirmed` in Redis. The `BalanceSnapshotWorker` (runs every 5min) can check if DCP hasn't been confirmed recently and log a warning:

```ruby
# In BalanceSnapshotWorker#perform, before the bot loop:
check_dcp_health

def check_dcp_health
  redis = Redis.new(url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0'))
  registered = redis.get('grid:dcp:registered_at')&.to_i
  return unless registered

  last_confirmed = redis.get('grid:dcp:last_confirmed')&.to_i || registered
  if Time.current.to_i - last_confirmed > 60
    Rails.logger.warn('[DCP] No DCP confirmation in >60s — safety net may be inactive')
  end
end
```

### Design Decisions

- **`set_dcp` already exists** in `Exchange::Adapter` and `Bybit::RestClient`. No new adapter methods needed.

- **DCP is per-account, not per-bot.** One `set_dcp` call covers all open orders for the exchange account. We register it on every connect/reconnect and on bot init (in case the WS listener hasn't started yet).

- **Non-fatal on failure.** DCP is a safety net, not a hard requirement. If registration fails (e.g., testnet issue), the bot still runs. A warning is logged.

- **The existing 20s heartbeat ping satisfies the 40s DCP window.** No changes to heartbeat interval needed.

- **DCP Redis timestamps (#I-4 fix).** `grid:dcp:registered_at` and `grid:dcp:last_confirmed` provide visibility. The BalanceSnapshotWorker checks staleness every 5 minutes and warns if DCP confirmation is overdue.

- **Public ticker on same WS connection (#I-1 fix).** Bybit allows subscribing to public topics (like `tickers.ETHUSDT`) on the authenticated private WebSocket connection. This avoids a second WebSocket connection and gives sub-second price updates for stop-loss/take-profit. The `handle_ticker_event` runs `RiskManager.check!` for each running bot on the received symbol.

---

## 4. Backend: BotsController Changes

### 4a. Permit Risk Parameters

In `Api::V1::BotsController`:

```ruby
def bot_params
  params.require(:bot).permit(
    :pair, :base_coin, :quote_coin, :lower_price, :upper_price,
    :grid_count, :spacing_type, :investment_amount,
    :stop_loss_price, :take_profit_price, :trailing_up_enabled  # NEW
  )
end
```

Also allow updating risk params on a running bot (the existing `update` action already calls `@bot.update!` for non-status fields — we just need to add a separate `update_params` method that permits the risk fields):

```ruby
def update
  if params.dig(:bot, :status)
    handle_status_change
    return if performed?
  end

  # Allow updating risk params on running bots
  @bot.update!(update_params) if update_params.present?

  render json: { bot: bot_detail(@bot, Grid::RedisState.new, recent_trades_for(@bot)) }
end

def update_params
  params.require(:bot).permit(
    :stop_loss_price, :take_profit_price, :trailing_up_enabled
  )
end
```

### 4b. Server-Side Validations

In `app/models/bot.rb`, add conditional validations:

```ruby
validate :stop_loss_below_lower_price
validate :take_profit_above_upper_price

private

def stop_loss_below_lower_price
  return unless stop_loss_price && lower_price
  return if stop_loss_price < lower_price

  errors.add(:stop_loss_price, 'must be below lower price')
end

def take_profit_above_upper_price
  return unless take_profit_price && upper_price
  return if take_profit_price > upper_price

  errors.add(:take_profit_price, 'must be above upper price')
end
```

### 4c. Expose Risk Fields in API Response

In `BotSerialization#bot_response`, add:

```ruby
def bot_response(bot)
  {
    # ... existing fields ...
    stop_loss_price: bot.stop_loss_price&.to_s,
    take_profit_price: bot.take_profit_price&.to_s,
    trailing_up_enabled: bot.trailing_up_enabled,
    stop_reason: bot.stop_reason,
  }
end
```

---

## 5. Frontend Changes

### 5a. TypeScript Types

In `frontends/app/src/types/bot.ts`, add to `Bot` interface:

```typescript
export interface Bot {
  // ... existing fields ...
  stop_loss_price?: string | null;
  take_profit_price?: string | null;
  trailing_up_enabled: boolean;
  stop_reason?: string | null;
}

export interface CreateBotParams {
  // ... existing fields ...
  stop_loss_price?: string;
  take_profit_price?: string;
  trailing_up_enabled?: boolean;
}
```

### 5b. Create Bot Wizard -- Step 2 Additions

Add risk fields to `StepSetParameters.tsx` below the spacing type toggle:

- **Stop Loss Price**: Optional `TextField`, type="number". Validation: if set, must be below `lowerPrice`.
- **Take Profit Price**: Optional `TextField`, type="number". Validation: if set, must be above `upperPrice`.
- **Trailing Grid**: `Switch` toggle, default off. Below it, an `Alert severity="info"` with caveat text: "Trailing keeps the bot running above the grid range by shifting upward. This sells base at lower prices and re-buys higher -- it is a continuity mechanism, not a profit strategy."

Update `GridParameters` interface:

```typescript
export interface GridParameters {
  lowerPrice: string;
  upperPrice: string;
  gridCount: number;
  spacingType: 'arithmetic' | 'geometric';
  stopLossPrice: string;      // NEW -- empty string = not set
  takeProfitPrice: string;    // NEW -- empty string = not set
  trailingUpEnabled: boolean; // NEW
}
```

Update `validateParameters` to include:

```typescript
if (stopLossPrice !== '' && !isNaN(parseFloat(stopLossPrice))) {
  if (parseFloat(stopLossPrice) >= lower) {
    errors.stopLossPrice = 'Must be below lower price';
  }
}
if (takeProfitPrice !== '' && !isNaN(parseFloat(takeProfitPrice))) {
  if (parseFloat(takeProfitPrice) <= upper) {
    errors.takeProfitPrice = 'Must be above upper price';
  }
}
```

Update `handleSubmit` in `CreateBotWizard.tsx` to include the risk params in the mutation payload.

### 5c. Bot Detail -- Risk Settings Card

Add a new `RiskSettingsCard` component rendered on the Bot Detail page between the stats row and the grid visualization:

```
+------------------------------------------+
| Risk Settings                    [Edit]  |
+------------------------------------------+
| Stop Loss     $1,800.00    (below grid)  |
| Take Profit   $3,200.00    (above grid)  |
| Trailing Grid    OFF                     |
+------------------------------------------+
```

**Edit mode:** Clicking Edit toggles inline `TextField` inputs for stop-loss and take-profit, plus a `Switch` for trailing. Save button calls `useUpdateBot` with the new values. Cancel reverts to display mode.

**Stop reason display:** When `bot.status === 'stopped'` and `bot.stop_reason` is `stop_loss` or `take_profit`, show a prominent `Alert severity="warning"`:

```
"Stopped: Stop Loss triggered" or "Stopped: Take Profit triggered"
```

When `bot.status === 'stopping'`, show `Alert severity="error"`:

```
"Emergency stop in progress -- if this persists, check exchange manually"
```

This replaces the generic "Bot encountered an error" alert for risk-triggered stops.

### 5d. Wire Risk Params Into CreateBotWizard Submission

In `CreateBotWizard.tsx#handleSubmit`, add to the mutation payload:

```typescript
createBot.mutate({
  // ... existing fields ...
  stop_loss_price: params.stopLossPrice || undefined,
  take_profit_price: params.takeProfitPrice || undefined,
  trailing_up_enabled: params.trailingUpEnabled,
});
```

---

## 6. Production Hardening

### 6a. systemd Unit Files

Three unit files in `config/systemd/`. All paths use `EnvironmentFile` to avoid hardcoding:

**`gridbot-puma.service`:**
```ini
[Unit]
Description=GridBot Puma (Rails API)
After=network.target postgresql.service redis.service

[Service]
Type=simple
EnvironmentFile=/etc/gridbot/env
User=${GRIDBOT_USER}
WorkingDirectory=${GRIDBOT_DIR}
ExecStart=/bin/bash -lc 'bundle exec puma -C config/puma.rb'
Restart=on-failure
RestartSec=5
SyslogIdentifier=gridbot-puma

[Install]
WantedBy=multi-user.target
```

**`gridbot-sidekiq.service`:**
```ini
[Unit]
Description=GridBot Sidekiq
After=network.target postgresql.service redis.service

[Service]
Type=simple
EnvironmentFile=/etc/gridbot/env
User=${GRIDBOT_USER}
WorkingDirectory=${GRIDBOT_DIR}
ExecStart=/bin/bash -lc 'bundle exec sidekiq -C config/sidekiq.yml'
Restart=on-failure
RestartSec=5
SyslogIdentifier=gridbot-sidekiq

[Install]
WantedBy=multi-user.target
```

**`gridbot-ws-listener.service`:**
```ini
[Unit]
Description=GridBot WebSocket Listener
After=network.target redis.service

[Service]
Type=simple
EnvironmentFile=/etc/gridbot/env
User=${GRIDBOT_USER}
WorkingDirectory=${GRIDBOT_DIR}
ExecStart=/bin/bash -lc 'bundle exec ruby bin/ws_listener'
Restart=on-failure
RestartSec=5
SyslogIdentifier=gridbot-ws

[Install]
WantedBy=multi-user.target
```

**`/etc/gridbot/env` (example):**
```bash
GRIDBOT_USER=deploy
GRIDBOT_DIR=/home/deploy/grid_bot
RAILS_ENV=production
REDIS_URL=redis://localhost:6379/0
DATABASE_URL=postgresql://localhost/grid_bot_production
```

### 6b. Development Procfile

**`Procfile.dev`** (for `foreman start -f Procfile.dev`):
```
web: bin/rails server -p 3000
worker: bundle exec sidekiq -C config/sidekiq.yml
ws: bundle exec ruby bin/ws_listener
frontend: cd frontends/app && npx vite --port 5173
```

### 6c. Rate Limiter: Monitoring + Emergency Exemption

**Monitoring:** In `Bybit::RateLimiter#update_from_headers`, add a warning log when usage exceeds 80%:

```ruby
def update_from_headers(bucket, headers)
  remaining = headers['X-Bapi-Limit-Status']&.to_i
  limit = headers['X-Bapi-Limit']&.to_i
  return unless remaining && limit && limit.positive?

  usage_pct = ((limit - remaining).to_f / limit * 100).round(1)
  if usage_pct > 80
    Rails.logger.warn("[RateLimit] #{bucket} at #{usage_pct}% usage (#{remaining}/#{limit} remaining)")
  end

  # ... existing header-based bucket update logic ...
end
```

**Emergency exemption (#WC-3 fix):** Add a `check!` option to bypass rate limiting for emergency operations:

```ruby
def check!(bucket, force: false)
  return if force

  config = BUCKETS.fetch(bucket) { raise ArgumentError, "Unknown bucket: #{bucket}" }
  key = counter_key(bucket)
  allowed = @redis.eval(CHECK_SCRIPT, keys: [key], argv: [config[:limit], config[:window]])
  raise Bybit::RateLimitError, "Rate limit exceeded for #{bucket}" if allowed.zero?
end
```

The `RestClient` needs a way to pass `force: true` for emergency calls. Add an `emergency:` option to the `post` method:

```ruby
def cancel_all_orders(symbol:, emergency: false)
  post('/v5/order/cancel-all', { category: 'spot', symbol: },
       bucket: :cancel_all_orders, force: emergency)
end

def place_order(symbol:, side:, order_type:, qty:, price: nil,
                order_link_id: nil, time_in_force: 'GTC', emergency: false)
  # ... existing params build ...
  post('/v5/order/create', params, bucket: :place_order, force: emergency)
end
```

Then in `RiskManager#execute_emergency_stop!`:

```ruby
client.cancel_all_orders(symbol: @bot.pair, emergency: true)
# ...
client.place_order(symbol:, side: 'Sell', order_type: 'Market', qty:, emergency: true)
```

---

## 7. Database Changes

**No new migrations required.** All columns exist from Phase 1:

| Column | Table | Type | Status |
|--------|-------|------|--------|
| `stop_loss_price` | `bots` | `decimal(20,8)` | Exists, nullable |
| `take_profit_price` | `bots` | `decimal(20,8)` | Exists, nullable |
| `trailing_up_enabled` | `bots` | `boolean` | Exists, default: false |
| `stop_reason` | `bots` | `string` | Exists, nullable |

---

## 8. File Inventory

### New Files

| File | Purpose |
|------|---------|
| `app/services/grid/risk_manager.rb` | Stop-loss and take-profit execution |
| `app/services/grid/trailing_manager.rb` | Grid trailing on top-sell fill |
| `config/systemd/gridbot-puma.service` | systemd unit for Puma |
| `config/systemd/gridbot-sidekiq.service` | systemd unit for Sidekiq |
| `config/systemd/gridbot-ws-listener.service` | systemd unit for WS listener |
| `config/systemd/env.example` | Example environment file |
| `Procfile.dev` | Development process manager |
| `frontends/app/src/components/RiskSettingsCard.tsx` | Bot detail risk card |

### Modified Files

| File | Changes |
|------|---------|
| `app/workers/order_fill_worker.rb` | Add risk check after fill; add trailing hook in `handle_sell_fill` |
| `app/workers/balance_snapshot_worker.rb` | Add risk check after price fetch; add DCP health check |
| `app/services/grid/initializer.rb` | Register DCP after bot goes running |
| `app/services/bybit/websocket_listener/connection.rb` | Register DCP, subscribe `dcp` + `tickers.{symbol}` topics |
| `app/services/bybit/websocket_listener/message_handler.rb` | Handle `dcp` topic + `tickers.*` topic messages |
| `app/services/bybit/rest_client.rb` | Add `emergency:` param to `cancel_all_orders` and `place_order` |
| `app/services/bybit/rate_limiter.rb` | Add `force:` param to `check!`; add >80% monitoring log |
| `app/models/bot.rb` | Add stop_loss/take_profit validations |
| `app/controllers/api/v1/bots_controller.rb` | Permit risk params in create + update |
| `app/controllers/concerns/bot_serialization.rb` | Expose risk fields in JSON |
| `frontends/app/src/types/bot.ts` | Add risk fields to Bot/CreateBotParams types |
| `frontends/app/src/components/wizard/StepSetParameters.tsx` | Add SL/TP/trailing fields |
| `frontends/app/src/components/wizard/gridParameters.ts` | Extend GridParameters + validation |
| `frontends/app/src/pages/CreateBotWizard.tsx` | Pass risk params to mutation |
| `frontends/app/src/pages/BotDetail.tsx` | Render RiskSettingsCard + stop reason alert |

---

## 9. Execution Order

Tasks should be implemented in this order (respecting dependencies):

1. **Rate limiter: `force:` param + monitoring** -- needed by RiskManager
2. **RestClient: `emergency:` param** -- needed by RiskManager
3. **Grid::RiskManager** -- standalone service, testable in isolation
4. **Bot model validations** -- add SL/TP validation rules
5. **BotsController updates** -- permit params, expose in JSON
6. **OrderFillWorker risk hook** -- integrate RiskManager after fills
7. **BalanceSnapshotWorker risk hook** -- integrate RiskManager on price poll + DCP health check
8. **Grid::TrailingManager** -- standalone service
9. **OrderFillWorker trailing hook** -- integrate TrailingManager in sell fill handler
10. **DCP: Initializer** -- register DCP on bot start
11. **DCP: WebSocket listener** -- register on connect, subscribe `dcp` + `tickers.*`, handle messages
12. **Frontend: types + wizard** -- TypeScript types, wizard step 2 risk fields
13. **Frontend: RiskSettingsCard** -- Bot detail page risk card with inline edit
14. **Production: systemd + Procfile** -- unit files, env template

---

## 10. Risk Analysis

| Risk | Impact | Mitigation |
|------|--------|------------|
| RiskManager races with OrderFillWorker | Double cancel/sell | Atomic `update_all(status: 'stopping')` with WHERE clause; loser sees 0 rows and bails |
| Market sell fails during emergency stop | Base asset stranded | Bot stays in `stopping` state; error logged with amount; `risk_error` broadcast to frontend; user must intervene |
| 5-min polling gap misses fast price crash | Late stop-loss trigger | Public ticker WS subscription provides sub-second price; BalanceSnapshotWorker is tertiary backup only |
| Trailing re-index violates unique index | Migration error | Two-phase negative index shift avoids collision |
| Trailing lowest buy already filled | Skip trail, corrupt grid | `validate_lowest_level!` checks status; `cancel_lowest_buy!` checks exchange response code |
| Exchange order placed but DB transaction fails | Orphaned order on exchange | Reconciliation worker detects and cancels orphaned orders every 15s |
| DCP triggers unexpectedly during normal ops | All orders cancelled | 40s window >> 20s heartbeat; reconciliation restores grid |
| Trailing + risk check race | Grid shifts then immediately stops | Trailing runs inside OFW; risk check runs after. If SL triggers, the trailed grid is stopped cleanly |
| Rate limiter blocks emergency stop | Stop-loss delayed | `emergency: true` bypasses rate limiter for cancel_all + market_sell |
| DCP not confirmed | Silent safety net failure | Redis timestamps + BalanceSnapshotWorker health check warns if >60s since last confirmation |

---

## Appendix: DA Finding Cross-Reference

| Finding | Category | Resolution | Section |
|---------|----------|------------|---------|
| #1 Double market sell race | Critical | Atomic `update_all` with WHERE status=running | 1 |
| #2 Market sell error handling | Critical | `MarketSellError` caught; bot stays `stopping`; broadcast `risk_error` | 1 |
| #3 Unique index collision | Critical | Two-phase negative index re-indexing | 2 |
| #4 No transaction in TrailingManager | Critical | Exchange ops outside txn; DB mutations inside txn | 2 |
| #5 Use exchange balance | Critical | `get_wallet_balance` with DB fallback | 1 |
| #I-1 5-min polling gap | Important | Public ticker WS subscription | 3d |
| #I-2 Check lowest buy status | Important | `validate_lowest_level!` + cancel response check | 2 |
| #I-3 cycle_count on wrong level | Important | `record_trade` uses original level; no separate increment | 2 |
| #I-4 DCP failure visibility | Important | Redis timestamps + health check in BalanceSnapshotWorker | 3 |
| #I-5 Use stopping state | Important | `running -> stopping` transition before exchange work | 1 |
| #WC-1 perform_async for snapshot | Small | `BalanceSnapshotWorker.perform_async` | 1 |
| #WC-3 Emergency rate limit exemption | Small | `force:` param on `check!`; `emergency:` on RestClient | 6c |
| #WC-4 Hardcoded systemd paths | Small | `EnvironmentFile=/etc/gridbot/env` | 6a |
