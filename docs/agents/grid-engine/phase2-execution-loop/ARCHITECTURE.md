# Phase 2: The Execution Loop — ARCHITECTURE

## Overview

Phase 2 transforms the GridBot from a static foundation into an autonomous trading loop. Six components work together: the **Initializer** places the grid on the exchange, the **WebSocket Listener** detects fills in real time, the **OrderFillWorker** executes the buy-sell-buy loop, the **ReconciliationWorker** repairs drift, **Redis hot state** enables fast reads, and the **BalanceSnapshotWorker** tracks portfolio health.

Data flow:

```
Exchange (Bybit)
    |
    v  (WebSocket: order.spot, execution.spot, wallet)
Bybit::WebsocketListener  [bin/ws_listener — standalone process]
    |
    v  (Sidekiq enqueue)
OrderFillWorker  [Sidekiq, critical queue]
    |
    +---> PostgreSQL (orders, grid_levels, trades)
    +---> Redis (hot state)
    +---> Bybit REST API (place counter-order)

GridReconciliationWorker  [Sidekiq-cron, every 15s]
    |
    +---> Bybit REST API (get_open_orders, get_order_history)
    +---> PostgreSQL (detect + repair gaps)

BalanceSnapshotWorker  [Sidekiq-cron, every 5min]
    +---> PostgreSQL (balance_snapshots)
```

---

## 1. Grid::Initializer

**File:** `app/services/grid/initializer.rb`

A service object that takes a `Bot` record from `pending` to `running`, placing the full grid on the exchange.

### Public Interface

```ruby
module Grid
  class Initializer
    def initialize(bot)
      @bot = bot
    end

    # Returns the bot (now in 'running' status).
    # Raises Grid::Initializer::Error on unrecoverable failure.
    def call
      # ...
    end
  end
end
```

### Flow

```
1. Validate bot is in 'pending' status
2. Transition bot to 'initializing'
3. Build REST client from bot.exchange_account
4. Fetch instrument info -> store tick_size, min_order_amt, min_order_qty, base_precision, quote_precision on bot
5. Fetch current market price via get_tickers
6. Calculate grid levels via Grid::Calculator
7. Classify levels (buy/sell/skip) relative to current price
8. Calculate quantity_per_level
9. Validate min_order constraints
10. Determine base asset needed for sell-side orders
11. If insufficient base balance: place market buy for the deficit
12. Persist grid_level records to DB (status: pending)
13. Batch-place limit orders (max 20 per batch, rate-limited)
14. For each successful order response:
    - Update grid_level: status=active, current_order_id, current_order_link_id
    - Create Order record: status=open, exchange_order_id, placed_at
15. For skipped (neutral zone) levels: set grid_level status=skipped
16. Transition bot to 'running'
17. Seed Redis hot state
```

### Status Transitions

```
pending -> initializing  (step 2, before any exchange calls)
initializing -> running  (step 16, after all orders placed)
initializing -> error    (on unrecoverable failure)
```

### Error Recovery

The initializer wraps the exchange interaction phase (steps 10-14) so that partial failures leave the bot in `initializing` status with whatever grid_levels/orders were created. The reconciliation worker (once the bot transitions to `running`) will detect and fill any gaps. This avoids complex rollback logic.

**Specific error scenarios:**

| Scenario | Handling |
|----------|----------|
| Instrument info fetch fails | Raise error, bot stays `pending` (nothing placed yet) |
| Market buy for base asset fails | Transition to `error`, log reason. Operator must fix balance and retry. |
| Batch order partially succeeds | Process successful orders normally. Failed orders within the batch are logged. After all batches complete, check for gaps. If critical gap count > 50%, transition to `error`. Otherwise proceed to `running` — reconciliation will fix minor gaps. |
| Rate limit hit during batches | Sleep until reset timestamp (from rate limiter headers), then resume. The initializer is synchronous — it can afford to wait. |

### Batch Placement Detail

Bybit `POST /v5/order/create-batch` accepts max 20 orders. For a 50-level grid, that's 3 batches. Each batch response returns per-order success/failure:

```json
{
  "retCode": 0,
  "result": {
    "list": [
      { "orderId": "123", "orderLinkId": "g1-L0-B-0", "code": "0" },
      { "orderId": "",    "orderLinkId": "g1-L1-B-0", "code": "170213", "msg": "..." }
    ]
  }
}
```

The initializer iterates the response list and matches each entry by `orderLinkId` back to the corresponding grid_level. Entries with `code != "0"` are logged as warnings but do not abort the initialization.

### Quantity for Sell-Side Orders

Sell-side levels need base asset. The initializer calculates the total base needed:

```ruby
sell_levels_count = classification.count { |_, side| side == :sell }
total_base_needed = quantity_per_level * sell_levels_count
```

It fetches the wallet balance via `get_wallet_balance(coin: bot.base_coin)`. If `available_balance < total_base_needed`, it places a market buy for the deficit:

```ruby
deficit = total_base_needed - available_balance
client.place_order(
  symbol: bot.pair,
  side: "Buy",
  order_type: "Market",
  qty: deficit.ceil(bot.base_precision).to_s
)
```

This market buy is **not** tracked as a grid order — it is infrastructure for setting up the grid. Its cost is implicitly part of the investment.

### Order Link ID Generation

```ruby
def order_link_id(bot_id, level_index, side, cycle_count)
  side_char = side == "buy" ? "B" : "S"
  "g#{bot_id}-L#{level_index}-#{side_char}-#{cycle_count}"
end

# Regex to detect our own order link IDs (used by reconciliation)
ORDER_LINK_ID_PATTERN = /\Ag(\d+)-L(\d+)-(B|S)-(\d+)\z/
```

