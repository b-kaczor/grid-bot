# Grid Engine Area

## Overview

The grid engine is the core trading system of Volatility Harvester. It manages the lifecycle of grid trading bots: calculating price levels, placing/cancelling orders on exchanges, processing fills, and tracking profit.

## Boundaries

- **Exchange communication**: All exchange interaction goes through the `Exchange::Adapter` interface. Bybit is the first (and currently only) implementation.
- **Bot lifecycle**: `pending -> initializing -> running -> paused -> stopped`. Transitions are driven by user actions, exchange events, and risk management triggers.
- **Data flow**: Exchange WebSocket -> Redis stream -> Sidekiq worker -> PostgreSQL. Redis holds hot state for fast reads; PostgreSQL is the source of truth.

## Key Patterns

- **Service objects** in `app/services/` for all business logic. Controllers are thin.
- **Exchange::Adapter** abstract interface — all exchange clients implement it so grid logic is exchange-agnostic.
- **Optimistic locking** on `grid_levels` to prevent duplicate counter-orders from concurrent fill processing.
- **Order link ID** format `g{bot_id}L{level_index}{B|S}{cycle_count}` for idempotency and reconciliation.
- **Fee-adjusted quantities**: `net_quantity` tracks actual received amount after exchange fees. Sell orders use `net_quantity` from the preceding buy to prevent base asset leakage.

## Constraints

- Bybit rate limits: 20 req/s order create/cancel, 10 req/s batch/query, 600 req per 5s IP limit.
- Bybit account limit: 500 open orders total.
- All decimal math uses `BigDecimal` — never floats for financial calculations.
- Prices rounded to `tick_size`, quantities to `base_precision`.

## Key Files

### Services
- `app/services/exchange/adapter.rb` — Abstract interface all exchange clients must implement
- `app/services/exchange/response.rb` — Unified `Exchange::Response` struct returned by all adapter methods
- `app/services/bybit/auth.rb` — HMAC-SHA256 request signing (headers: X-BAPI-API-KEY, X-BAPI-TIMESTAMP, X-BAPI-SIGN, X-BAPI-RECV-WINDOW)
- `app/services/bybit/rest_client.rb` — Faraday-based REST client implementing `Exchange::Adapter`
- `app/services/bybit/rate_limiter.rb` — Redis-backed token bucket; 3 buckets: `order_write`, `order_batch`, `ip_global`
- `app/services/bybit/error.rb` — Custom exception hierarchy (`Bybit::Error` > Auth/RateLimit/Order/NetworkError)
- `app/services/grid/calculator.rb` — Pure arithmetic/geometric grid math; no side effects
- `app/services/grid/initializer.rb` — Bot initialization: fetch instrument info, calculate grid, batch-place orders
- `app/services/grid/redis_state.rb` — Redis hot state CRUD for bot status, levels, stats
- `app/services/bybit/websocket_listener.rb` — Private WebSocket connection, fill detection, heartbeat, reconnection (standalone process via `bin/ws_listener`)

### Models
- `app/models/exchange_account.rb` — Encrypted API credentials (Lockbox)
- `app/models/bot.rb` — Grid bot config, lifecycle status, instrument constraints
- `app/models/grid_level.rb` — Per-level state with optimistic locking (`lock_version`)
- `app/models/order.rb` — Order records with idempotency via `order_link_id`
- `app/models/trade.rb` — Completed buy+sell cycles with profit tracking
- `app/models/balance_snapshot.rb` — Portfolio value snapshots at fine/hourly/daily granularity

### Jobs / Workers
- `app/jobs/snapshot_retention_job.rb` — Sidekiq-cron daily at 03:00 UTC; downsample and prune balance snapshots
- `app/workers/order_fill_worker.rb` — Sidekiq critical queue; processes fills, places counter-orders
- `app/workers/grid_reconciliation_worker.rb` — Sidekiq-cron every 15s; detects and repairs grid gaps; self-scheduling, adopts orphaned exchange orders
- `app/workers/balance_snapshot_worker.rb` — Sidekiq-cron every 5min; captures portfolio snapshots
- `bin/ws_listener` — Standalone process entry point for Bybit::WebsocketListener

### Migrations
- `db/migrate/20260307004956_create_exchange_accounts.rb`
- `db/migrate/20260307004957_create_bots.rb`
- `db/migrate/20260307004958_create_grid_levels.rb`
- `db/migrate/20260307004959_create_orders.rb`
- `db/migrate/20260307005000_create_trades.rb`
- `db/migrate/20260307005001_create_balance_snapshots.rb`

## Directory

| Work Item | Phase | Status | Description |
|-----------|-------|--------|-------------|
| phase1-foundation | 1 | Complete | Rails skeleton, Bybit client, DB schema, grid calculator |
| phase2-execution-loop | 2 | Complete | Initializer, WebSocket listener, fill worker, reconciliation, Redis state, snapshots |

## Cross-references

- `docs/agents/patterns/adding-exchange-adapter.md` — How to add a new exchange (Binance, OKX, etc.)
- `docs/agents/patterns/bybit-auth-signing.md` — Bybit HMAC-SHA256 signing details and gotchas
- `docs/agents/patterns/websocket-reconnection.md` — Exponential backoff reconnect, heartbeat, graceful shutdown (Phase 2)
- `docs/agents/patterns/optimistic-locking-sidekiq.md` — Exactly-once counter-order placement with StaleObjectError retry (Phase 2)
- `docs/agents/patterns/self-scheduling-sidekiq-worker.md` — Sub-minute recurring workers without cron (Phase 2)

## History

- 2026-03-07: Phase 1 Foundation complete — Rails skeleton, Bybit REST client, Exchange::Adapter interface, DB schema (6 tables), Grid::Calculator (see phase1-foundation/)
- 2026-03-07: Phase 2 Execution Loop complete — Grid::Initializer, Grid::RedisState, Bybit::WebsocketListener, OrderFillWorker, GridReconciliationWorker, BalanceSnapshotWorker (see phase2-execution-loop/)
