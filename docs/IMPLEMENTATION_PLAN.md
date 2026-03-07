# Volatility Harvester - Implementation Plan

## Project Summary

A grid trading bot for Bybit (Spot), built with Ruby on Rails + React + PostgreSQL + Redis + Sidekiq. The bot places a net of limit buy/sell orders within a price range and profits from sideways market oscillations.

---

## Phase 1: Foundation (The Skeleton)

**Goal:** Rails app scaffolding, Bybit API client, basic grid math. Testnet connectivity.

### 1.1 Project Bootstrap

- `rails new grid_bot --api --database=postgresql --skip-action-mailer --skip-action-mailbox --skip-action-text --skip-active-storage`
- Add core gems: `sidekiq`, `redis`, `faraday`, `faraday-retry`, `async-websocket`, `lockbox`, `dotenv-rails`, `oj`
- Frontend: Create React app using vite in `frontends/app/` with Material-UI v6, React Query, React Router
- Configure PostgreSQL, Redis, Sidekiq
- Set up `.env` with `BYBIT_BASE_URL`, `BYBIT_WS_PUBLIC`, `BYBIT_WS_PRIVATE`, `BYBIT_API_KEY`, `BYBIT_API_SECRET` (encrypted with Lockbox)
- Default to testnet URLs: `https://api-testnet.bybit.com`, `wss://stream-testnet.bybit.com/v5/public/spot`, `wss://stream-testnet.bybit.com/v5/private`

### 1.2 Bybit API Client (Custom, No Gem)

Build a thin `Bybit::Client` using Faraday. No maintained Ruby gem exists for Bybit V5. Design the client behind an `Exchange::Adapter` interface so Binance (or others) can be added later without rewriting grid logic.

**Authentication module** (`app/services/bybit/auth.rb`):
- HMAC-SHA256 signing via `OpenSSL::HMAC.hexdigest`
- Signature: `HMAC_SHA256(secret, timestamp + apiKey + recvWindow + params)`
- Headers: `X-BAPI-API-KEY`, `X-BAPI-TIMESTAMP`, `X-BAPI-SIGN`, `X-BAPI-RECV-WINDOW`

**REST methods needed** (`app/services/bybit/rest_client.rb`):

| Method | Endpoint | Auth | Purpose |
|--------|----------|------|---------|
| `get_wallet_balance` | `GET /v5/account/wallet-balance` | Yes | Read USDT/base balances |
| `get_instruments_info` | `GET /v5/market/instruments-info` | No | Fetch tickSize, minOrderAmt, minOrderQty, basePrecision |
| `get_tickers` | `GET /v5/market/tickers` | No | Current price, bid/ask |
| `place_order` | `POST /v5/order/create` | Yes | Place single limit order |
| `batch_place_orders` | `POST /v5/order/create-batch` | Yes | Grid initialization (up to 20 per batch) |
| `cancel_order` | `POST /v5/order/cancel` | Yes | Cancel single order |
| `cancel_all_orders` | `POST /v5/order/cancel-all` | Yes | Bot shutdown / stop-loss |
| `get_open_orders` | `GET /v5/order/realtime` | Yes | Reconciliation, paginated (limit 50) |
| `set_dcp` | `POST /v5/order/disconnected-cancel-all` | Yes | Dead man's switch safety |

**Rate limiter** (`app/services/bybit/rate_limiter.rb`):
- Redis-backed token bucket
- Track remaining requests via response headers: `X-Bapi-Limit-Status`, `X-Bapi-Limit-Reset-Timestamp`
- Limits: 20 req/s for order create/cancel, 10 req/s for batch/query
- IP limit: 600 per 5-second window

### 1.3 Database Schema (Core Models)

