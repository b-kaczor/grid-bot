# Volatility Harvester — Grid Trading Bot

Automated grid trading bot for Bybit (Spot). Places a net of limit buy/sell orders within a price range and profits from sideways market oscillations.

## Stack

- **Backend:** Ruby on Rails 7.1 (API mode), PostgreSQL, Redis, Sidekiq
- **Frontend:** React 18 + TypeScript, Vite, Material-UI v6, React Query, Recharts
- **Exchange:** Bybit V5 API (testnet first), behind an `Exchange::Adapter` interface
- **Real-time:** ActionCable (Rails → React), async-websocket (Bybit → Rails)

## Prerequisites

- Ruby 3.4.7
- Node.js 20+
- PostgreSQL 14+
- Redis 7+

## Setup

```bash
# 1. Clone and install dependencies
bundle install
cd frontends/app && npm install && cd ../..

# 2. Configure environment
cp .env.example .env
# Edit .env with your Bybit testnet API keys and a Lockbox key:
#   BYBIT_API_KEY=your_testnet_api_key
#   BYBIT_API_SECRET=your_testnet_api_secret
#   LOCKBOX_MASTER_KEY=$(rails runner "puts Lockbox.generate_key")

# 3. Create and migrate database
rails db:create db:migrate

# 4. Create an exchange account (required before first use)
rails runner "ExchangeAccount.create!(
  name: 'Bybit Testnet',
  exchange: 'bybit',
  environment: 'testnet',
  api_key: ENV['BYBIT_API_KEY'],
  api_secret: ENV['BYBIT_API_SECRET']
)"
```

## Running

You need 4 processes running. Use separate terminals or a process manager like `foreman`.

```bash
# Terminal 1: Rails API server
rails s -p 3000

# Terminal 2: Sidekiq (background jobs)
bundle exec sidekiq

# Terminal 3: WebSocket listener (Bybit fill events)
bundle exec bin/ws_listener

# Terminal 4: React frontend
cd frontends/app && npm run dev
```

Then open **http://localhost:5173**

## Running Tests

### Unit and Integration Specs

```bash
# All backend specs (517 total)
bundle exec rspec

# Unit + integration specs only (no browser)
bundle exec rspec --exclude-pattern "spec/features/**/*_spec.rb"

# Rubocop
bundle exec rubocop

# Frontend TypeScript check
cd frontends/app && npx tsc --noEmit
```

### E2E Feature Specs (Capybara + Cuprite)

Feature specs drive a real headless Chrome browser against the full Rails + React stack.

**Prerequisites:**
- Chrome or Chromium installed (Cuprite connects via Chrome DevTools Protocol — no Selenium required)
- Frontend assets built with test environment variables (the suite does this automatically on first run)

```bash
# Build Vite assets for testing (automatic on first feature spec run, or force with FORCE_VITE_BUILD=1)
cd frontends/app && \
  VITE_API_URL=/api/v1 VITE_CABLE_URL=/cable VITE_TEST_MODE=1 npm run build && \
  cd ../..

# Run feature specs only
bundle exec rspec spec/features/

# Force a fresh Vite build before running
FORCE_VITE_BUILD=1 bundle exec rspec spec/features/
```

The feature specs cover three pages: Dashboard (3 scenarios), Bot Detail (6 scenarios), and Create Bot Wizard (4 scenarios). No live Redis or Bybit exchange connection is required — both are stubbed.

## Architecture

```
React Frontend (Vite, :5173)
    ↕ REST API + ActionCable
Rails API (Puma, :3000)
    ↕
PostgreSQL    Redis    Sidekiq
                         ↕
              WebSocket Listener (bin/ws_listener)
                         ↕
                    Bybit V5 API
```

### Key Components

| Component | Description |
|-----------|-------------|
| `Grid::Calculator` | Arithmetic/geometric grid level spacing |
| `Grid::Initializer` | Places initial grid orders on exchange |
| `Grid::Stopper` | Safely stops a bot (cancels orders, cleans up) |
| `OrderFillWorker` | Core buy→sell→buy loop with optimistic locking |
| `GridReconciliationWorker` | Detects and repairs grid gaps every 15s |
| `BalanceSnapshotWorker` | Portfolio snapshots every 5 minutes |
| `Bybit::WebsocketListener` | Real-time fill detection via WebSocket |
| `Bybit::RestClient` | Bybit V5 REST API client with rate limiting |
| `Grid::RedisState` | Fast-read cache for dashboard |

### Frontend Pages

| Page | Route | Description |
|------|-------|-------------|
| Dashboard | `/bots` | Bot cards with status, profit, range visualizer |
| Create Bot | `/bots/new` | 3-step wizard: pair → parameters → investment |
| Bot Detail | `/bots/:id` | Grid visualization, charts, trade history |

## Project Structure

```
app/
  channels/        — ActionCable channels (BotChannel)
  controllers/     — API controllers (Api::V1::*)
  jobs/            — Sidekiq jobs (BotInitializerJob)
  models/          — ActiveRecord models (Bot, Order, Trade, etc.)
  services/
    bybit/         — Bybit API client, auth, rate limiter, WebSocket
    exchange/      — Exchange-agnostic adapter interface
    grid/          — Grid calculator, initializer, stopper, Redis state
  workers/         — Sidekiq workers (OrderFill, Reconciliation, Snapshot)
frontends/app/src/
  api/             — API client, React Query hooks
  cable/           — ActionCable consumer and hooks
  components/      — Shared UI components
  pages/           — Route pages (Dashboard, Detail, Wizard)
  theme/           — MUI v6 dark theme
  types/           — TypeScript interfaces
docs/
  IMPLEMENTATION_PLAN.md  — Full 6-phase plan
  agents/                 — Architecture docs per phase
```

## Phases

- [x] Phase 1: Foundation (Bybit client, models, grid math)
- [x] Phase 2: Execution Loop (trading engine, WebSocket, reconciliation)
- [x] Phase 3: Dashboard (Rails API, React frontend, real-time updates)
- [x] Phase 4: Risk Management (stop-loss, take-profit, trailing grid)
- [x] Phase 5: Feature Specs (Capybara browser-based E2E tests)
- [ ] Phase 6: Analytics (daily stats, tax export, AI suggestions)
