# Phase 3: The Dashboard — BRIEF

**Area:** grid-engine
**Work Item:** phase3-dashboard
**Phase:** 3 of 5

---

## Problem to Solve

Phases 1 and 2 delivered a fully functional trading engine, but it is entirely opaque to the user. There is no way to create a bot, monitor its performance, or observe what the grid is doing without querying the database directly. A user cannot extract value from the system without a frontend.

The dashboard closes this gap: it must let a user create a bot in three clicks, see live profit figures that match the exchange, and observe the grid reacting to price moves in real time.

---

## Goals and Scope

**In scope:**
- Rails REST API (10 endpoints under `/api/v1/`)
- ActionCable `BotChannel` for real-time push updates to the browser
- React frontend scaffold (Vite + MUI v6 + React Query + React Router)
- Create Bot Wizard (3-step form)
- Bot Dashboard page (card grid)
- Bot Detail page (grid visualization, performance charts, trade history)
- Exchange info endpoints (trading pairs, account balance)

**Out of scope:**
- Stop-loss, take-profit, trailing grid (Phase 4)
- Analytics deep-dive (APR trends, drawdown, grid heatmap) (Phase 5)
- Tax/CSV export (Phase 5)
- AI parameter suggestion (Phase 5)
- BalanceSnapshotWorker — already built in Phase 2

---

## User Personas

**Solo trader (primary):** A single user who owns and operates this instance. Not a multi-tenant SaaS. The UI needs to be functional and clear, not polished for a marketing audience.

---

## Feature Description

### 3.1 Rails API Endpoints

Ten endpoints serve the frontend and provide the data contract:

| Method | Path | Purpose |
|--------|------|---------|
| `POST` | `/api/v1/bots` | Create bot (triggers Grid::Initializer) |
| `GET` | `/api/v1/bots` | List all bots with summary stats |
| `GET` | `/api/v1/bots/:id` | Bot detail: config + grid levels + recent trades |
| `PATCH` | `/api/v1/bots/:id` | Update bot (stop, pause, modify stop-loss/take-profit) |
| `DELETE` | `/api/v1/bots/:id` | Stop bot and cancel all open orders |
| `GET` | `/api/v1/bots/:id/trades` | Paginated trade history |
| `GET` | `/api/v1/bots/:id/chart` | Balance snapshots for charting |
| `GET` | `/api/v1/bots/:id/grid` | Grid levels with current order status |
| `GET` | `/api/v1/exchange/pairs` | Available spot trading pairs from Bybit |
| `GET` | `/api/v1/exchange/balance` | Current account balance (USDT + held base coins) |

Controllers are thin — all business logic stays in service objects.

### 3.2 ActionCable BotChannel

A per-bot channel that streams real-time updates to subscribed frontend clients.

- `OrderFillWorker` broadcasts on every fill: updated grid level state, new trade record, updated realized profit
- WebSocket listener publishes price updates to the channel
- Bot status changes (e.g., `running` → `error`) are broadcast immediately
- Frontend subscribes on Bot Detail page load and unsubscribes on unmount

### 3.3 Create Bot Wizard (`/bots/new`)

Three-step form. User cannot skip steps.

**Step 1 — Select Pair:**
- Searchable dropdown populated from `GET /api/v1/exchange/pairs`
- Shows pair name and current price

**Step 2 — Set Parameters:**
- Lower price, upper price (validated: lower < current < upper)
- Grid count (integer, min 2, max 200)
- Spacing type toggle: Arithmetic / Geometric
- Live preview: calculated grid step size, profit per grid (gross, before fees)

**Step 3 — Investment:**
- Slider: percentage of available USDT balance (fetched from `GET /api/v1/exchange/balance`)
- Shows: total USDT to invest, expected quantity per grid level
- Fee impact summary: estimated fee cost per round trip at current Bybit taker rate (0.1%)
- Confirmation summary of all parameters before submission

On submit: `POST /api/v1/bots` — bot moves to `initializing` status, wizard redirects to Bot Detail page.

### 3.4 Bot Dashboard (`/bots`)

Grid of cards, one per bot.