```ruby
# db/migrate/001_create_exchange_accounts.rb
create_table :exchange_accounts do |t|
  t.string :name, null: false
  t.string :exchange, null: false, default: 'bybit' # bybit (extensible later)
  t.text :api_key_ciphertext, null: false      # Lockbox encrypted
  t.text :api_secret_ciphertext, null: false   # Lockbox encrypted
  t.string :environment, default: 'testnet'    # testnet | mainnet
  t.timestamps
  t.index [:exchange, :environment], unique: true  # prevent duplicate accounts
end

# db/migrate/002_create_bots.rb
create_table :bots do |t|
  t.references :exchange_account, null: false, foreign_key: true
  t.string :pair, null: false                  # e.g., "ETHUSDT"
  t.string :base_coin, null: false             # e.g., "ETH"
  t.string :quote_coin, null: false            # e.g., "USDT"
  t.decimal :lower_price, precision: 20, scale: 8, null: false
  t.decimal :upper_price, precision: 20, scale: 8, null: false
  t.integer :grid_count, null: false
  t.string :spacing_type, default: 'arithmetic' # arithmetic | geometric
  t.decimal :investment_amount, precision: 20, scale: 8, null: false
  t.decimal :tick_size, precision: 20, scale: 12
  t.decimal :min_order_amt, precision: 20, scale: 8
  t.decimal :min_order_qty, precision: 20, scale: 8  # minimum base quantity
  t.integer :base_precision
  t.integer :quote_precision
  t.string :status, default: 'pending'         # pending | initializing | running | paused | stopped | error
  t.string :stop_reason                        # user | stop_loss | take_profit | error | maintenance
  t.decimal :stop_loss_price, precision: 20, scale: 8
  t.decimal :take_profit_price, precision: 20, scale: 8
  t.boolean :trailing_up_enabled, default: false
  t.timestamps
end

# db/migrate/003_create_grid_levels.rb
create_table :grid_levels do |t|
  t.references :bot, null: false, foreign_key: true
  t.integer :level_index, null: false
  t.decimal :price, precision: 20, scale: 8, null: false
  t.string :expected_side, null: false          # buy | sell (what order SHOULD be here)
  t.string :status, default: 'pending'          # pending | active | filled
  t.string :current_order_id                    # Bybit orderId
  t.string :current_order_link_id               # our client order ID
  t.integer :cycle_count, default: 0            # completed buy+sell round-trips at this level
  t.integer :lock_version, default: 0           # optimistic locking for concurrency control
  t.timestamps
  t.index [:bot_id, :level_index], unique: true
end

# db/migrate/004_create_orders.rb
create_table :orders do |t|
  t.references :bot, null: false, foreign_key: true
  t.references :grid_level, null: false, foreign_key: true
  t.string :exchange_order_id                   # Bybit orderId
  t.string :order_link_id, null: false          # client order ID (for idempotency)
  t.string :side, null: false                   # buy | sell
  t.decimal :price, precision: 20, scale: 8, null: false
  t.decimal :quantity, precision: 20, scale: 8, null: false       # requested quantity
  t.decimal :filled_quantity, precision: 20, scale: 8, default: 0 # gross filled (before fee)
  t.decimal :net_quantity, precision: 20, scale: 8                # actual received (filled - fee when fee in base)
  t.decimal :avg_fill_price, precision: 20, scale: 8
  t.decimal :fee, precision: 20, scale: 10, default: 0
  t.string :fee_coin                            # which coin the fee was charged in (ETH or USDT)
  t.string :status, default: 'pending'          # pending | open | partially_filled | filled | cancelled
  t.datetime :placed_at
  t.datetime :filled_at
  t.timestamps
  t.index :order_link_id, unique: true
  t.index :exchange_order_id
  t.index [:grid_level_id, :status]             # fast lookup: active order per level
end

# db/migrate/005_create_trades.rb (realized profit per grid level cycle)
# A trade is recorded when a sell completes a buy+sell cycle at a grid level.
# Links to specific buy/sell orders. Profit tracked per-level via grid_level.cycle_count.
create_table :trades do |t|
  t.references :bot, null: false, foreign_key: true
  t.references :grid_level, null: false, foreign_key: true
  t.references :buy_order, null: false, foreign_key: { to_table: :orders }
  t.references :sell_order, null: false, foreign_key: { to_table: :orders }
  t.decimal :buy_price, precision: 20, scale: 8, null: false
  t.decimal :sell_price, precision: 20, scale: 8, null: false
  t.decimal :quantity, precision: 20, scale: 8, null: false  # net quantity (fee-adjusted)
  t.decimal :gross_profit, precision: 20, scale: 8, null: false
  t.decimal :total_fees, precision: 20, scale: 10, null: false
  t.decimal :net_profit, precision: 20, scale: 8, null: false
  t.datetime :completed_at, null: false
  t.timestamps
  t.index [:bot_id, :completed_at]
end

# db/migrate/006_create_balance_snapshots.rb
create_table :balance_snapshots do |t|
  t.references :bot, null: false, foreign_key: true
  t.decimal :base_balance, precision: 20, scale: 8
  t.decimal :quote_balance, precision: 20, scale: 8
  t.decimal :total_value_quote, precision: 20, scale: 8
  t.decimal :current_price, precision: 20, scale: 8
  t.decimal :realized_profit, precision: 20, scale: 8
  t.decimal :unrealized_pnl, precision: 20, scale: 8
  t.string :granularity, default: 'fine'       # fine (5min) | hourly | daily
  t.datetime :snapshot_at, null: false
  t.timestamps
  t.index [:bot_id, :snapshot_at]
  t.index [:bot_id, :granularity, :snapshot_at] # for retention policy queries
end
```

