# Phase 2: The Execution Loop — BRIEF

## Problem to Solve

Phase 1 delivered a working foundation: the Bybit REST client, DB schema, and grid calculator are all operational on testnet. However, the bot cannot yet trade autonomously. There is no mechanism to initialize a grid on the exchange, no listener to detect order fills in real time, and no logic to place counter-orders when a fill occurs. Until these are in place, the bot requires manual intervention for every order and cannot generate profit. The target outcome for this phase is 100 autonomous trades on testnet with zero manual intervention after startup.

---

## Goals and Scope

**In scope:**
- Bot initialization service: fetch instrument info, calculate grid, batch-place orders on Bybit
- WebSocket listener process: connect to Bybit private stream, detect fills in real time
- Order fill worker: process fills, place counter-orders, record trades, track profit
- Reconciliation worker: detect and repair grid gaps every 15 seconds
- Redis hot state: maintain fast-read cache of bot status, price, levels, stats
- Balance snapshot worker: capture portfolio value snapshots every 5 minutes

**Out of scope:**
- React frontend / UI (Phase 3)
- Stop-loss, take-profit, trailing grid (Phase 4)
- DCP (dead man's switch) safety (Phase 4)
- Rails API endpoints (Phase 3)
- All interaction is via Rails console only

---

## User Personas

**Developer / Bot Operator** — starts and monitors the bot via Rails console. No UI. Expects the bot to run autonomously once initialized, completing buy->sell->buy loops without manual intervention.

---

## Feature Description

### 2.1 Bot Initialization Service

`app/services/grid/initializer.rb`

1. Fetch instrument info from Bybit (`tick_size`, `min_order_amt`, `min_order_qty`, `base_precision`) — store on bot record
2. Fetch current market price
3. Calculate grid levels via `Grid::Calculator` (with neutral zone skipping)
4. Determine buy levels (below current price) and sell levels (above current price)
5. Calculate required base asset for sell orders; place initial market buy if base balance is insufficient
6. Batch-place limit orders via `POST /v5/order/create-batch` (max 20 per batch, throttled through rate limiter)
7. Persist `grid_levels` and `orders` records to DB
8. Update bot status to `running`

**Order Link ID format:** `g{bot_id}L{level_index}{B|S}{cycle_count}` (max 36 chars). The `cycle_count` from `grid_levels` ensures uniqueness across repeated buy/sell cycles at the same level. Example: `g12L25B3` = bot 12, level 25, buy, 3rd cycle.

### 2.2 WebSocket Listener Process

**Separate OS process** (not a Sidekiq worker). Launched via `bin/ws_listener`.

`app/services/bybit/websocket_listener.rb`:

- Uses `async-websocket` gem (fiber-based, no EventMachine)
- Connects to private WebSocket: `wss://stream-testnet.bybit.com/v5/private`
- Authenticates with HMAC: `HMAC_SHA256(secret, "GET/realtime" + expires)`
- Subscribes to: `order.spot`, `execution.spot`, `wallet`
- On `order.spot` message with `orderStatus == "Filled"`:
  - Publish fill data to Redis stream `grid:fills`
  - Enqueue `OrderFillWorker.perform_async(order_data)`
- Heartbeat: `{"op":"ping"}` every 20 seconds via async timer task
- Reconnection: exponential backoff (1s, 2s, 4s, 8s, max 30s), re-authenticate, re-subscribe
- On reconnect: trigger `GridReconciliationWorker` for all running bots
- Graceful shutdown: handle SIGTERM/SIGINT — cancel all async tasks, close WebSocket cleanly
- Maintenance detection: on HTTP 503 or WS close code 1001, set all bots to `paused`, retry every 30s

### 2.3 Order Fill Processing

`app/workers/order_fill_worker.rb` (Sidekiq, `critical` queue)

**Concurrency control:** Optimistic locking on `grid_levels.lock_version`. If two workers race on the same level, the loser gets `ActiveRecord::StaleObjectError` and retries. Prevents duplicate counter-orders from WebSocket message deduplication failures.

**Processing steps:**
1. Find order by `exchange_order_id` or `order_link_id`
2. Idempotency check: if order already marked `filled`, skip (handles duplicate WS messages)
3. Wrap in transaction with optimistic lock on grid_level
4. Update order: `status=filled`, `filled_quantity`, `net_quantity`, `avg_fill_price`, `fee`, `fee_coin`, `filled_at`
5. Calculate `net_quantity`: if `fee_coin` == base coin, `net_quantity = filled_quantity - fee`; otherwise `net_quantity = filled_quantity`
6. Update grid_level: `status=filled`

**The Core Loop:**

- Filled **BUY** at level N:
  - Place **SELL** limit order at level N+1 price
  - Sell quantity = `net_quantity` from the buy (fee-adjusted to prevent base asset leakage)
  - Create order record, update grid_level with new order ID and `expected_side=sell`

- Filled **SELL** at level N:
  - Place **BUY** limit order at level N-1 price
  - Create order record, update grid_level with new order ID and `expected_side=buy`
  - Increment `grid_level.cycle_count`
  - Record a Trade (links buy + sell orders, calculates profit)

**Profit calculation per trade:**
```
quantity      = sell_order.net_quantity
gross_profit  = (sell_price - buy_price) * quantity
total_fees    = buy_fee_in_quote + sell_fee_in_quote  (normalize to quote currency)
net_profit    = gross_profit - total_fees
```

### 2.4 Reconciliation Worker

`app/workers/grid_reconciliation_worker.rb` (Sidekiq-cron, every 15 seconds)

For each running bot:
1. Fetch all open orders from exchange (`GET /v5/order/realtime`, paginated, limit 50)
2. Compare against local DB state
3. **Missing on exchange but active locally:** Fill/cancel missed by WS — query order history, process fill
4. **On exchange but not in DB:** Orphaned order — cancel it
5. **Grid level with no active order (gap):** Determine correct side, place new order
6. Log all discrepancies for monitoring

Runs every 15 seconds to balance responsiveness (~4 API req/cycle per bot) against the 10 req/s rate limit.

### 2.5 Redis Hot State

Maintained for fast reads (future dashboard, monitoring).

```
grid:{bot_id}:status         -> "running"
grid:{bot_id}:current_price  -> "2543.50"
grid:{bot_id}:levels         -> Hash { "0" => "{side:buy,status:active,order_id:...}", ... }
grid:{bot_id}:stats          -> Hash { realized_profit, trade_count, uptime_seconds }
```

Updated on every fill event. Keys deleted (no TTL) when bot stops.

### 2.6 Balance Snapshot Worker

`app/workers/balance_snapshot_worker.rb` (Sidekiq-cron, every 5 minutes)

For each running bot:
1. Fetch current price
2. Calculate base balance held (sum of filled buys minus sold quantities)
3. Calculate quote balance
4. `total_value = quote_balance + (base_balance * current_price)`
5. `realized_profit = SUM(trades.net_profit)`
6. `unrealized_pnl = (current_price - avg_buy_price) * base_balance`
7. Save `BalanceSnapshot` record with `granularity='fine'`

Note: This worker was originally scoped to Phase 3 in the implementation plan but is included here because balance snapshots are needed for monitoring bot health during Phase 2 testnet validation.

---

## Acceptance Criteria

**AC-001 (P0):** `Grid::Initializer.new(bot).call` places the correct number of limit orders on Bybit testnet, creates matching `grid_levels` and `orders` records in DB, and sets `bot.status = 'running'`.

**AC-002 (P0):** WebSocket listener connects to Bybit testnet private stream, authenticates successfully, and receives `order.spot` events.

**AC-003 (P0):** When a buy order fills on the exchange, `OrderFillWorker` places a sell order one level above within a reasonable latency window and creates an `Order` record in DB.

**AC-004 (P0):** When a sell order fills, `OrderFillWorker` places a buy order one level below, increments `grid_level.cycle_count`, and creates a `Trade` record with correct `net_profit`.

**AC-005 (P0):** `net_quantity` is calculated correctly when `fee_coin` equals the base coin — sell quantity does not exceed actual holdings.

**AC-006 (P0):** Two concurrent `OrderFillWorker` instances processing the same grid level result in exactly one counter-order placed (optimistic locking prevents the duplicate).

**AC-007 (P0):** Milestone — bot completes 100 autonomous trades on ETHUSDT testnet with 10 grid levels, with no manual intervention after initialization.

**AC-008 (P0):** `GridReconciliationWorker` detects a missing order (simulated by killing the WS listener temporarily) and re-places it within one reconciliation cycle (≤15 seconds).

**AC-009 (P1):** WebSocket listener reconnects automatically after a connection drop, with exponential backoff, and triggers reconciliation on reconnect.

**AC-010 (P1):** On WS close code 1001 or HTTP 503, all running bots are set to `paused` status and resume automatically when connectivity is restored.

**AC-011 (P1):** Redis hot state keys (`grid:{bot_id}:status`, `:current_price`, `:levels`, `:stats`) are populated and updated on each fill event.

**AC-012 (P1):** `BalanceSnapshotWorker` creates `fine` granularity snapshots every 5 minutes for each running bot with correct `total_value_quote`, `realized_profit`, and `unrealized_pnl`.

**AC-013 (P1):** `bin/ws_listener` handles SIGTERM gracefully — closes WebSocket cleanly without leaving orphaned async tasks.

**AC-014 (P2):** Duplicate WebSocket fill messages for the same order (simulated) result in exactly one DB update and one counter-order (idempotency check passes).
