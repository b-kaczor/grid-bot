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

### Controllers (Phase 3)
- `app/controllers/api/v1/base_controller.rb` — Error handling, pagination helpers, standard JSON envelope; all API controllers inherit from this
- `app/controllers/api/v1/bots_controller.rb` — CRUD + lifecycle actions (start, stop, pause, resume)
- `app/controllers/api/v1/bots/trades_controller.rb` — Paginated trade history for a bot
- `app/controllers/api/v1/bots/chart_controller.rb` — Balance snapshot time series for charting
- `app/controllers/api/v1/bots/grid_controller.rb` — Grid levels with current order status
- `app/controllers/api/v1/exchange/pairs_controller.rb` — Available spot trading pairs from Bybit
- `app/controllers/api/v1/exchange/balances_controller.rb` — Current account balance

### Channels (Phase 3)
- `app/channels/bot_channel.rb` — ActionCable channel; streams per-bot fill events, status changes, and price updates to subscribed clients

### Services (Phase 3)
- `app/services/grid/stopper.rb` — Graceful bot shutdown: cancels open orders on exchange, sets status to `stopped`

### Services (Phase 4)
- `app/services/grid/risk_manager.rb` — Stop-loss/take-profit: atomic running→stopping transition, emergency cancel + market sell, exchange balance lookup with DB fallback
- `app/services/grid/trailing_manager.rb` — Grid trailing: cancel lowest buy, place new top sell, two-phase negative index re-indexing, exchange ops before DB transaction

### Jobs (Phase 3)
- `app/jobs/bot_initializer_job.rb` — Sidekiq job that enqueues `Grid::Initializer`; triggered on bot create

### Frontend (Phase 3)
- `frontends/app/src/main.tsx` — Vite + React app entry point
- `frontends/app/src/App.tsx` — Root component with React Router routes
- `frontends/app/src/api/client.ts` — Axios base client
- `frontends/app/src/api/bots.ts` — Bot API calls (React Query hooks)
- `frontends/app/src/api/exchange.ts` — Exchange API calls
- `frontends/app/src/cable/consumer.ts` — ActionCable consumer singleton
- `frontends/app/src/cable/useBotChannel.ts` — Typed hook for per-bot ActionCable subscription
- `frontends/app/src/types/bot.ts` — Bot TypeScript types
- `frontends/app/src/types/trade.ts` — Trade TypeScript types
- `frontends/app/src/types/cable.ts` — `CableMessage` discriminated union
- `frontends/app/src/types/exchange.ts` — Exchange pair/balance types
- `frontends/app/src/pages/BotDashboard.tsx` — Dashboard page: grid of BotCards
- `frontends/app/src/pages/BotDetail.tsx` — Detail page: stats, grid visualization, charts, trade history
- `frontends/app/src/pages/CreateBotWizard.tsx` — 3-step bot creation wizard
- `frontends/app/src/components/BotCard.tsx` — Card with status badge, range visualizer, profit stats
- `frontends/app/src/components/GridVisualization.tsx` — Vertical price axis with level status colors
- `frontends/app/src/components/PerformanceCharts.tsx` — Line chart (portfolio value) + bar chart (daily profit)
- `frontends/app/src/components/StatusBadge.tsx` — Bot status chip
- `frontends/app/src/components/RangeVisualizer.tsx` — Price position bar within grid bounds
- `frontends/app/src/components/TradeHistoryTable.tsx` — Paginated trade table
- `frontends/app/src/components/ConnectionBanner.tsx` — ActionCable connection status banner
- `frontends/app/src/components/RiskSettingsCard.tsx` — Inline-editable stop-loss, take-profit, trailing settings with stop reason alerts (Phase 4)
- `frontends/app/src/theme/index.ts` — MUI v6 theme

### Jobs / Workers
- `app/jobs/snapshot_retention_job.rb` — Sidekiq-cron daily at 03:00 UTC; downsample and prune balance snapshots
- `app/workers/order_fill_worker.rb` — Sidekiq critical queue; processes fills, places counter-orders
- `app/workers/grid_reconciliation_worker.rb` — Sidekiq-cron every 15s; detects and repairs grid gaps; self-scheduling, adopts orphaned exchange orders
- `app/workers/balance_snapshot_worker.rb` — Sidekiq-cron every 5min; captures portfolio snapshots
- `bin/ws_listener` — Standalone process entry point for Bybit::WebsocketListener

### Production (Phase 4)
- `config/systemd/gridbot-puma.service` — systemd unit for Rails API (Puma)
- `config/systemd/gridbot-sidekiq.service` — systemd unit for Sidekiq workers
- `config/systemd/gridbot-ws-listener.service` — systemd unit for WebSocket listener
- `config/systemd/env.example` — Example environment file for systemd units
- `Procfile.dev` — Development process manager (foreman)

### Test Support
- `spec/support/mock_redis.rb` — Shared MockRedis class for specs needing Redis without a live server
- `spec/integration/trading_loop_spec.rb` — 9 end-to-end integration tests (full trading loop, risk management, idempotency)

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
| phase3-dashboard | 3 | Complete | Rails API endpoints, ActionCable, React frontend (Vite + MUI v6 + React Query) |
| phase4-risk-management | 4 | Complete | Stop-loss, take-profit, trailing grid, DCP safety, frontend risk UI, systemd units |
| phase5-feature-specs | 5 | Not started | Capybara browser-based E2E tests for React frontend |
| phase6-analytics | 6 | Not started | Daily stats, tax export, AI suggestions, multi-bot analytics |

## Cross-references

- `docs/agents/patterns/adding-exchange-adapter.md` — How to add a new exchange (Binance, OKX, etc.)
- `docs/agents/patterns/bybit-auth-signing.md` — Bybit HMAC-SHA256 signing details and gotchas
- `docs/agents/patterns/websocket-reconnection.md` — Exponential backoff reconnect, heartbeat, graceful shutdown (Phase 2)
- `docs/agents/patterns/optimistic-locking-sidekiq.md` — Exactly-once counter-order placement with StaleObjectError retry (Phase 2)
- `docs/agents/patterns/self-scheduling-sidekiq-worker.md` — Sub-minute recurring workers without cron (Phase 2)
- `docs/agents/patterns/actioncable-react-integration.md` — Per-resource ActionCable subscription with React Query coexistence (Phase 3)

## History

- 2026-03-07: Phase 1 Foundation complete — Rails skeleton, Bybit REST client, Exchange::Adapter interface, DB schema (6 tables), Grid::Calculator (see phase1-foundation/)
- 2026-03-07: Phase 2 Execution Loop complete — Grid::Initializer, Grid::RedisState, Bybit::WebsocketListener, OrderFillWorker, GridReconciliationWorker, BalanceSnapshotWorker (see phase2-execution-loop/)
- 2026-03-07: Phase 3 Dashboard complete — Rails REST API (10 endpoints), ActionCable BotChannel, Grid::Stopper, BotInitializerJob, React frontend (Vite + MUI v6 + React Query): Dashboard, BotDetail, CreateBotWizard (see phase3-dashboard/)
- 2026-03-07: Phase 4 Safety & Production complete — Grid::RiskManager (atomic stop-loss/take-profit), Grid::TrailingManager (grid shift on top-sell fill), DCP safety (40s dead man's switch), RiskSettingsCard (inline edit), systemd units, Procfile.dev, rate limiter monitoring (see phase4-risk-management/)
- 2026-03-07: Integration specs added — 9 end-to-end tests covering full trading loop, multi-cycle profit, idempotency, fee-adjusted quantities, stop-loss/take-profit, race safety. Shared MockRedis extracted to spec/support/