**Snapshot retention policy** (`SnapshotRetentionWorker`, Sidekiq-cron daily at 03:00 UTC):
- Keep `fine` (5-min) snapshots for 7 days
- Aggregate to `hourly` after 7 days (keep one per hour, closest to :00)
- Aggregate to `daily` after 30 days (keep one per day, end-of-day snapshot)

### 1.4 Grid Math Service

`app/services/grid/calculator.rb`:

**Arithmetic spacing:**
```
step = (upper - lower) / grid_count
level[i] = lower + (i * step)     # i = 0..grid_count
```

**Geometric spacing:**
```
ratio = (upper / lower) ^ (1.0 / grid_count)
level[i] = lower * (ratio ^ i)    # i = 0..grid_count
```

**Key calculations:**
- `quantity_per_grid` = investment_amount / (grid_count + 1) / current_price (simplified; exact formula accounts for buy vs sell sides)
- Round prices to `tick_size`, quantities to `base_precision`
- Validate BOTH: `quantity_per_grid * price >= min_order_amt` AND `quantity_per_grid >= min_order_qty` for each level
- Determine which levels are BUY (below current price) and SELL (above current price)
- **Neutral zone:** If current price is within 0.1% of a grid level, skip that level (no order placed). This prevents immediate taker fills during initialization that would corrupt the grid state.

### 1.5 Phase 1 Milestone

- [ ] `rails console`: `Bybit::RestClient.new.get_tickers(symbol: 'ETHUSDT')` returns live price from testnet
- [ ] `Bybit::RestClient.new.get_wallet_balance` returns test USDT balance
- [ ] `Grid::Calculator.new(lower: 2000, upper: 3000, count: 50, spacing: :arithmetic).levels` returns 51 price levels
- [ ] Place and cancel a single limit order on testnet

---

## Phase 2: The Execution Loop

**Goal:** Place grid orders, listen for fills via WebSocket, execute the buy->sell / sell->buy loop.

### 2.1 Bot Initialization Service

`app/services/grid/initializer.rb`:

1. Fetch instrument info (tick_size, min_order_amt, min_order_qty, base_precision) -> store on bot record
2. Fetch current market price
3. Calculate grid levels (with neutral zone handling)
4. Determine buy levels (below price) and sell levels (above price)
5. Calculate required base asset for sell orders
6. Place initial market buy if insufficient base balance
7. Batch-place limit orders via `POST /v5/order/create-batch` (max 20 per batch, throttled)
8. Create `grid_levels` and `orders` records in DB
9. Update bot status to `running`

**Order Link ID format:** `g{bot_id}L{level_index}{B|S}{cycle_count}` (max 36 chars, unique per order). The `cycle_count` from `grid_levels` ensures uniqueness across repeated buy/sell cycles at the same level. Example: `g12L25B3` = bot 12, level 25, buy, 3rd cycle.

### 2.2 WebSocket Listener Process

**Separate process** (NOT a Sidekiq worker). Run via `bin/ws_listener`.

`app/services/bybit/websocket_listener.rb`:

- Uses `async-websocket` gem (built on `async` — actively maintained, fiber-based concurrency, no EventMachine dependency)
- Connects to private WebSocket: `wss://stream-testnet.bybit.com/v5/private`
- Authenticates with HMAC: `HMAC_SHA256(secret, "GET/realtime" + expires)`
- Subscribes to: `order.spot`, `execution.spot`, `wallet`
- On `order.spot` message with `orderStatus == "Filled"`:
  - Publish to Redis stream: `grid:fills` with order data
  - Enqueue `OrderFillWorker.perform_async(order_data)`
- Heartbeat: send `{"op":"ping"}` every 20 seconds via `async` timer task
- Reconnection: exponential backoff (1s, 2s, 4s, 8s, max 30s), re-auth, re-subscribe
- On reconnect: trigger `GridReconciliationWorker` for all running bots
- **Graceful shutdown:** Handle SIGTERM/SIGINT — cancel all pending async tasks, close WebSocket cleanly
- **Maintenance detection:** On HTTP 503 or WS close code 1001, set all bots to `paused` status, retry connection every 30s until exchange is back

### 2.3 Order Fill Processing

`app/workers/order_fill_worker.rb` (Sidekiq, `critical` queue):

**Concurrency control:** Uses optimistic locking on `grid_levels.lock_version`. If two workers race on the same level, the second gets `ActiveRecord::StaleObjectError` and retries. This prevents duplicate counter-orders from WebSocket message dedup failures.

1. Find order by `exchange_order_id` or `order_link_id`
2. **Idempotency check:** if order already marked `filled`, skip (handles duplicate WS messages)
3. Wrap in transaction with optimistic lock on grid_level:
4. Update order: status=filled, filled_quantity, net_quantity, avg_fill_price, fee, fee_coin, filled_at
5. **Calculate net_quantity:** If `fee_coin` == base coin (e.g., ETH on a buy), then `net_quantity = filled_quantity - fee`. Otherwise `net_quantity = filled_quantity`. This accounts for Bybit deducting fees from the received asset.
6. Update grid_level: status=filled

**The Core Loop:**
- If filled order was a **BUY** at level N:
  - Place a **SELL** limit order one grid step above (at level N+1 price)
  - Sell quantity = `net_quantity` from the buy (fee-adjusted to prevent gradual base asset leakage)
  - Create new order record, update grid_level with new order ID, expected_side becomes `sell`

- If filled order was a **SELL** at level N:
  - Place a **BUY** limit order one grid step below (at level N-1 price)
  - Create new order record, update grid_level with new order ID, expected_side becomes `buy`
  - Increment `grid_level.cycle_count`
  - **Record a Trade:** Link the buy and sell orders for this cycle, calculate profit

**Profit calculation per trade:**
```
quantity = sell_order.net_quantity  (fee-adjusted)
gross_profit = (sell_price - buy_price) * quantity
total_fees = buy_fee_in_quote + sell_fee_in_quote  (normalize all fees to quote currency)
net_profit = gross_profit - total_fees
```

### 2.4 Reconciliation Worker

`app/workers/grid_reconciliation_worker.rb` (Sidekiq-cron, every 15 seconds):

1. For each running bot:
2. Fetch all open orders from exchange (`GET /v5/order/realtime`, paginate)
3. Compare against local DB state
4. **Missing on exchange but active locally:** Order was filled/cancelled without WS notification -> query order history, process fill
5. **On exchange but not in DB:** Orphaned order -> cancel it
6. **Gap detection:** Grid levels with no active order -> determine correct side, place order
7. Log any discrepancies for monitoring

**Why 15 seconds:** A 60-second gap is too slow — in volatile markets, price can move through multiple grid levels in under a minute. 15 seconds balances responsiveness with API rate budget (costs ~4 req/cycle per bot within the 10 req/s limit).

### 2.5 Redis Hot State

Store in Redis for fast reads (dashboard, monitoring):
```
grid:{bot_id}:status        -> "running"
grid:{bot_id}:current_price -> "2543.50"
grid:{bot_id}:levels        -> Hash { "0" => "{side:buy,status:active,order_id:...}", ... }
grid:{bot_id}:stats         -> Hash { realized_profit, trade_count, uptime_seconds }
```

Update on every fill event. TTL: none (deleted when bot stops).

