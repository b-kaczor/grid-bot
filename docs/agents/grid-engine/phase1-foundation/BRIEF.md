# Phase 1: Foundation — BRIEF

## Problem to Solve

There is no working codebase. Before any trading logic can run, the project needs a Rails application skeleton, a reliable Bybit API client, a database schema to persist bot state, and a mathematically correct grid calculator. Without these foundations, no subsequent phase can be built or tested. The immediate success signal is: connect to Bybit testnet, fetch a live price, calculate grid levels, and place/cancel a limit order — all from the Rails console.

---

## Goals and Scope

**In scope:**
- Rails API application bootstrap with all required gems and infrastructure configuration
- Custom Bybit REST API v5 client (Faraday-based) behind an `Exchange::Adapter` interface
- PostgreSQL database schema: 6 core tables
- Grid math service: arithmetic and geometric spacing, neutral zone handling
- Testnet connectivity verification (manual console checks)

**Out of scope:**
- WebSocket listener (Phase 2)
- Bot initialization / order placement loop (Phase 2)
- React frontend (Phase 3)
- Stop-loss, trailing grid, production deployment (Phase 4)

---

## User Personas

**Developer / Bot Operator** — the person running the bot. At this phase they interact only via Rails console and environment configuration. No UI exists yet.

---

## Feature Description

### 1.1 Project Bootstrap

- Create Rails API app: `rails new grid_bot --api --database=postgresql --skip-action-mailer --skip-action-mailbox --skip-action-text --skip-active-storage`
- Add gems: `sidekiq`, `redis`, `faraday`, `faraday-retry`, `async-websocket`, `lockbox`, `dotenv-rails`, `oj`
- Frontend scaffold: React app in `frontends/app/` using Vite, with Material-UI v6, React Query, React Router (scaffold only — no UI features in this phase)
- Configure PostgreSQL, Redis, Sidekiq
- Environment variables via `.env`: `BYBIT_BASE_URL`, `BYBIT_WS_PUBLIC`, `BYBIT_WS_PRIVATE`, `BYBIT_API_KEY`, `BYBIT_API_SECRET`; API key/secret encrypted via Lockbox
- Default to testnet URLs: `https://api-testnet.bybit.com`, `wss://stream-testnet.bybit.com/v5/public/spot`, `wss://stream-testnet.bybit.com/v5/private`

### 1.2 Bybit REST API Client

**Authentication** (`app/services/bybit/auth.rb`):
- HMAC-SHA256 signing: `HMAC_SHA256(secret, timestamp + apiKey + recvWindow + params)`
- Request headers: `X-BAPI-API-KEY`, `X-BAPI-TIMESTAMP`, `X-BAPI-SIGN`, `X-BAPI-RECV-WINDOW`

**REST client** (`app/services/bybit/rest_client.rb`) — implements `Exchange::Adapter` interface:

| Method | Endpoint | Auth |
|--------|----------|------|
| `get_wallet_balance` | `GET /v5/account/wallet-balance` | Yes |
| `get_instruments_info` | `GET /v5/market/instruments-info` | No |
| `get_tickers` | `GET /v5/market/tickers` | No |
| `place_order` | `POST /v5/order/create` | Yes |
| `batch_place_orders` | `POST /v5/order/create-batch` | Yes |
| `cancel_order` | `POST /v5/order/cancel` | Yes |
| `cancel_all_orders` | `POST /v5/order/cancel-all` | Yes |
| `get_open_orders` | `GET /v5/order/realtime` | Yes |
| `set_dcp` | `POST /v5/order/disconnected-cancel-all` | Yes |

**Rate limiter** (`app/services/bybit/rate_limiter.rb`):
- Redis-backed token bucket
- Reads response headers: `X-Bapi-Limit-Status`, `X-Bapi-Limit-Reset-Timestamp`
- Limits: 20 req/s for order create/cancel; 10 req/s for batch/query; 600 req per 5s IP limit

**Exchange::Adapter interface** (`app/services/exchange/adapter.rb`):
- Abstract interface defining the contract all exchange clients must implement
- Allows Binance or other exchanges to be added later without modifying grid logic

### 1.3 Database Schema (6 Tables)

All migrations created and applied to testnet-connected DB.

1. **exchange_accounts** — stores encrypted API credentials per exchange/environment; unique index on `[exchange, environment]`
2. **bots** — grid bot configuration: pair, price range, grid count, spacing type, investment amount, instrument constraints (tick_size, min_order_amt, min_order_qty, precisions), status, stop/take-profit prices, trailing flag
3. **grid_levels** — one record per price level per bot; tracks expected side, current order ID, cycle count; optimistic locking via `lock_version`; unique index on `[bot_id, level_index]`
4. **orders** — one record per order placed; tracks exchange_order_id, order_link_id (unique, used for idempotency), side, price, quantities (requested / filled / net), fee details, status lifecycle
5. **trades** — one record per completed buy+sell cycle; links buy and sell orders; stores gross_profit, total_fees, net_profit
6. **balance_snapshots** — periodic portfolio value snapshots at `fine` (5-min), `hourly`, and `daily` granularity; indexed for retention policy queries

**Snapshot retention** (`SnapshotRetentionWorker`, Sidekiq-cron at 03:00 UTC daily):
- Keep `fine` snapshots for 7 days
- Aggregate to `hourly` after 7 days (closest to :00)
- Aggregate to `daily` after 30 days (end-of-day snapshot)

### 1.4 Grid Math Service

`app/services/grid/calculator.rb`

**Arithmetic spacing:**
```
step = (upper - lower) / grid_count
level[i] = lower + (i * step)   # i = 0..grid_count
```

**Geometric spacing:**
```
ratio = (upper / lower) ^ (1.0 / grid_count)
level[i] = lower * (ratio ^ i)  # i = 0..grid_count
```

**Additional calculations:**
- `quantity_per_grid` = investment_amount / (grid_count + 1) / current_price
- Round prices to `tick_size`, quantities to `base_precision`
- Validate per level: `quantity_per_grid * price >= min_order_amt` AND `quantity_per_grid >= min_order_qty`
- Classify each level as BUY (below current price) or SELL (above current price)
- **Neutral zone:** Skip any level within 0.1% of current price — prevents immediate taker fills at initialization that would corrupt grid state

---

## Acceptance Criteria

**AC-001 (P0):** `Bybit::RestClient.new.get_tickers(symbol: 'ETHUSDT')` returns a live price from Bybit testnet when called from Rails console.

**AC-002 (P0):** `Bybit::RestClient.new.get_wallet_balance` returns the test USDT balance from Bybit testnet.

**AC-003 (P0):** `Grid::Calculator.new(lower: 2000, upper: 3000, count: 50, spacing: :arithmetic).levels` returns exactly 51 price levels.

**AC-004 (P0):** A single limit order can be placed and then cancelled on Bybit testnet via the REST client.

**AC-005 (P0):** All 6 database migrations run cleanly with `rails db:migrate`; schema matches the specified column definitions.

**AC-006 (P1):** Rate limiter reads response headers and raises or throttles before hitting exchange rate limits.

**AC-007 (P1):** API key and secret are stored encrypted (Lockbox) in `exchange_accounts`; plaintext never written to DB.

**AC-008 (P1):** `Exchange::Adapter` interface is defined such that `Bybit::RestClient` implements it and a future `Binance::RestClient` would only need to implement the same interface.

**AC-009 (P1):** Neutral zone logic in `Grid::Calculator` correctly skips levels within 0.1% of current price.

**AC-010 (P2):** Frontend scaffold (`frontends/app/`) initializes with Vite + Material-UI v6 + React Query + React Router without errors.