Delimiters (`-`) eliminate parsing ambiguity (e.g., `g1-L23-B-4` vs `g12-L3-B-4` — without delimiters both would be `g1L23B4` / `g12L3B4` which is unambiguous in this case, but delimiters make regex extraction reliable and human-readable).

Max 36 chars (Bybit limit). With bot IDs up to 999999 and level indexes up to 999, this stays well under the limit. Example: `g12-L25-B-3` = bot 12, level 25, buy, 3rd cycle.

---

## 2. Bybit::WebsocketListener

**File:** `app/services/bybit/websocket_listener.rb`
**Entry point:** `bin/ws_listener`

A long-lived standalone process (not a Sidekiq worker) that maintains a persistent WebSocket connection to Bybit's private stream.

The listener holds explicit instances of its dependencies — `@redis` for stream publishing, `@redis_state` (a `Grid::RedisState` instance) for hot state updates. No use of `Redis.current` or global state.

### Architecture Decision: Why a Separate Process

The WebSocket listener runs as its own OS process rather than as a Sidekiq worker because:
- It needs a persistent, long-lived connection (WebSocket)
- Sidekiq workers are designed for short-lived, stateless jobs
- A single connection handles all bots on the same exchange account
- Process isolation means a crash doesn't affect Sidekiq job processing

### Technology: async-websocket

Uses the `async-websocket` gem (already in Gemfile), which is built on the `async` gem (fiber-based concurrency). No EventMachine dependency. This gives us:
- Non-blocking I/O with simple sequential-looking code
- Built-in task management for heartbeat timers
- Clean cancellation via `Async::Task#stop`

### Connection Lifecycle

```
1. Load Rails environment
2. Find active ExchangeAccount(s)
3. For each account:
   a. Connect to wss://stream-testnet.bybit.com/v5/private
   b. Authenticate (HMAC)
   c. Subscribe to: order.spot, execution.spot, wallet
   d. Start heartbeat task (ping every 20s)
   e. Enter message read loop
4. On SIGTERM/SIGINT: graceful shutdown
```

### Authentication

Bybit private WebSocket auth uses a different signing scheme than REST:

```ruby
expires = ((Time.now.to_f * 1000).to_i + 5000).to_s  # 5s from now
signature = OpenSSL::HMAC.hexdigest("SHA256", api_secret, "GET/realtime#{expires}")

ws.write({ op: "auth", args: [api_key, expires, signature] })
```

After auth, subscribe:

```ruby
ws.write({ op: "subscribe", args: ["order.spot", "execution.spot", "wallet"] })
```

### Message Processing

```ruby
# Pseudo-code for the message read loop
# Read timeout of 30s — if no message (including pong) arrives within 30s,
# treat the connection as dead and trigger reconnection.
WS_READ_TIMEOUT = 30

loop do
  message = Async::Task.current.with_timeout(WS_READ_TIMEOUT) { ws.read }
  data = Oj.load(message.buffer, symbol_keys: true)

  case data[:topic]
  when "order.spot"
    data[:data].each do |order_data|
      process_order_event(order_data)
    end
  when "execution.spot"
    # Log for debugging; primary processing is via order.spot
  when "wallet"
    # Update Redis hot state with balance info
  end
end
```

### Order Event Processing

On receiving an `order.spot` event where `orderStatus == "Filled"`:

```ruby
def process_order_event(order_data)
  return unless order_data[:orderStatus] == "Filled"

  # Publish to Redis stream for audit trail
  publish_to_redis_stream(order_data)

  # Enqueue Sidekiq worker for DB processing
  OrderFillWorker.perform_async(order_data.to_json)
end
```

The listener does **not** process fills itself — it delegates to Sidekiq for transactional DB work. This keeps the WebSocket loop fast and non-blocking.

### Redis Stream (Audit Trail)

Every fill event is published to a Redis stream `grid:fills` before being enqueued:

```ruby
def publish_to_redis_stream(order_data)
  @redis.xadd("grid:fills", {
    order_id: order_data[:orderId],
    order_link_id: order_data[:orderLinkId],
    symbol: order_data[:symbol],
    side: order_data[:side],
    status: order_data[:orderStatus],
    qty: order_data[:qty],
    price: order_data[:avgPrice],
    timestamp: Time.now.to_i
  })
end
```

The stream is capped at 10,000 entries (`MAXLEN ~ 10000`) to prevent unbounded growth. This is a debugging/audit aid, not the primary processing path.

### Heartbeat

```ruby
# Inside the Async reactor, a separate task:
Async do |task|
  task.async do
    loop do
      sleep 20
      ws.write({ op: "ping" })
    end
  end
end
```

Bybit expects a ping every 20 seconds and will disconnect after ~30 seconds of silence.

### Reconnection

When the connection drops (read error, `Async::TimeoutError` from read timeout, close frame):

```ruby
def connect_with_reconnect
  backoff = 1
  max_backoff = 30

  loop do
    begin
      connect_and_listen
    rescue => e
      Rails.logger.error("[WS] Connection lost: #{e.message}. Reconnecting in #{backoff}s...")

      # On reconnect: trigger reconciliation for all running bots
      trigger_reconciliation_for_all_bots

      sleep backoff
      backoff = [backoff * 2, max_backoff].min
    end
  end
end

def trigger_reconciliation_for_all_bots
  Bot.running.find_each do |bot|
    GridReconciliationWorker.perform_async(bot.id)
  end
end
```

On successful reconnection, backoff resets to 1.

### Maintenance Detection

Bybit sends HTTP 503 or WebSocket close code 1001 during scheduled maintenance:

```ruby
rescue Async::WebSocket::ClosedError => e
  if e.code == 1001  # Going Away (maintenance)
    pause_all_bots("maintenance")
    # Retry every 30s with special maintenance backoff
    maintenance_reconnect_loop
  else
    # Normal reconnection logic
    raise
  end
end

def pause_all_bots(reason)
  Bot.running.find_each do |bot|
    bot.update!(status: "paused", stop_reason: reason)
    @redis_state.update_status(bot.id, "paused")
  end
end
```