### 2.6 Phase 2 Milestone

- [ ] Start a bot on ETHUSDT testnet with 10 grid levels
- [ ] WebSocket listener receives fill notifications
- [ ] Bot completes the buy->sell->buy loop autonomously
- [ ] **Milestone: 100 autonomous trades on testnet** (per PRD)
- [ ] Reconciliation worker detects and fixes missing orders after simulated WS disconnect

---

## Phase 3: The Dashboard

**Goal:** React frontend to create bots, monitor performance, visualize the grid.

### 3.1 Rails API Endpoints

```
POST   /api/v1/bots              # Create bot (starts initialization)
GET    /api/v1/bots              # List all bots with summary stats
GET    /api/v1/bots/:id          # Bot detail + grid levels + recent trades
PATCH  /api/v1/bots/:id          # Update (stop, start, modify stop-loss)
DELETE /api/v1/bots/:id          # Stop and remove bot (cancel all orders)
GET    /api/v1/bots/:id/trades   # Paginated trade history
GET    /api/v1/bots/:id/chart    # Balance snapshots for charting
GET    /api/v1/bots/:id/grid     # Grid levels with current order status
GET    /api/v1/exchange/pairs    # Available trading pairs
GET    /api/v1/exchange/balance  # Current account balance
```

### 3.2 Real-Time Updates (ActionCable)

`BotChannel`: Streams per-bot updates (fill events, price changes, status changes).
- Backend publishes to ActionCable from `OrderFillWorker` and price stream
- Frontend subscribes via WebSocket for live dashboard updates

### 3.3 Frontend Pages

**Create Bot Wizard** (`/bots/new`):
1. Step 1: Select pair (searchable dropdown from `/api/v1/exchange/pairs`)
2. Step 2: Set parameters (lower/upper price, grid count, spacing type)
3. Step 3: Investment slider (% of available USDT) + summary preview (expected profit per grid, fee impact)

**Bot Dashboard** (`/bots`):
- Cards per bot showing: pair, status, range visualizer (progress bar: low-current-high), realized profit, daily APR, trade count, uptime

**Bot Detail** (`/bots/:id`):
- Grid visualization: vertical price axis with buy/sell levels, current price marker
- Realized Profit (cash) vs Unrealized PnL (asset value change) - shown separately (PRD requirement)
- Line chart: total balance over time (from balance_snapshots)
- Bar chart: daily realized profit
- Trade history table (paginated)

### 3.4 Balance Snapshot Worker

`app/workers/balance_snapshot_worker.rb` (Sidekiq-cron, every 5 minutes):

For each running bot:
1. Fetch current price
2. Calculate base_balance (sum of held base from filled buys minus sold)
3. Calculate quote_balance
4. total_value = quote_balance + (base_balance * current_price)
5. realized_profit = sum of trades.net_profit
6. unrealized_pnl = (current_price - avg_buy_price) * base_balance
7. Save snapshot

### 3.5 Phase 3 Milestone

- [ ] User can create a bot in 3 clicks (per PRD success criteria)
- [ ] Dashboard shows live Realized Profit matching exchange history
- [ ] Grid visualization updates in real-time via ActionCable
- [ ] Daily profit bar chart renders correctly

---

## Phase 4: Safety & Production

**Goal:** Stop-loss, trailing grid, production deployment with real capital.

### 4.1 Risk Management Module

`app/services/grid/risk_manager.rb`:

**Stop Loss** (checked on every price update):
- If `current_price <= bot.stop_loss_price`:
  1. Cancel all open orders (`POST /v5/order/cancel-all`)
  2. Market-sell all base asset
  3. Set bot status to `stopped`, stop_reason to `stop_loss`
  4. Record final P&L

**Take Profit:**
- If `current_price >= bot.take_profit_price`:
  1. Cancel all open orders
  2. Market-sell all base asset
  3. Set bot status to `stopped`, stop_reason to `take_profit`
  4. Record final P&L

**Trailing Grid** (`app/services/grid/trailing_manager.rb`):
- Trigger: price fills the highest sell order (top of grid)
- Action: cancel lowest buy order, shift grid range up by one step
- Place new sell order at new top level
- Update bot.lower_price and bot.upper_price
- Limit: configurable max trail distance from original range
- **Important caveat:** Trailing UP means the bot sold all base at lower prices and re-buys at higher prices. This is a "keep the bot alive" mechanism, NOT a profit strategy. The dashboard should clearly communicate this to the user.

