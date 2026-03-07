# Phase 4: Safety & Production — BRIEF

## Problem to solve

The bot can run autonomously and generate profit (Phases 1–3), but it has no protection against adverse market conditions. A sharp price drop below the grid causes unlimited loss exposure with no automated exit. If the bot process dies or the WebSocket disconnects, open orders remain live on the exchange with no owner. Without production process management, the bot cannot run reliably 24/7 with real capital.

---

## Goals and scope

- Protect capital with configurable stop-loss and take-profit triggers
- Keep the bot alive during bull runs with an optional trailing grid
- Protect open orders when the process dies via Bybit's DCP (Dead Man's Switch)
- Allow users to configure risk parameters at bot creation and update them on the detail page
- Harden production deployment: process supervision, monitoring, alerting

**Out of scope:**
- API key encryption (already built in Phase 1 via Lockbox)
- Retry logic (already built in Phase 1 via faraday-retry)
- Futures/margin risk management (Spot only)

---

## User personas affected

- **Solo trader (primary):** Runs the bot unattended, needs capital protection while sleeping
- **Risk-averse operator:** Wants hard guarantees that losses cannot exceed a defined threshold

---

## Feature description

### 4.1 Grid::RiskManager service

`app/services/grid/risk_manager.rb` — called on every price update received from the WebSocket.

**Stop Loss:**
- Triggered when `current_price <= bot.stop_loss_price` (and `stop_loss_price` is set)
- Actions:
  1. Cancel all open orders via `POST /v5/order/cancel-all`
  2. Market-sell all held base asset
  3. Set `bot.status = stopped`, `bot.stop_reason = stop_loss`
  4. Record final P&L (balance snapshot)
  5. Broadcast status change via ActionCable

**Take Profit:**
- Triggered when `current_price >= bot.take_profit_price` (and `take_profit_price` is set)
- Same actions as stop-loss with `stop_reason = take_profit`

**Constraints:**
- Both triggers are optional (nil = disabled)
- Checks must be idempotent: if the bot is already stopping/stopped, skip
- All decimal comparisons use BigDecimal

### 4.2 Grid::TrailingManager service

`app/services/grid/trailing_manager.rb` — invoked from `OrderFillWorker` when the top-of-grid sell order fills.

**Trigger condition:** The highest-index sell order fills (price has broken above the upper grid boundary).

**Actions:**
1. Cancel the lowest active buy order (level 0)
2. Shift `bot.lower_price` and `bot.upper_price` up by one grid step
3. Recalculate the new top level price
4. Place a new sell order at the new top level
5. Update `GridLevel` records to reflect the shifted range
6. Update Redis hot state (`grid:{bot_id}:levels`)

**Constraints:**
- Only active when `bot.trailing_up_enabled = true`
- Dashboard must display a warning: trailing up keeps the bot running but sells base at lower prices and re-buys higher — it is a continuity mechanism, not a profit strategy
- No configurable max trail distance in MVP (can be added in Phase 5)

### 4.3 DCP Safety (Dead Man's Switch)

Bybit's Disconnected Cancel-All (DCP) auto-cancels all open orders if no heartbeat is received for a configurable window.

**On bot start:**
1. Call `POST /v5/order/disconnected-cancel-all` with `timeWindow: 40` (seconds)
2. Subscribe to the `dcp` topic on the private WebSocket
3. The existing WebSocket heartbeat (ping every 20s) satisfies the DCP window

**Behavior:**
- If the WebSocket listener process dies or disconnects for >40s, Bybit automatically cancels all open orders
- On reconnect, the bot re-registers DCP and triggers `GridReconciliationWorker` to restore the grid

### 4.4 Frontend: risk settings

**Create Bot Wizard — Step 2 additions:**
- Stop Loss Price field (optional, number input, must be below `lower_price` if set)
- Take Profit Price field (optional, number input, must be above `upper_price` if set)
- Trailing Grid toggle (boolean, defaults off), with inline caveat text

**Bot Detail page additions:**
- Risk settings card showing current stop-loss, take-profit, trailing status
- Inline edit: user can update stop-loss and take-profit prices on a running bot via `PATCH /api/v1/bots/:id`
- Trailing toggle (enable/disable on a running bot)
- Stop reason displayed prominently when bot is in `stopped` state (e.g., "Stopped: Stop Loss triggered at $1,850")