When connectivity is restored, the listener resumes all bots that were paused with `stop_reason: "maintenance"`:

```ruby
def resume_after_maintenance
  Bot.where(status: "paused", stop_reason: "maintenance").find_each do |bot|
    bot.update!(status: "running", stop_reason: nil)
    @redis_state.update_status(bot.id, "running")
  end
  trigger_reconciliation_for_all_bots
end
```

### Graceful Shutdown

```ruby
shutdown = false

%w[TERM INT].each do |signal|
  Signal.trap(signal) do
    shutdown = true
    # The async reactor will check this flag
  end
end
```

Within the async reactor, the shutdown flag causes:
1. Cancel all async tasks (heartbeat, read loop)
2. Send WebSocket close frame
3. Wait up to 5 seconds for pending Sidekiq enqueues to complete
4. Exit process cleanly

---

## 3. bin/ws_listener Entry Point

**File:** `bin/ws_listener`

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../config/environment"

Rails.logger = ActiveSupport::Logger.new($stdout)
Rails.logger.level = ENV.fetch("WS_LOG_LEVEL", "info").to_sym

listener = Bybit::WebsocketListener.new
listener.run
```

Make executable: `chmod +x bin/ws_listener`

Run: `bundle exec bin/ws_listener`

The script loads the full Rails environment so it has access to models, Redis, and Sidekiq client. It writes logs to stdout (suitable for systemd/docker log capture).

---

## 4. OrderFillWorker

**File:** `app/workers/order_fill_worker.rb`

The core of the grid trading loop. Receives fill data from the WebSocket listener and executes the counter-order logic.

### Sidekiq Configuration

```ruby
class OrderFillWorker
  include Sidekiq::Worker

  sidekiq_options queue: :critical, retry: 5,
                  lock: :until_executed  # Sidekiq unique job (if available)
end
```

Queue: `critical` (higher priority than reconciliation/snapshots).
Retries: 5 with exponential backoff. `StaleObjectError` retries are immediate (see below).

### Argument

The worker receives the raw order data JSON from the WebSocket message:

```ruby
def perform(order_data_json, retry_count = 0)
  order_data = Oj.load(order_data_json, symbol_keys: true)
  process_fill(order_data, retry_count)