### 4.2 DCP Safety (Dead Man's Switch)

On bot start:
1. Call `POST /v5/order/disconnected-cancel-all` with `timeWindow: 40`
2. Subscribe to `dcp` topic on private WebSocket
3. If WebSocket disconnects for >40s, Bybit auto-cancels all orders
4. Prevents runaway exposure if the bot process dies

### 4.3 Production Hardening

- **API key encryption:** Lockbox with Rails credentials master key
- **IP whitelisting:** Static server IP, configure on Bybit API key settings
- **Permission scope:** API keys with Spot Trading only, NO Withdrawals
- **Monitoring:** Log all order placements, fills, errors. Alert on: WebSocket disconnect >10s, reconciliation discrepancy, rate limit >80% usage
- **Error recovery:** All workers are idempotent and safe to retry (Sidekiq retry with exponential backoff)
- **Process management:** systemd services for: Rails (Puma), Sidekiq, WebSocket listener

### 4.4 Phase 4 Milestone

- [ ] Stop-loss triggers correctly on testnet (price drops below threshold)
- [ ] Trailing grid follows upward price movement
- [ ] DCP cancels orders when WebSocket listener is killed
- [ ] Bot runs 24 hours without crashing or hitting rate limits (PRD success criteria)
- [ ] Deploy to mainnet with $500 capital

---

## Phase 5: Feature Specs (E2E Browser Testing)

**Goal:** Add Capybara-based browser E2E tests that exercise the full stack (Rails API + React frontend) through a real browser.

### 5.1 Infrastructure Setup

- Add gems: `capybara`, `cuprite` (headless Chrome driver, no Selenium dependency)
- Configure Capybara to drive the Vite React frontend alongside the Rails API
- Set up `spec/features/` directory with shared helpers for bot creation, fill simulation
- MockRedis + mocked exchange client (same approach as integration specs)

### 5.2 Feature Specs

**Dashboard page** (`spec/features/dashboard_spec.rb`):
- User sees bot cards with status, profit, range visualizer
- Creating a new bot via the 3-step wizard
- Bot status updates in real-time via ActionCable

**Bot Detail page** (`spec/features/bot_detail_spec.rb`):
- Grid visualization displays correct levels
- Trade history table is paginated
- Performance charts render
- Risk settings card (stop-loss, take-profit, trailing) is editable

**Create Bot Wizard** (`spec/features/create_bot_wizard_spec.rb`):
- Step 1: pair selection
- Step 2: parameter entry with validation
- Step 3: investment summary and confirmation

### 5.3 Phase 5 Milestone

- [ ] Capybara + Cuprite configured and running
- [ ] Feature specs cover all 3 frontend pages
- [ ] Specs run in CI (headless Chrome)
- [ ] All feature specs pass alongside existing 504 unit/integration specs

---

## Phase 6: Analytics & Polish (Post-MVP)

### 6.1 Analytics & Performance Monitoring

#### 6.1.1 Analytics Database Schema

```ruby
# db/migrate/007_create_daily_bot_stats.rb
# Pre-aggregated daily metrics for fast dashboard queries
create_table :daily_bot_stats do |t|
  t.references :bot, null: false, foreign_key: true
  t.date :date, null: false
  t.integer :trade_count, default: 0             # completed buy+sell cycles
  t.integer :buy_fills, default: 0               # total buy orders filled
  t.integer :sell_fills, default: 0              # total sell orders filled
  t.decimal :gross_profit, precision: 20, scale: 8, default: 0
  t.decimal :total_fees, precision: 20, scale: 10, default: 0
  t.decimal :net_profit, precision: 20, scale: 8, default: 0
  t.decimal :volume_base, precision: 20, scale: 8, default: 0   # total base traded
  t.decimal :volume_quote, precision: 20, scale: 8, default: 0  # total quote traded
  t.decimal :price_high, precision: 20, scale: 8                # highest price seen
  t.decimal :price_low, precision: 20, scale: 8                 # lowest price seen
  t.decimal :avg_profit_per_trade, precision: 20, scale: 8      # net_profit / trade_count
  t.decimal :opening_value, precision: 20, scale: 8             # total portfolio value at start of day
  t.decimal :closing_value, precision: 20, scale: 8             # total portfolio value at end of day
  t.timestamps
  t.index [:bot_id, :date], unique: true
end
```