Each card shows:
- Trading pair (e.g., `ETHUSDT`)
- Bot status badge (`running` / `paused` / `error` / `stopped`)
- Range visualizer: horizontal progress bar showing current price position between lower and upper bounds
- Realized profit (USDT, from completed trades)
- Daily APR (annualized yield based on today's realized profit / total portfolio value)
- Trade count (total completed buy+sell cycles)
- Uptime (human-readable duration since bot started)

Cards link to Bot Detail page. Live stats update via ActionCable without full page reload.

### 3.5 Bot Detail Page (`/bots/:id`)

Four sections:

**Header:** Pair, status badge, start time, stop/pause/resume controls.

**Grid Visualization:**
- Vertical price axis showing all grid levels
- Each level shows: price, side (buy/sell), order status (pending/active/filled)
- Current price marker updates in real time via ActionCable
- Levels color-coded: green = buy active, red = sell active, grey = filled/pending

**Performance:**
- Realized Profit and Unrealized PnL displayed as separate figures (PRD requirement — never combined)
- Line chart: total portfolio value over time (from `balance_snapshots`, via `GET /api/v1/bots/:id/chart`)
- Bar chart: daily realized profit (green positive, red negative)

**Trade History:**
- Paginated table via `GET /api/v1/bots/:id/trades`
- Columns: completed_at, level, buy price, sell price, quantity, net profit, fees
- Newest trades at top; pagination controls at bottom

---

## Acceptance Criteria

### P0 — Must Have

**AC-001:** `POST /api/v1/bots` creates a bot record and enqueues `Grid::Initializer`; response includes bot ID and status `initializing`.

**AC-002:** `GET /api/v1/bots` returns all bots with: pair, status, realized_profit, trade_count, uptime, and current price position within range.

**AC-003:** `GET /api/v1/bots/:id` returns full bot detail including grid levels array and 10 most recent trades.

**AC-004:** `DELETE /api/v1/bots/:id` cancels all open orders on exchange and sets bot status to `stopped`.

**AC-005:** `GET /api/v1/exchange/pairs` returns tradeable spot pairs from Bybit (symbol, base coin, quote coin, current price).

**AC-006:** `GET /api/v1/exchange/balance` returns current USDT balance and per-coin held amounts.

**AC-007:** Create Bot Wizard renders all three steps; user cannot advance without valid input on the current step.

**AC-008:** Step 2 of the wizard displays the calculated grid step size and gross profit-per-grid in real time as the user adjusts parameters.

**AC-009:** Step 3 displays fee impact estimate before submission.

**AC-010:** Bot Dashboard renders a card for each bot showing pair, status, range visualizer, realized profit, and trade count.

**AC-011:** Bot Detail page shows realized profit and unrealized PnL as two separate labeled figures — never summed.

**AC-012:** Bot Detail grid visualization shows all price levels with correct side and status.

**AC-013:** Trade history table on Bot Detail page is paginated and sortable by `completed_at`.

**AC-014:** ActionCable `BotChannel` broadcasts a fill event to subscribed clients within 1 second of `OrderFillWorker` processing it.

**AC-015:** Grid visualization current price marker updates in real time without page refresh when connected to ActionCable.

**AC-016:** The user can create a bot from start to submitted wizard in 3 clicks (select pair → accept defaults → confirm investment).

### P1 — Should Have

**AC-017:** `GET /api/v1/bots/:id/chart` returns balance snapshot time series at appropriate granularity (fine for last 7 days, hourly thereafter).

**AC-018:** Line chart on Bot Detail renders total portfolio value over time from balance snapshot data.

**AC-019:** Daily profit bar chart on Bot Detail shows per-day realized profit.

**AC-020:** Bot status changes (e.g., `running` → `error`) are reflected on the dashboard card without page reload.

**AC-021:** `PATCH /api/v1/bots/:id` accepts `status: "stopped"` to trigger graceful bot shutdown.

### P2 — Nice to Have

**AC-022:** Step 2 of the wizard includes an "AI Suggest" button that calls backend volatility analysis and auto-fills lower/upper price and grid count.

**AC-023:** Pair search in Step 1 filters results as the user types (client-side filter on loaded pairs list).

**AC-024:** Bot Detail page shows bot uptime and a count of active grid levels vs total levels.

---

## Technical Notes

- Frontend lives in `frontends/app/` (Vite + React + MUI v6 + React Query + React Router)
- All financial values displayed to appropriate decimal precision (quote precision from instrument info)
- React Query handles caching and background refresh for REST data; ActionCable handles push updates
- API responses use JSON; no XML, no GraphQL
- Controllers follow Rails API conventions — thin, no business logic
- Redis hot state (`grid:{bot_id}:*`) is the source for live dashboard reads; PostgreSQL for historical data