end
```

### Processing Flow

```
1. FIND ORDER
   - Lookup by exchange_order_id first, fall back to order_link_id
   - If not found:
     a. Check if orderLinkId matches our pattern (ORDER_LINK_ID_PATTERN regex)
     b. If it matches: this is likely a rapid-fill race — the counter-order
        was placed on the exchange but the DB record hasn't been created yet
        (the buy fill worker hasn't finished). Re-enqueue with delay:
        OrderFillWorker.perform_in(5, order_data_json, retry_count + 1)
        Max 3 re-enqueues. After that, log error for manual investigation.
     c. If it doesn't match: truly foreign order. Log warning, return.

2. IDEMPOTENCY CHECK
   - If order.status == 'filled': log duplicate, return
   - This handles duplicate WebSocket messages

3. TRANSACTION + OPTIMISTIC LOCK
   ActiveRecord::Base.transaction do
     grid_level = order.grid_level.lock_version  # reload with lock

     4. UPDATE ORDER
        order.update!(
          status: 'filled',
          filled_quantity: order_data[:cumExecQty],
          avg_fill_price: order_data[:avgPrice],
          fee: order_data[:cumExecFee],
          fee_coin: order_data[:feeCurrency],
          filled_at: Time.at(order_data[:updatedTime].to_i / 1000)
        )

     5. CALCULATE NET QUANTITY
        if order.fee_coin == bot.base_coin && order.side == 'buy'
          order.update!(net_quantity: order.filled_quantity - order.fee)
        else
          order.update!(net_quantity: order.filled_quantity)
        end

     6. UPDATE GRID LEVEL
        grid_level.update!(status: 'filled')

     7. PLACE COUNTER-ORDER (see below)

     8. UPDATE REDIS HOT STATE
   end

RESCUE ActiveRecord::StaleObjectError
   -> retry (re-read grid_level, try again — max 3 retries in-process)
```

### The Core Loop: Counter-Order Logic

**When a BUY fills at level N:**

```ruby
def handle_buy_fill(order, grid_level, bot)
  sell_level_index = grid_level.level_index + 1
  sell_level = bot.grid_levels.find_by!(level_index: sell_level_index)
  sell_price = sell_level.price

  # Fee-adjusted quantity: sell only what we actually received
  sell_qty = order.net_quantity.truncate(bot.base_precision)

  link_id = order_link_id(bot.id, sell_level.level_index, "sell", sell_level.cycle_count)

  response = client.place_order(
    symbol: bot.pair,
    side: "Sell",
    order_type: "Limit",
    qty: sell_qty,
    price: sell_price,
    order_link_id: link_id
  )

  if response.success?
    sell_order = Order.create!(
      bot: bot,
      grid_level: sell_level,
      exchange_order_id: response.data[:orderId],
      order_link_id: link_id,
      side: "sell",
      price: sell_price,
      quantity: sell_qty,
      status: "open",
      placed_at: Time.current,
      paired_order_id: order.id  # Link back to the buy that triggered this sell
    )

    sell_level.update!(
      status: "active",
      expected_side: "sell",
      current_order_id: response.data[:orderId],
      current_order_link_id: link_id
    )
  else
    # Log error — reconciliation will catch the gap
    Rails.logger.error("[Fill] Failed to place sell counter-order: #{response.error_message}")
  end
end
```

**When a SELL fills at level N:**

```ruby
def handle_sell_fill(order, grid_level, bot)
  buy_level_index = grid_level.level_index - 1
  buy_level = bot.grid_levels.find_by!(level_index: buy_level_index)
  buy_price = buy_level.price

  # Use the stored quantity — set once during initialization, never recalculated
  buy_qty = bot.quantity_per_level

  link_id = order_link_id(bot.id, buy_level.level_index, "buy", buy_level.cycle_count)

  response = client.place_order(
    symbol: bot.pair,
    side: "Buy",
    order_type: "Limit",
    qty: buy_qty,
    price: buy_price,
    order_link_id: link_id
  )

  if response.success?
    buy_order = Order.create!(
      bot: bot,
      grid_level: buy_level,
      exchange_order_id: response.data[:orderId],
      order_link_id: link_id,
      side: "buy",
      price: buy_price,
      quantity: buy_qty,
      status: "open",
      placed_at: Time.current,
      paired_order_id: order.id  # Link back to the sell that triggered this buy
    )

    buy_level.update!(
      status: "active",
      expected_side: "buy",
      current_order_id: response.data[:orderId],
      current_order_link_id: link_id
    )
  else
    Rails.logger.error("[Fill] Failed to place buy counter-order: #{response.error_message}")
  end

  # Increment cycle count on the SELL level (a full buy+sell cycle completed)
  grid_level.update!(cycle_count: grid_level.cycle_count + 1)

  # Record the trade
  record_trade(order, grid_level, bot)
end
```

### Trade Recording

When a sell fills, we look up the corresponding buy order via `paired_order_id` to record the completed trade. The `paired_order_id` was set when the sell counter-order was created in `handle_buy_fill`, so it directly links back to the originating buy — even though the buy and sell are on different grid levels (buy at N, sell at N+1).

```ruby
def record_trade(sell_order, grid_level, bot)
  # The buy order is directly linked via paired_order_id (set in handle_buy_fill)
  buy_order = Order.find(sell_order.paired_order_id)

  quantity = sell_order.net_quantity
  buy_price = buy_order.avg_fill_price
  sell_price = sell_order.avg_fill_price

  gross_profit = (sell_price - buy_price) * quantity

  # Normalize fees to quote currency
  buy_fee_in_quote = normalize_fee_to_quote(buy_order, bot)
  sell_fee_in_quote = normalize_fee_to_quote(sell_order, bot)
  total_fees = buy_fee_in_quote + sell_fee_in_quote

  net_profit = gross_profit - total_fees

  Trade.create!(
    bot: bot,
    grid_level: grid_level,
    buy_order: buy_order,
    sell_order: sell_order,
    buy_price: buy_price,
    sell_price: sell_price,
    quantity: quantity,
    gross_profit: gross_profit,
    total_fees: total_fees,
    net_profit: net_profit,
    completed_at: sell_order.filled_at
  )
end

def normalize_fee_to_quote(order, bot)
  if order.fee_coin == bot.quote_coin
    order.fee
  elsif order.fee_coin == bot.base_coin
    # Fee was in base coin — convert to quote using fill price
    order.fee * order.avg_fill_price
  else
    # Fee in third coin (e.g., BNB, platform token). This should not happen
    # if "fee deduction using other coin" is disabled in Bybit account settings.
    # Log warning and treat as zero to avoid corrupting profit calculations.
    Rails.logger.warn("[Fill] Fee in unexpected coin #{order.fee_coin} for order #{order.id}. " \
                       "Disable 'fee deduction using other coin' in Bybit account settings.")
    BigDecimal("0")
  end
end
```

**Important prerequisite:** The Bybit account MUST have "Fee deduction using other coin" disabled in account settings. This ensures fees are always in base or quote coin. The third-coin guard above is defensive — if it ever triggers, it indicates a misconfigured account.

### Concurrency Control: Optimistic Locking

The `grid_levels.lock_version` column enables Rails optimistic locking. If two `OrderFillWorker` instances race on the same grid_level:

1. Both read `grid_level` with `lock_version = 3`
2. Worker A updates grid_level, Rails increments `lock_version` to 4
3. Worker B tries to update with `lock_version = 3` — Rails raises `ActiveRecord::StaleObjectError`
4. Worker B catches the error and retries (re-reads the grid_level, checks state, and decides whether to proceed)

```ruby
def process_fill(order_data)
  retries = 0
  begin
    execute_fill_processing(order_data)
  rescue ActiveRecord::StaleObjectError
    retries += 1
    raise if retries > 3  # Let Sidekiq retry handle it
    order = Order.find_by(exchange_order_id: order_data[:orderId])
    retry unless order&.status == "filled"  # Already processed by the other worker
  end
end
```

### Edge Cases

| Scenario | Handling |
|----------|----------|
| Counter-order at level 0 (bottom) after sell fills | No buy below level 0 — the sell at level 0 means price dropped through the entire grid. Log warning. The level stays `filled` until reconciliation or price recovery. |
| Counter-order above top level after buy fills | No sell above the last level — price rose through the entire grid. Same handling as above. |
| Order not found in DB (our pattern) | Rapid-fill race: re-enqueue with 5s delay, max 3 retries. See "FIND ORDER" step above. |
| Order not found in DB (foreign pattern) | Skip — order from another system or manually placed. |
| Rate limit on counter-order placement | Log error, return. Reconciliation will detect the gap within 15s. |
| `net_quantity` results in qty below `min_order_qty` | Log warning. Place order anyway (exchange will reject). Reconciliation handles. |
| Partial fill (order status `PartiallyFilled`) | See "Partial Fill Handling" section below. |

### Partial Fill Handling

**Known limitation for Phase 2.** Bybit limit orders can be partially filled. The WebSocket listener only dispatches fills when `orderStatus == "Filled"` (fully filled). Partially filled orders are handled as follows:

**Reconciliation detection:** The `GridReconciliationWorker` checks for orders that have been in `PartiallyFilled` status on the exchange for longer than 10 minutes. When detected:

1. Log a warning with the order details and fill percentage.
2. If fill percentage >= 95%: cancel the remaining unfilled portion on the exchange, then process as a full fill with the actual `cumExecQty` as the filled amount. This prevents tiny leftover orders from blocking the grid.
3. If fill percentage < 95%: leave the order open. Log for operator awareness.

**Mitigation:** Use `PostOnly` time-in-force for all limit orders during initialization. This ensures orders are always maker orders and never partially fill as takers. Counter-orders placed by `OrderFillWorker` also use `PostOnly` when possible, falling back to `GTC` if `PostOnly` is rejected (e.g., if the order would immediately match).

**Monitoring:** Orders in `PartiallyFilled` state for > 10 minutes should trigger an alert (Rails logger warn level). Operators can investigate and manually intervene via Rails console if needed.

### Buy Quantity Calculation

For buy counter-orders, the worker reads `bot.quantity_per_level` directly. This value is set once during initialization by `Grid::Initializer` and never recalculated. There is no fallback — if `quantity_per_level` is nil (which should be impossible for a running bot), the worker raises an error.

```ruby
# In handle_sell_fill:
buy_qty = bot.quantity_per_level
raise "Bot #{bot.id} has no quantity_per_level set" unless buy_qty
```

---

## 5. GridReconciliationWorker

**File:** `app/workers/grid_reconciliation_worker.rb`

Runs every 15 seconds to detect and repair discrepancies between the exchange and local DB state.

### Sidekiq Configuration

```ruby
class GridReconciliationWorker
  include Sidekiq::Worker

  sidekiq_options queue: :default, retry: 3
end
```

### Two Modes

1. **Scheduled (cron):** `GridReconciliationWorker.perform_async` with no args — iterates all running bots.
2. **On-demand:** `GridReconciliationWorker.perform_async(bot_id)` — reconciles a single bot (triggered on WS reconnect).

```ruby
def perform(bot_id = nil)
  bots = bot_id ? [Bot.find(bot_id)] : Bot.running.to_a
  bots.each { |bot| reconcile(bot) }
end
```

### Reconciliation Flow (per bot)

```
1. Fetch all open orders from exchange (paginated via cursor)
2. Build exchange_orders hash: { order_link_id => order_data }
3. Build local_orders: bot.orders.active (status: open | partially_filled)
4. Compare:

   A. MISSING ON EXCHANGE (in DB as active, not on exchange):
      - Query order history to determine fate
      - If filled: process as fill (enqueue OrderFillWorker)
      - If cancelled: mark as cancelled in DB
      - If not found: mark as cancelled (exchange may have auto-cancelled)

   B. ON EXCHANGE BUT NOT IN DB (orphan):
      - Check if orderLinkId matches ORDER_LINK_ID_PATTERN
      - If it matches our bot: ADOPT the order — create the missing DB records
        (Order + update GridLevel). This handles the case where the API call
        for a counter-order succeeded but the subsequent DB commit failed.
      - If it does NOT match any running bot: cancel the order on exchange.
      - Log either way for monitoring.

   C. GRID GAPS (levels with no active order and not in terminal state):
      - For each grid_level where status is 'filled' or 'pending' (no active order):
        - Determine correct side based on expected_side
        - Place appropriate limit order
        - Update grid_level and create order record

5. REFRESH REDIS HOT STATE
   After all repairs for a bot, refresh Redis from DB truth:
   - Update all level entries in grid:{bot_id}:levels
   - Update stats (trade_count, realized_profit)
   - Update status
   This ensures Redis stays consistent even if fill events were missed.
```

### API Requirement: get_order_history

The reconciliation worker needs to query order history to determine whether a missing order was filled or cancelled. This requires a new adapter method not present in Phase 1:

```ruby
# Exchange::Adapter addition
def get_order_history(symbol:, order_id: nil, order_link_id: nil, cursor: nil, limit: 50)
  raise NotImplementedError
end
```

**Bybit endpoint:** `GET /v5/order/history?category=spot`

This maps to the `order_batch` rate limit bucket (10 req/s).

### Rate Budget

Each reconciliation cycle per bot costs approximately:
- 1 call: `get_open_orders` (may need 2+ if > 50 open orders)
- 0-N calls: `get_order_history` (one per missing order, usually 0)
- 0-N calls: `cancel_order` (one per orphan, usually 0)
- 0-N calls: `place_order` (one per gap, usually 0)

Typical: ~2-4 requests per bot per cycle. With the 10 req/s batch limit, this supports 2-3 bots comfortably at a 15s interval.

### Pagination for Open Orders

Bybit returns max 50 open orders per page with a cursor:

```ruby
def fetch_all_open_orders(client, symbol)
  orders = []
  cursor = nil

  loop do
    response = client.get_open_orders(symbol: symbol, cursor: cursor, limit: 50)
    break unless response.success?

    orders.concat(response.data[:list])
    cursor = response.data[:nextPageCursor]
    break if cursor.nil? || cursor.empty?
  end

  orders
end
```

### Gap Detection

A "gap" is a grid level that should have an active order but doesn't:

```ruby
def detect_gaps(bot, exchange_order_ids)
  # Re-check bot status before making changes — bot may have been stopped
  return unless bot.reload.status == "running"

  bot.grid_levels.where.not(status: "skipped").find_each do |level|
    next if level.current_order_id.present? && exchange_order_ids.include?(level.current_order_id)
    next if level.status == "skipped"

    # This level has no active order on exchange
    repair_gap(level, bot)
  end
end
```

---

## 6. Redis Hot State

### Key Structure

```
grid:{bot_id}:status         -> String: "running" | "paused" | "stopped" | ...
grid:{bot_id}:current_price  -> String: "2543.50"
grid:{bot_id}:levels         -> Hash: { "0" => JSON, "1" => JSON, ... }
grid:{bot_id}:stats          -> Hash: { "realized_profit" => "12.50", "trade_count" => "42", "uptime_seconds" => "86400" }
```

### Level Hash Value Format

Each level entry in the `grid:{bot_id}:levels` hash:

```json
{
  "side": "buy",
  "status": "active",
  "price": "2500.00",
  "order_id": "123456",
  "cycle_count": 3
}
```

### Update Points

| Event | Keys Updated |
|-------|-------------|
| Bot initialization complete | `status`, `current_price`, `levels`, `stats` (all seeded) |
| Order fill processed | `levels` (affected level), `stats` (realized_profit, trade_count), `current_price` |
| Bot paused/stopped | `status` |
| Balance snapshot | `current_price` |

### Update Implementation

```ruby
module Grid
  class RedisState
    PREFIX = "grid"

    def initialize(redis: nil)
      @redis = redis || Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0"))
    end

    def seed(bot)
      @redis.pipelined do |pipe|
        pipe.set("#{PREFIX}:#{bot.id}:status", bot.status)
        pipe.set("#{PREFIX}:#{bot.id}:stats", Oj.dump({
          realized_profit: "0",
          trade_count: "0",
          uptime_start: Time.current.to_i.to_s
        }))
        bot.grid_levels.each do |level|
          pipe.hset("#{PREFIX}:#{bot.id}:levels", level.level_index.to_s, level_json(level))
        end
      end
    end

    def update_on_fill(bot, grid_level, trade = nil)
      @redis.pipelined do |pipe|
        pipe.hset("#{PREFIX}:#{bot.id}:levels", grid_level.level_index.to_s, level_json(grid_level))
        if trade
          pipe.hincrby("#{PREFIX}:#{bot.id}:stats", "trade_count", 1)
          pipe.hset("#{PREFIX}:#{bot.id}:stats", "realized_profit",
                    bot.trades.sum(:net_profit).to_s)
        end
      end
    end

    def update_price(bot_id, price)
      @redis.set("#{PREFIX}:#{bot_id}:current_price", price.to_s)
    end

    def update_status(bot_id, status)
      @redis.set("#{PREFIX}:#{bot_id}:status", status)
    end

    def cleanup(bot_id)
      # Delete known keys explicitly — never use KEYS in production (O(N) scan)
      suffixes = %w[status current_price levels stats]
      keys = suffixes.map { |s| "#{PREFIX}:#{bot_id}:#{s}" }
      @redis.del(*keys)
    end

    private

    def level_json(level)
      Oj.dump({
        side: level.expected_side,
        status: level.status,
        price: level.price.to_s,
        order_id: level.current_order_id,
        cycle_count: level.cycle_count
      })
    end
  end
end
```

### No TTL

Hot state keys have no expiration. They are explicitly deleted when a bot stops (`cleanup`). This ensures data is always available for running bots and never stale-expires mid-operation.

---

## 7. BalanceSnapshotWorker

**File:** `app/workers/balance_snapshot_worker.rb`

### Sidekiq Configuration

```ruby
class BalanceSnapshotWorker
  include Sidekiq::Worker

  sidekiq_options queue: :default, retry: 3
end
```

Cron: every 5 minutes (added to `config/sidekiq.yml`).

### Processing Flow

```ruby
def perform
  Bot.running.find_each do |bot|
    create_snapshot(bot)
  rescue => e
    Rails.logger.error("[Snapshot] Failed for bot #{bot.id}: #{e.message}")
    # Continue with next bot — don't let one failure block all
  end
end

def create_snapshot(bot)
  client = Bybit::RestClient.new(exchange_account: bot.exchange_account)

  # Current price
  ticker = client.get_tickers(symbol: bot.pair)
  return unless ticker.success?
  current_price = BigDecimal(ticker.data[:list].first[:lastPrice])

  # Base balance: sum of active buy fills minus sold quantities
  base_held = calculate_base_held(bot)

  # Quote balance: investment minus spent on buys plus received from sells
  quote_balance = calculate_quote_balance(bot)

  total_value = quote_balance + (base_held * current_price)
  realized_profit = bot.trades.sum(:net_profit)

  # Unrealized PnL: how much the held base is worth vs what we paid
  avg_buy_price = calculate_avg_buy_price(bot)
  unrealized_pnl = avg_buy_price.positive? ? (current_price - avg_buy_price) * base_held : BigDecimal("0")

  BalanceSnapshot.create!(
    bot: bot,
    base_balance: base_held,
    quote_balance: quote_balance,
    total_value_quote: total_value,
    current_price: current_price,
    realized_profit: realized_profit,
    unrealized_pnl: unrealized_pnl,
    granularity: "fine",
    snapshot_at: Time.current
  )

  # Update Redis hot state with latest price
  Grid::RedisState.new.update_price(bot.id, current_price)
end
```

### Balance Calculation Logic

```ruby
# Base held = quantity from filled buys that hasn't been sold yet
def calculate_base_held(bot)
  # Sum net_quantity of all filled buys
  bought = bot.orders.buys.filled.sum(:net_quantity)
  # Minus net_quantity of all filled sells
  sold = bot.orders.sells.filled.sum(:net_quantity)
  bought - sold
end

# Quote balance = investment - quote spent on buys + quote received from sells
def calculate_quote_balance(bot)
  bot.investment_amount -
    bot.orders.buys.filled.sum("avg_fill_price * filled_quantity") +
    bot.orders.sells.filled.sum("avg_fill_price * filled_quantity") -
    quote_fees(bot)
end

# Average buy price of currently held base
def calculate_avg_buy_price(bot)
  # Filled buys that don't yet have a corresponding sell
  active_buys = bot.orders.buys.filled
    .where.not(id: bot.trades.select(:buy_order_id))
  return BigDecimal("0") if active_buys.empty?

  total_cost = active_buys.sum("avg_fill_price * net_quantity")
  total_qty = active_buys.sum(:net_quantity)
  total_qty.positive? ? total_cost / total_qty : BigDecimal("0")
end
```

---

## 8. Exchange::Adapter Additions

Phase 2 requires one new method on the adapter interface:

```ruby
# app/services/exchange/adapter.rb — add:
def get_order_history(symbol:, order_id: nil, order_link_id: nil, cursor: nil, limit: 50)
  raise NotImplementedError
end
```

And the corresponding Bybit implementation:

```ruby
# app/services/bybit/rest_client.rb — add:
def get_order_history(symbol:, order_id: nil, order_link_id: nil, cursor: nil, limit: 50)
  params = { category: "spot", symbol: }
  params[:orderId] = order_id if order_id
  params[:orderLinkId] = order_link_id if order_link_id
  params[:cursor] = cursor if cursor
  params[:limit] = limit
  get("/v5/order/history", params, authenticated: true, bucket: :get_open_orders)
end
```

The `BUCKET_MAP` should also be updated:

```ruby
BUCKET_MAP = {
  # ... existing entries ...
  get_order_history: :order_batch,
}.freeze
```

---

## 9. Sidekiq Configuration Updates

**File:** `config/sidekiq.yml` — additions for Phase 2:

```yaml
:queues:
  - critical
  - default

:schedule:
  snapshot_retention:
    cron: "0 3 * * *"
    class: SnapshotRetentionJob
    description: "Daily cleanup of balance snapshots (03:00 UTC)"
  balance_snapshot:
    cron: "*/5 * * * *"
    class: BalanceSnapshotWorker
    description: "Capture portfolio balance snapshots every 5 minutes"
```

Note: `critical` queue is listed first so it gets higher processing priority.

**Reconciliation is NOT cron-scheduled.** It uses self-scheduling (see below) because standard Sidekiq cron only supports minute-level granularity, and we need 15-second intervals.

### Self-Scheduling Reconciliation with Redis Mutex

```ruby
class GridReconciliationWorker
  include Sidekiq::Worker
  sidekiq_options queue: :default, retry: 0

  SCHEDULE_LOCK_KEY = "grid:reconciliation:scheduled"
  SCHEDULE_LOCK_TTL = 30  # seconds — longer than the 15s interval to prevent gaps

  def perform(bot_id = nil)
    bots = bot_id ? [Bot.find(bot_id)] : Bot.running.to_a
    bots.each do |bot|
      bot.reload  # Re-check status — bot may have been stopped since enqueue
      next unless bot.status == "running"
      reconcile(bot)
    end
  ensure
    # Re-enqueue self in 15 seconds (only for the scheduled mode, not on-demand)
    schedule_next if bot_id.nil?
  end

  private

  def schedule_next
    return unless Bot.running.exists?

    redis = Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0"))
    # SET NX ensures only one chain exists — prevents duplicate chains
    if redis.set(SCHEDULE_LOCK_KEY, Time.current.to_i, nx: true, ex: SCHEDULE_LOCK_TTL)
      GridReconciliationWorker.perform_in(15, nil)
    end
  end
end
```

The Redis mutex (`SET NX`) prevents duplicate scheduling chains. If two reconciliation runs complete simultaneously (e.g., one scheduled + one triggered by WS reconnect that happened to run with `bot_id = nil`), only one will successfully schedule the next run. The lock TTL of 30s auto-expires if the chain dies, allowing a fresh start (e.g., from the initial kickoff in `Grid::Initializer`).

**Kickoff:** The reconciliation chain is started by `Grid::Initializer` after the first bot transitions to `running`. If no chain is running (the Redis lock is absent), the initializer enqueues the first `GridReconciliationWorker.perform_async`.

---

## 10. Testing Guidance

Components that need test coverage (tests written by developers, not the architect):

### Grid::Initializer
- Happy path: pending -> running with correct orders placed
- Partial batch failure: bot still transitions, gaps logged
- Instrument info fetch failure: stays pending
- Market buy for base asset
- Neutral zone levels skipped correctly
- Order link ID format verification

### OrderFillWorker
- Buy fill -> sell counter-order placed at correct level and price, paired_order_id set
- Sell fill -> buy counter-order placed, trade recorded with correct paired buy, cycle_count incremented
- Idempotency: duplicate fill message processes only once
- Optimistic locking: concurrent fills on same level -> one wins, one retries
- Fee-adjusted net_quantity: base coin fee vs. quote coin fee
- Fee in third coin: warning logged, fee treated as zero
- Edge: fill at boundary level (no counter-order possible)
- Rapid-fill race: order not in DB but matches pattern -> re-enqueue with delay
- Rapid-fill race: max re-enqueue count exceeded -> error logged
- Partial fill detection by reconciliation (>= 95% -> cancel remainder and process)

### GridReconciliationWorker
- Missing order detected and repaired
- Orphan with our pattern: adopted (DB records created), not cancelled
- Orphan without our pattern: cancelled
- Grid gap detected and filled
- Bot status re-checked before repairs (stopped bot not touched)
- Redis hot state refreshed after reconciliation
- Pagination of open orders (>50)
- Redis mutex prevents duplicate scheduling chains
- Partial fill > 10 min at >= 95%: cancel remainder and process as fill

### Bybit::WebsocketListener
- Auth message format
- Subscription message format
- Fill event dispatches to Sidekiq
- Read timeout triggers reconnection
- Reconnection triggers reconciliation
- Maintenance detection pauses bots (find_each, not update_all)
- Maintenance resume re-enables bots and triggers reconciliation
- Graceful shutdown (SIGTERM/SIGINT)

### BalanceSnapshotWorker
- Correct base_held calculation
- Correct unrealized PnL
- One failing bot doesn't block others

### Grid::RedisState
- Seed populates all keys
- Update on fill changes correct keys
- Cleanup removes all keys for a bot

---

## 11. File Summary

### New Files (Phase 2)

| File | Type | Description |
|------|------|-------------|
| `app/services/grid/initializer.rb` | Service | Bot initialization and grid placement |
| `app/services/grid/redis_state.rb` | Service | Redis hot state management |
| `app/services/bybit/websocket_listener.rb` | Service | WebSocket connection and message dispatch |
| `app/workers/order_fill_worker.rb` | Worker | Fill processing and counter-order loop |
| `app/workers/grid_reconciliation_worker.rb` | Worker | Gap detection and repair |
| `app/workers/balance_snapshot_worker.rb` | Worker | Portfolio snapshot creation |
| `bin/ws_listener` | Script | WebSocket listener entry point |

### Modified Files (Phase 2)

| File | Change |
|------|--------|
| `app/services/exchange/adapter.rb` | Add `get_order_history` method |
| `app/services/bybit/rest_client.rb` | Implement `get_order_history`, update BUCKET_MAP |
| `app/models/bot.rb` | No code changes needed (new column auto-available) |
| `app/models/order.rb` | Add `belongs_to :paired_order, class_name: "Order", optional: true` |
| `config/sidekiq.yml` | Add balance_snapshot cron schedule (reconciliation is self-scheduled) |

### New Migrations (Phase 2)

| Migration | Change |
|-----------|--------|
| `add_quantity_per_level_to_bots` | Add `quantity_per_level` decimal column |
| `add_paired_order_id_to_orders` | Add `paired_order_id` reference column with FK to orders |

---

## 12. Architectural Decisions

### AD-1: WebSocket Listener as Standalone Process

**Decision:** Run the WebSocket listener as a separate OS process, not a Sidekiq worker or thread within Rails.

**Rationale:** WebSocket connections are long-lived and stateful. Sidekiq is designed for short-lived, stateless jobs. A standalone process gives clean lifecycle management (SIGTERM, reconnection), process isolation, and simple systemd integration.

### AD-2: Optimistic Locking Over Pessimistic Locking

**Decision:** Use Rails optimistic locking (`lock_version`) on `grid_levels` rather than `SELECT FOR UPDATE`.

**Rationale:** Contention on the same grid_level from duplicate WS messages is rare (but possible). Optimistic locking avoids holding database locks during the exchange API call (which could take seconds). The retry cost is negligible compared to holding a row lock for the duration of a REST API round-trip.

### AD-3: Reconciliation Self-Scheduling with Redis Mutex

**Decision:** Use `perform_in(15)` self-scheduling with a Redis `SET NX` mutex to prevent duplicate chains, rather than requiring sub-minute cron.

**Rationale:** Standard Sidekiq cron only supports minute-level granularity. Self-scheduling gives us 15-second intervals without additional gem dependencies. The Redis mutex ensures exactly one scheduling chain runs at a time, even if multiple reconciliation runs complete simultaneously. The lock auto-expires (30s TTL) to recover if the chain dies.

### AD-4: Store quantity_per_level on Bot Record

**Decision:** Add `quantity_per_level` column to the `bots` table, set during initialization.

**Rationale:** Counter-orders need to know the per-level buy quantity. Recalculating from investment/levels/price is fragile (price changes, levels may be different). Storing it once during init ensures consistency throughout the bot's lifetime.

### AD-5: Redis Stream for Fill Audit Trail

**Decision:** Publish fill events to a Redis stream (capped at 10K entries) in addition to Sidekiq enqueue.

**Rationale:** Provides a lightweight audit trail for debugging without querying PostgreSQL. The stream is append-only and auto-trimmed, so no maintenance burden. Not used for processing — purely observability.

### AD-6: Paired Order ID for Trade Recording

**Decision:** Add `paired_order_id` column to orders table, linking counter-orders to their triggering order.

**Rationale:** A buy fills at level N, and the counter-sell is placed at level N+1. When the sell fills and we need to record the trade, we must find the originating buy. Without a direct link, we'd search for "most recent filled buy" — which fails when the buy and sell are on different grid levels. The `paired_order_id` gives an explicit, unambiguous link.

### AD-7: Reconciliation Adopts Orphans (Not Cancel)

**Decision:** When reconciliation finds orders on the exchange that have no DB record but match our `ORDER_LINK_ID_PATTERN`, it adopts them (creates DB records) rather than cancelling them.

**Rationale:** Orphans with our order link ID pattern exist because the API call to place a counter-order succeeded but the DB commit failed. Cancelling them would destroy a valid order and leave a grid gap. Adopting them preserves the order and repairs the DB to match exchange reality.

### AD-8: Rapid-Fill Re-enqueue Strategy

**Decision:** When `OrderFillWorker` receives a fill for an order not yet in the DB (but with a recognizable order link ID), it re-enqueues itself with a 5-second delay instead of discarding.

**Rationale:** In fast markets, a counter-order can be placed on the exchange and fill before the DB write from the original fill worker completes. Without re-enqueue, this fill is silently lost. The 5-second delay gives the original worker time to commit. Max 3 re-enqueues prevents infinite loops.

### AD-9: Explicit Redis Instances (No Redis.current)

**Decision:** All components instantiate explicit Redis connections via `Redis.new(url: ENV.fetch("REDIS_URL", ...))` or accept an injected instance. No use of `Redis.current`.

**Rationale:** `Redis.current` is deprecated in the `redis` gem v5+ and creates hidden global state that complicates testing and connection management. Explicit instances are injectable for tests and make connection lifecycle clear.