Note: Per-level stats are already tracked via `grid_levels.cycle_count` — no separate `grid_level_stats` table needed for MVP. Can be added later if deeper per-level analytics are desired.

#### 6.1.2 Analytics Service

`app/services/analytics/bot_analytics.rb`:

**Core metrics (computed on demand or cached in Redis):**

| Metric | Formula | Description |
|--------|---------|-------------|
| **Total Realized Profit** | `SUM(trades.net_profit)` | Cash profit from completed cycles |
| **Unrealized PnL** | `(current_price - avg_buy_price) * base_held` | Paper gain/loss on held base asset |
| **Total Return %** | `(current_value - investment) / investment * 100` | Overall performance |
| **Daily APR** | `(today_net_profit / total_value) * 365 * 100` | Annualized daily yield |
| **Weekly/Monthly APR** | Same formula, averaged over 7/30 days | Smoothed yield |
| **Avg Profit per Trade** | `total_net_profit / trade_count` | Per-cycle efficiency |
| **Trade Frequency** | `trade_count / hours_running` | Trades per hour |
| **Grid Utilization** | `active_levels / total_levels * 100` | % of grid levels currently in range |
| **Fee Ratio** | `total_fees / gross_profit * 100` | What % of gross profit goes to fees |
| **Max Drawdown** | Largest peak-to-trough drop in `total_value_quote` from balance_snapshots | Worst-case dip |
| **Time in Range** | `% of snapshots where lower <= price <= upper` | How often price stays in grid |

**Derived insights:**

| Insight | Logic |
|---------|-------|
| **Grid too wide** | Grid utilization < 30% — most levels idle |
| **Grid too narrow** | Time in range < 50% — price frequently escapes |
| **Fee-inefficient** | Fee ratio > 60% — grid spacing too tight relative to fee tier |

#### 6.1.3 Daily Stats Aggregation Worker

`app/workers/daily_stats_aggregation_worker.rb` (Sidekiq-cron, runs at 00:05 UTC daily):

1. For each running bot, aggregate yesterday's trades into `daily_bot_stats`
2. Also callable on-demand for backfill: `DailyStatsAggregationWorker.perform_async(bot_id, date)`

Incremental updates: `OrderFillWorker` bumps today's `daily_bot_stats` counters in real-time (upsert on `[bot_id, date]`). The nightly job reconciles and fills any gaps.

#### 6.1.4 Analytics API Endpoints

```
GET /api/v1/bots/:id/analytics/summary       # Key metrics (profit, APR, drawdown, fee ratio)
GET /api/v1/bots/:id/analytics/daily          # Daily stats timeseries (for charts)
GET /api/v1/bots/:id/analytics/grid_heatmap   # Per-level cycle counts + profit
GET /api/v1/analytics/overview                # Aggregate stats across all bots
```

#### 6.1.5 Frontend Analytics Views

**Analytics Tab** on Bot Detail page (`/bots/:id/analytics`):

1. **KPI Cards Row**: Total Profit | Daily APR | Trade Count | Max Drawdown | Fee Ratio
   - Each card shows current value + trend arrow (up/down vs. last period)

2. **Equity Curve Chart** (line):
   - X: time, Y: total portfolio value (from balance_snapshots)
   - Overlay: drawdown periods shaded in red

3. **Daily Profit Bar Chart**:
   - X: date, Y: net profit per day (from daily_bot_stats)
   - Color: green for positive, red for negative
   - Overlay line: cumulative profit

4. **Grid Heatmap**:
   - Visual grid showing each price level
   - Color intensity = cycle_count (hotter = more active)
   - Tooltip: cycles, price, last fill time
   - Instantly shows which price zones are "money printers" vs. dead zones

5. **Comparison Table** (multi-bot view at `/analytics`):
   - All bots side by side: pair, APR, profit, drawdown, utilization, uptime
   - Sortable columns