### 4.5 Production hardening

- **systemd unit files** for three processes: Puma (Rails), Sidekiq, `bin/ws_listener`
  - All set to `Restart=on-failure`, `RestartSec=5`
- **Monitoring hooks** (log-based, no external service required for MVP):
  - Alert log entry on: WebSocket disconnect >10s, reconciliation discrepancy detected, rate limiter usage >80%
- **IP whitelisting docs:** README note — configure the server's static IP on the Bybit API key settings page
- **Permission scope docs:** README note — API keys must have Spot Trading only, Withdrawals denied

---

## API changes

No new endpoints. Existing `PATCH /api/v1/bots/:id` accepts updated `stop_loss_price`, `take_profit_price`, `trailing_up_enabled`.

Validation rules (server-side):
- `stop_loss_price` must be < `lower_price` (if provided)
- `take_profit_price` must be > `upper_price` (if provided)

---

## Acceptance criteria

**AC-001 — Stop Loss triggers correctly:**
- Given a running bot with `stop_loss_price = 1800` and current price drops to 1800 or below
- All open orders are cancelled on the exchange
- All held base asset is market-sold
- Bot status becomes `stopped` with `stop_reason = stop_loss`
- Final balance snapshot is recorded
- ActionCable broadcasts the status change to connected clients

**AC-002 — Take Profit triggers correctly:**
- Given a running bot with `take_profit_price = 3200` and price rises to 3200 or above
- Same sequence as AC-001 with `stop_reason = take_profit`

**AC-003 — Risk checks are idempotent:**
- If `RiskManager` is called multiple times while the bot is already stopping, no duplicate cancel/sell calls are made

**AC-004 — Stop Loss and Take Profit are optional:**
- A bot with `stop_loss_price = nil` and `take_profit_price = nil` runs normally with no risk triggers fired

**AC-005 — Trailing grid shifts on top-of-grid fill:**
- Given `trailing_up_enabled = true` and the highest sell level fills
- The lowest buy order is cancelled
- `bot.lower_price` and `bot.upper_price` are each incremented by one grid step
- A new sell order is placed at the new upper level
- Redis hot state reflects the updated level map

**AC-006 — Trailing grid is inactive when disabled:**
- Given `trailing_up_enabled = false`, top-of-grid fill is handled by normal `OrderFillWorker` logic only

**AC-007 — DCP registration on bot start:**
- When `Grid::Initializer` completes and bot status becomes `running`, DCP is registered with `timeWindow: 40`
- Verified via Bybit testnet: killing the `bin/ws_listener` process causes all orders to be cancelled within 40s

**AC-008 — DCP re-registers on reconnect:**
- After WebSocket reconnects, DCP is re-registered before any other subscriptions are restored

**AC-009 — Create Bot Wizard accepts risk parameters:**
- Stop Loss, Take Profit, and Trailing toggle are visible in Step 2
- Validation: stop-loss field shows inline error if value >= lower_price; take-profit shows error if value <= upper_price
- Fields are optional; submitting without them creates a bot with nil values

**AC-010 — Bot Detail page shows risk settings:**
- Stop-loss and take-profit prices are displayed
- User can edit them inline on a running bot; changes persist via API
- When bot is stopped with a risk reason, the stop reason is clearly displayed

**AC-011 — systemd units restart on failure:**
- Killing Puma, Sidekiq, or `bin/ws_listener` processes individually causes each to restart within 10s

**AC-012 — Rate limiter monitoring:**
- When Bybit response headers indicate >80% rate limit usage, a WARNING entry is written to the application log

---

## Priority

| Feature | Priority |
|---------|----------|
| Stop-loss (AC-001, 003, 004) | P0 |
| Take-profit (AC-002, 003, 004) | P0 |
| DCP safety (AC-007, 008) | P0 |
| systemd process management (AC-011) | P0 |
| Trailing grid (AC-005, 006) | P1 |
| Frontend risk settings UI (AC-009, 010) | P1 |
| Monitoring/alerting hooks (AC-012) | P2 |