### 6.2 Tax & Reporting Module
- CSV export of all trades with cost basis (FIFO method)
- Compliant with Polish PIT-38 tax reporting
- Fields: date, pair, side, quantity, price, fee, cost_basis, realized_gain

### 6.3 AI Parameter Suggestion
- `POST /api/v1/exchange/suggest` endpoint
- Analyze 30-day price history for a pair
- Calculate: mean, std_dev, min, max, ATR
- Suggest: lower = mean - 2*std_dev, upper = mean + 2*std_dev
- Suggest grid count based on ATR vs fee threshold

### 6.4 Multi-Bot Support
- Multiple bots on different pairs, same account
- Dashboard aggregates total P&L across all bots
- Respect 500-order limit per Bybit account (5 bots x 100 orders max)

---

## Architecture Diagram

```
                    +-------------------+
                    |   React Frontend  |
                    |  (Vite + MUI v6)  |
                    +--------+----------+
                             |
                        ActionCable (WS)
                         REST API
                             |
                    +--------v----------+
                    |   Rails API       |
                    |   (Puma)          |
                    +---+----------+----+
                        |          |
              +---------+    +-----v-------+
              |              |             |
     +--------v---+    +----v----+   +----v--------+
     | PostgreSQL  |    | Redis   |   | Sidekiq     |
     | - bots      |    | - cache |   | - fills     |
     | - orders    |    | - state |   | - reconcile |
     | - trades    |    | - queue |   | - snapshots |
     | - snapshots |    +---------+   +-------------+
     +-------------+
                         +-------------------+
                         | WS Listener       |
                         | (async-websocket) |
                         | - order.spot      |
                         | - tickers         |
                         | - wallet          |
                         +--------+----------+
                                  |
                           Bybit API v5
                         (REST + WebSocket)
```

## Key Technical Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Exchange | Bybit V5 (Spot) | PRD target. Testnet available. 0.1% fees. |
| API client | Custom (Faraday) behind `Exchange::Adapter` interface | No maintained Ruby gem. Interface allows adding Binance later. |
| WebSocket | `async-websocket` (fiber-based) | Actively maintained, no EventMachine dependency, clean shutdown. |
| Grid spacing | Arithmetic (default) | Simpler, equal dollar profit per grid. Geometric as option. |
| Order ID | `orderLinkId` with cycle counter | Idempotency, reconciliation, dedup. Unique across cycles. |
| Concurrency | Optimistic locking on grid_levels | Prevents duplicate counter-orders from WS message races. |
| State recovery | DB as truth, Redis as cache | Survives process death. |
| Fee handling | Track fee_coin, compute net_quantity | Prevents gradual base asset leakage when fees in base coin. |
| Real-time UI | ActionCable | Built into Rails, WebSocket to React. |
| Encryption | Lockbox | Standard for Rails API key encryption. |
| Time-in-force | GTC (default), PostOnly option | Guarantee maker fees with PostOnly. |

## Risk Register

| Risk | Impact | Mitigation |
|------|--------|------------|
| WebSocket disconnect misses fills | Orders stuck, no counter-order | Reconciliation every 15s + DCP safety |
| Exchange rate limit hit | Orders fail to place | Redis token bucket, response header tracking |
| Bot crash during initialization | Partial grid on exchange | Reconciliation on restart detects gaps |
| Price exits range permanently | Bot idle, capital locked | Stop-loss, trailing grid, user alerts |
| Duplicate fill messages | Double counter-orders | Optimistic locking + idempotency check on order_link_id |
| Bybit 500-order account limit | Can't run enough bots | Track total open orders, warn user |
| Partial fills | Tiny counter-orders below minimum | Threshold: wait for 95% fill or accumulate |
| Price on grid level at init | Immediate taker fill corrupts state | Neutral zone: skip level within 0.1% of current price |
| Bybit maintenance window | Bot errors, orders fail | Detect 503/WS 1001, pause bots, auto-resume after |
| Fee in base coin | Sell quantity > actual holdings | Track net_quantity (filled - fee), use for sell orders |
| Order link ID collision | Bybit rejects order | Append cycle_count to ensure uniqueness |
