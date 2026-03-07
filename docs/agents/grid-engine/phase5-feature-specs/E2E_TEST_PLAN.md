# Phase 5 — E2E Test Plan

## 1. Overview

This document is the authoritative end-to-end test plan for Phase 5 (Feature Specs). It covers the three Capybara feature spec files, test strategy, environment prerequisites, data seeding rules, selector conventions, and individual test cases.

The implementation team writes RSpec feature specs in `spec/features/`. This plan is the specification those specs must satisfy. The manual-tester can also execute every test case by hand using Playwright CLI while the automated suite is being built.

---

## 2. Test Strategy

### 2.1 Scope

| Area | Automated (Capybara + Cuprite) | Manual (Playwright) |
|------|-------------------------------|---------------------|
| Dashboard — bot card display | Yes | Yes |
| Dashboard — navigate to detail | Yes | Yes |
| Dashboard — empty state | Yes | Yes |
| Bot Detail — grid visualization | Yes | Yes |
| Bot Detail — trade history pagination | Yes | Yes |
| Bot Detail — performance charts | Yes | Yes |
| Bot Detail — risk settings view | Yes | Yes |
| Bot Detail — risk settings edit | Yes | Yes |
| Bot Detail — real-time ActionCable update | Yes | Yes |
| Create Bot Wizard — step 1 pair selection | Yes | Yes |
| Create Bot Wizard — step 2 params + validation | Yes | Yes |
| Create Bot Wizard — step 3 investment summary | Yes | Yes |
| Create Bot Wizard — full happy path | Yes | Yes |

**Total scenarios:** 13

### 2.2 Out of Scope

- Visual regression / screenshot diffing
- Performance benchmarking
- Phase 6 Analytics pages (not yet built)
- Cross-browser testing (Chromium only)
- Mobile viewport testing

### 2.3 Test Types

- **Happy path:** User completes an action successfully under normal conditions.
- **Validation/Error path:** User supplies invalid input and sees appropriate feedback.
- **Empty state:** Application renders gracefully with no seeded data.
- **Real-time update:** Server push via ActionCable updates the UI without a reload.

---

## 3. Test Environment

### 3.1 Automated Suite (Capybara + Cuprite)

| Component | Value |
|-----------|-------|
| Driver | Cuprite (Ferrum / CDP, no Selenium) |
| Browser | Headless Chromium |
| Window size | 1280 x 800 |
| Rails server | Puma (mandatory for ActionCable) |
| Frontend | Pre-built Vite assets served from `public/` |
| Database cleaner | Truncation strategy (not transaction) |
| Redis | MockRedis (no live Redis required) |
| Exchange client | Stubbed `Bybit::RestClient` (no real HTTP) |
| ActionCable adapter | `async` (not `test`) during feature specs |
| WebMock | `allow_localhost: true` for feature specs only |

Run command:
```
bundle exec rspec spec/features/
```

Build Vite assets before first run (or set `FORCE_VITE_BUILD=1`):
```
VITE_API_URL=/api/v1 VITE_CABLE_URL=/cable VITE_TEST_MODE=1 npm run build
```

### 3.2 Manual Execution (Playwright CLI)

| Component | Value |
|-----------|-------|
| Frontend URL | http://localhost:3000 |
| Rails API URL | http://localhost:4000 |
| Browser | Any Chromium-based browser |
| Database | Development SQLite or PostgreSQL with seeded data |

Playwright CLI invocation pattern:
```
npx playwright open http://localhost:3000
```

### 3.3 Prerequisites (Both Environments)

- Rails API running and responding to `/api/v1/` requests
- React frontend built with `VITE_API_URL=/api/v1` and served (dev server or static)
- `VITE_TEST_MODE=1` baked into the build to disable React Query stale time and retries
- An `ExchangeAccount` record exists in the database (all bot-related API calls require it)
- The exchange client is stubbed or the Bybit testnet is reachable

---

## 4. Data Seeding Rules

### 4.1 Bot with Grid Levels (Used by Dashboard + Bot Detail)

A complete "running bot" seed requires:
- One `ExchangeAccount` record
- One `Bot` record with `status: 'running'`, `pair: 'ETHUSDT'`, `lower_price: '2000.00'`, `upper_price: '3000.00'`
- Grid levels (minimum 4, mix of buy and sell sides)
- Redis state populated via `Grid::RedisState` (current price, unrealized PnL)

Helper: `seed_bot_redis_state(bot)` in `Features::BotHelpers`

### 4.2 Bot with Trades (Used by Trade History Pagination)

- Same as 4.1 plus at least 26 `Trade` records (default page size is 25, so page 2 requires 26+)
- All trades must have `completed_at`, `buy_price`, `sell_price`, `net_profit` set

### 4.3 Bot with Chart Data (Used by Performance Charts)

- Same as 4.1 plus at least 2 `BalanceSnapshot` records at different timestamps with different `realized_profit` values
- Minimum 2 snapshots is enforced by the `PerformanceCharts` component guard at line 46 of `PerformanceCharts.tsx`

Helper: `seed_bot_with_charts(bot)` in `Features::BotHelpers` (creates 2 snapshots automatically)

### 4.4 Empty State (Used by Dashboard Empty State)

- No `Bot` records in the database (but `ExchangeAccount` may still exist)

### 4.5 Wizard (Used by Create Bot Wizard)

- `ExchangeAccount` record
- Exchange client stub returns: ETHUSDT pair info (`last_price: '2500.00'`), wallet balance (`USDT available: 10000.00`)
- No pre-existing bot records required

---

## 5. Selector Conventions

All test assertions use `data-testid` attributes. CSS class names and MUI internal class names are explicitly forbidden as selectors because MUI generates dynamic class names that change between builds.

The implementation team (frontend-dev-1, task T6) must add the following `data-testid` attributes to the React components before specs can be written:

| Component / Element | data-testid | File |
|---------------------|-------------|------|
| BotCard root element | `bot-card-{id}` | `BotCard.tsx` |
| StatusBadge Chip | `status-badge` | `StatusBadge.tsx` |
| RangeVisualizer container | `range-visualizer` | `RangeVisualizer.tsx` |
| Empty state container | `empty-state` | `BotDashboard.tsx` |
| Empty state "Create Bot" button | `empty-state-create-btn` | `BotDashboard.tsx` |
| GridVisualization container | `grid-visualization` | `GridVisualization.tsx` |
| Individual grid level row | `grid-level-{index}` | `GridVisualization.tsx` |
| TradeHistoryTable container | `trade-history-table` | `TradeHistoryTable.tsx` |
| Trade history pagination | `trade-pagination` | `TradeHistoryTable.tsx` |
| PerformanceCharts equity container | `chart-portfolio` | `PerformanceCharts.tsx` |
| PerformanceCharts daily profit container | `chart-daily-profit` | `PerformanceCharts.tsx` |
| RiskSettingsCard root | `risk-settings-card` | `RiskSettingsCard.tsx` |
| Risk settings Edit button | `risk-settings-edit-btn` | `RiskSettingsCard.tsx` |
| Stop-loss text field input | `input-stop-loss` | `RiskSettingsCard.tsx` |
| Take-profit text field input | `input-take-profit` | `RiskSettingsCard.tsx` |
| Risk settings Save button | `risk-settings-save-btn` | `RiskSettingsCard.tsx` |
| Risk settings Cancel button | `risk-settings-cancel-btn` | `RiskSettingsCard.tsx` |
| Realized profit stat card | `stat-realized-profit` | `BotDetail.tsx` |
| Trade count stat card | `stat-trade-count` | `BotDetail.tsx` |
| Wizard step container (step 1) | `wizard-step-1` | `CreateBotWizard.tsx` |
| Wizard step container (step 2) | `wizard-step-2` | `CreateBotWizard.tsx` |
| Wizard step container (step 3) | `wizard-step-3` | `CreateBotWizard.tsx` |
| Pair Autocomplete input | `pair-select` | `StepSelectPair.tsx` |
| Lower price text field input | `input-lower-price` | `StepSetParameters.tsx` |
| Upper price text field input | `input-upper-price` | `StepSetParameters.tsx` |
| Grid count slider | `input-grid-count` | `StepSetParameters.tsx` |
| Investment slider | `input-investment-pct` | `StepInvestment.tsx` |
| Order summary card | `order-summary` | `StepInvestment.tsx` |
| Wizard Next button | `wizard-next-btn` | `CreateBotWizard.tsx` |
| Wizard Back button | `wizard-back-btn` | `CreateBotWizard.tsx` |
| Wizard Create Bot button | `wizard-submit-btn` | `CreateBotWizard.tsx` |

---

## 6. Wait Strategies

- Use `have_content` / `have_selector` matchers — Capybara retries these for up to `default_max_wait_time` (5 seconds).
- Never use `page.text.include?(...)` — this is a snapshot assertion with no retry.
- Never use `sleep` — fix the underlying timing issue instead.
- For ActionCable updates: broadcast via `Features::CableHelpers#broadcast_to_bot`, then assert with `have_content`. The `async` adapter delivers promptly; the 5-second wait is sufficient.
- For MUI Autocomplete: after typing into the input, wait for the dropdown listbox to appear (`have_css('[role="listbox"]')`), then click the target option.
- For navigation after form submit: use `have_current_path` with wait to confirm redirect.

---

## 7. Spec File Mapping

| Spec File | Test Case IDs | User Story |
|-----------|---------------|------------|
| `spec/features/dashboard_spec.rb` | TC-001, TC-002, TC-003 | US01 |
| `spec/features/bot_detail_spec.rb` | TC-004, TC-005, TC-006, TC-007, TC-008, TC-009 | US02 |
| `spec/features/create_bot_wizard_spec.rb` | TC-010, TC-011, TC-012, TC-013 | US03 |

---

## 8. Test Cases

### TC-001: Bot Card Display

**Priority**: P0
**User Story**: US01 — Dashboard
**Spec file**: `spec/features/dashboard_spec.rb`

**Preconditions**:
- Backend running
- Frontend built with `VITE_TEST_MODE=1`
- `ExchangeAccount` seeded
- One `Bot` record seeded: `status: 'running'`, `pair: 'ETHUSDT'`, `lower_price: '2000.00'`, `upper_price: '3000.00'`, `investment_amount: '5000.00'`, `realized_profit: '42.50'`
- Redis state populated (current price within range, e.g. `2500.00`)
- Exchange client stubbed

**Steps**:
1. Visit `/bots`
2. Wait for the page to load (skeletons disappear)
3. Locate the bot card for ETHUSDT
4. Verify the pair name is displayed
5. Verify the status badge reads "running"
6. Verify the profit figure "42.50" is visible
7. Verify the range visualizer bar is present

**Expected Result**:
- Page renders at `/bots` without error
- A card element with `data-testid="bot-card-{id}"` is present
- Card contains text "ETHUSDT"
- `data-testid="status-badge"` element contains text "running"
- Card contains text "42.50"
- `data-testid="range-visualizer"` element is visible within the card
- No error alert is shown

**Edge Cases**:
- Bot with no uptime (just created): Daily APR shows "--"
- Bot with `realized_profit: '0'`: Profit shows "0"
- Multiple bots: Each renders its own card; cards are ordered by creation time

**Playwright Hints**:
- Selector: `[data-testid="bot-card-{id}"]`
- Wait for: skeletons to be replaced by actual content (wait for `[data-testid="status-badge"]` to be visible)
- Assertion: `expect(page.locator('[data-testid="status-badge"]')).toContainText('running')`

---

### TC-002: Navigate to Bot Detail

**Priority**: P0
**User Story**: US01 — Dashboard
**Spec file**: `spec/features/dashboard_spec.rb`

**Preconditions**:
- Same as TC-001
- Bot record exists with a known `id`

**Steps**:
1. Visit `/bots`
2. Wait for the bot card to appear
3. Click the bot card (the `CardActionArea` is the clickable region)
4. Wait for navigation to complete
5. Verify the URL changed to `/bots/{id}`
6. Verify the page displays the pair name "ETHUSDT"

**Expected Result**:
- URL changes to `/bots/{id}`
- Bot Detail page renders with "ETHUSDT" in the header
- Status badge is present on the detail page
- No error state is shown

**Edge Cases**:
- Clicking the floating "+" FAB navigates to `/bots/new` instead of a bot card
- Clicking a stopped bot card still navigates to its detail page

**Playwright Hints**:
- Selector: `[data-testid="bot-card-{id}"]` — click the entire card area
- Wait for: `page.url()` to include `/bots/{id}`
- Assertion: `expect(page).toHaveURL(/\/bots\/\d+/)`

---

### TC-003: Dashboard Empty State

**Priority**: P1
**User Story**: US01 — Dashboard
**Spec file**: `spec/features/dashboard_spec.rb`

**Preconditions**:
- Backend running
- Frontend built
- No `Bot` records in the database
- `ExchangeAccount` may or may not exist

**Steps**:
1. Visit `/bots`
2. Wait for loading state to resolve
3. Verify the empty state is displayed
4. Verify a "Create Bot" button or link is present
5. Click the "Create Bot" button
6. Verify navigation to `/bots/new`

**Expected Result**:
- Text "No bots yet" is visible
- Text "Create your first grid trading bot to get started" is visible
- A button/link to create a bot is present (`data-testid="empty-state-create-btn"`)
- Clicking it navigates to `/bots/new`
- No bot cards are rendered

**Edge Cases**:
- After creating a bot and being redirected back to `/bots`, the card appears (covered by TC-013)
- API error state: Shows error alert with "Failed to load bots" (separate concern, not a seeding scenario)

**Playwright Hints**:
- Selector: `[data-testid="empty-state"]`, `[data-testid="empty-state-create-btn"]`
- Wait for: `[data-testid="empty-state"]` to be visible (confirms loading finished)
- Assertion: `expect(page.locator('[data-testid="empty-state"]')).toBeVisible()`

---

### TC-004: Grid Visualization

**Priority**: P0
**User Story**: US02 — Bot Detail
**Spec file**: `spec/features/bot_detail_spec.rb`

**Preconditions**:
- Backend running, frontend built
- Bot seeded with `status: 'running'`, `pair: 'BTCUSDT'`
- At least 6 `GridLevel` records for the bot: 3 with `expected_side: 'buy'`, 3 with `expected_side: 'sell'`
- At least 2 levels with `status: 'active'`
- Redis state populated with current price
- Exchange client stubbed

**Steps**:
1. Visit `/bots/{id}`
2. Wait for the page header to display the pair name
3. Locate the grid visualization container
4. Verify buy-side levels are present with green color distinction
5. Verify sell-side levels are present with red color distinction
6. Verify the current price marker/label is visible
7. Verify levels are sorted by price descending (highest price at top)

**Expected Result**:
- `data-testid="grid-visualization"` container is visible
- Multiple `data-testid="grid-level-{index}"` rows are present
- Buy-side rows have a green (`#4caf50`) bar color
- Sell-side rows have a red (`#f44336`) bar color
- A "Current:" price label is shown at the bottom of the grid container
- Prices are displayed in descending order top-to-bottom

**Edge Cases**:
- No grid levels seeded: "Not enough data yet." text is shown instead of the grid
- All levels filled/pending: bars render at 40% opacity (grey, `#555`)
- Level at current price: a yellow marker line overlays that row

**Playwright Hints**:
- Selector: `[data-testid="grid-visualization"]`, `[data-testid="grid-level-0"]`
- Wait for: `[data-testid="grid-visualization"]` to be visible
- Assertion: `expect(page.locator('[data-testid="grid-level-0"]')).toBeVisible()`
- Note: Color assertions may require evaluating computed styles via `page.evaluate()`

---

### TC-005: Trade History Pagination

**Priority**: P0
**User Story**: US02 — Bot Detail
**Spec file**: `spec/features/bot_detail_spec.rb`

**Preconditions**:
- Bot seeded with `status: 'running'`
- 26 `Trade` records for the bot (default page size is 25; 26 triggers pagination controls)
- Each trade has `completed_at`, `buy_price`, `sell_price`, `net_profit`, `quantity`, `total_fees`, `level_index`
- Exchange client stubbed

**Steps**:
1. Visit `/bots/{id}`
2. Scroll down to the trade history section
3. Wait for the `data-testid="trade-history-table"` to be visible
4. Verify the table shows 25 rows (page 1)
5. Verify pagination controls are visible (`data-testid="trade-pagination"`)
6. Click the "next page" pagination button (MUI `TablePagination` next arrow)
7. Wait for the table to update
8. Verify the table now shows the remaining trade(s) (page 2)
9. Verify the date, level index, and profit values in the rows are different from page 1

**Expected Result**:
- Page 1: 25 trade rows visible in the table
- Pagination controls show total count reflecting 26 trades
- After clicking next: 1 trade row visible (page 2)
- Table header columns remain: Date, Level, Buy Price, Sell Price, Qty, Net Profit, Fees
- Net profit values are color-coded (green for positive, red for negative)

**Edge Cases**:
- Zero trades: "No trades completed yet. Waiting for the first grid cycle." text shown; no pagination
- Exactly 25 trades: 25 rows shown but no pagination controls (pagination only appears when `total_pages > 1`)
- Navigating back to page 1 from page 2 restores the first set of trades

**Playwright Hints**:
- Selector: `[data-testid="trade-history-table"]`, `[data-testid="trade-pagination"]`
- Wait for: `[data-testid="trade-history-table"] tbody tr` to have count 25
- Next page button: `[aria-label="Go to next page"]` (MUI TablePagination renders this aria label)
- Assertion: `expect(page.locator('[data-testid="trade-history-table"] tbody tr')).toHaveCount(1)`

---

### TC-006: Performance Charts

**Priority**: P1
**User Story**: US02 — Bot Detail
**Spec file**: `spec/features/bot_detail_spec.rb`

**Preconditions**:
- Bot seeded with `status: 'running'`
- At least 2 `BalanceSnapshot` records at different timestamps (use `seed_bot_with_charts` helper)
  - Snapshot 1: `snapshot_at: 2.hours.ago`, `total_value_quote: '10000.00'`, `realized_profit: '0.00'`
  - Snapshot 2: `snapshot_at: 1.hour.ago`, `total_value_quote: '10050.00'`, `realized_profit: '50.00'`
- Exchange client stubbed

**Steps**:
1. Visit `/bots/{id}`
2. Wait for the page to load
3. Locate the equity curve chart (`data-testid="chart-portfolio"`)
4. Verify it is visible and contains a rendered chart (SVG element is present)
5. Locate the daily profit bar chart (`data-testid="chart-daily-profit"`)
6. Verify it is visible and contains rendered bars

**Expected Result**:
- `data-testid="chart-portfolio"` is visible and contains an SVG element (Recharts renders to SVG)
- The equity curve SVG has at least 2 data points
- `data-testid="chart-daily-profit"` is visible and contains an SVG element
- Neither chart shows "Not enough data yet." text
- "Equity Curve" label is visible
- "Daily Profit" label is visible

**Edge Cases**:
- Only 1 snapshot seeded: "Not enough data yet. Charts appear after the first few minutes of running." is shown; neither chart renders
- 0 snapshots: same "not enough data" message
- Daily profit chart only shows when `dailyProfitData.length > 0`; with 2 snapshots at different days this is guaranteed

**Playwright Hints**:
- Selector: `[data-testid="chart-portfolio"] svg`, `[data-testid="chart-daily-profit"] svg`
- Wait for: `[data-testid="chart-portfolio"]` to be visible
- Assertion: `expect(page.locator('[data-testid="chart-portfolio"] svg')).toBeVisible()`
- Note: Recharts renders into `<svg>` elements with `<path>` children; asserting SVG presence is sufficient

---

### TC-007: Risk Settings View

**Priority**: P0
**User Story**: US02 — Bot Detail
**Spec file**: `spec/features/bot_detail_spec.rb`

**Preconditions**:
- Bot seeded with `status: 'running'`, `stop_loss_price: '1800.00'`, `take_profit_price: '3200.00'`, `trailing_up_enabled: false`
- Exchange client stubbed

**Steps**:
1. Visit `/bots/{id}`
2. Wait for the page to load
3. Locate the risk settings card (`data-testid="risk-settings-card"`)
4. Verify stop-loss price is displayed as "$1800.00"
5. Verify take-profit price is displayed as "$3200.00"
6. Verify trailing grid status is displayed as "OFF"
7. Verify the "Edit" button is visible (bot is running, so editing is allowed)

**Expected Result**:
- `data-testid="risk-settings-card"` is visible
- Text "Stop Loss: $1800.00" is present
- Text "Take Profit: $3200.00" is present
- Text "Trailing Grid: OFF" is present
- "Risk Settings" section heading is visible
- `data-testid="risk-settings-edit-btn"` is visible

**Edge Cases**:
- `stop_loss_price: nil`: Displays "Stop Loss: Not set"
- `take_profit_price: nil`: Displays "Take Profit: Not set"
- `trailing_up_enabled: true`: Displays "Trailing Grid: ON"
- Bot `status: 'stopped'`: Edit button is hidden (`canEdit` is false)
- Bot triggered stop-loss: A warning alert "Stopped: Stop Loss triggered" is shown above the risk settings

**Playwright Hints**:
- Selector: `[data-testid="risk-settings-card"]`, `[data-testid="risk-settings-edit-btn"]`
- Wait for: `[data-testid="risk-settings-card"]` to be visible
- Assertion: `expect(page.locator('[data-testid="risk-settings-card"]')).toContainText('$1800.00')`

---

### TC-008: Risk Settings Inline Edit

**Priority**: P0
**User Story**: US02 — Bot Detail
**Spec file**: `spec/features/bot_detail_spec.rb`

**Preconditions**:
- Bot seeded with `status: 'running'`, `stop_loss_price: '1800.00'`, `take_profit_price: '3200.00'`, `trailing_up_enabled: false`
- Exchange client stubbed
- The API `PATCH /api/v1/bots/{id}` is stubbed to return the updated bot (or a real test DB update is used)

**Steps**:
1. Visit `/bots/{id}`
2. Wait for the risk settings card to appear
3. Click the "Edit" button (`data-testid="risk-settings-edit-btn"`)
4. Verify the form fields appear (stop-loss input, take-profit input, trailing switch)
5. Clear the stop-loss input (`data-testid="input-stop-loss"`)
6. Type the new value: `"1750.00"`
7. Click the "Save" button (`data-testid="risk-settings-save-btn"`)
8. Wait for the form to close (editing state returns to view mode)
9. Verify the displayed stop-loss value is now "$1750.00"

**Expected Result**:
- Clicking Edit reveals the text fields (Stop Loss Price, Take Profit Price) and the Trailing Grid switch
- The stop-loss input is pre-populated with "1800.00"
- After typing "1750.00" and clicking Save, the form closes
- The risk settings view mode shows "Stop Loss: $1750.00"
- No error alert is displayed

**Edge Cases**:
- Clicking Cancel instead of Save: form closes; original value "1800.00" is still shown
- Saving with blank stop-loss: sends `null` to API; view shows "Stop Loss: Not set"
- API error during save: error alert "Failed to update risk settings" appears within the card
- Save button is disabled while `updateBot.isPending`

**Playwright Hints**:
- Selector: `[data-testid="input-stop-loss"]` (the actual `<input>` element within the MUI TextField)
- Clear + type: `await page.locator('[data-testid="input-stop-loss"]').clear(); await page.locator('[data-testid="input-stop-loss"]').fill('1750.00')`
- Wait for: form to close — assert `[data-testid="risk-settings-edit-btn"]` is visible again (view mode restored)
- Assertion: `expect(page.locator('[data-testid="risk-settings-card"]')).toContainText('$1750.00')`

---

### TC-009: Real-Time ActionCable Fill Update

**Priority**: P1
**User Story**: US02 — Bot Detail
**Spec file**: `spec/features/bot_detail_spec.rb`

**Preconditions**:
- Bot seeded with `status: 'running'`, `realized_profit: '10.00'`, `trade_count: 3`
- ActionCable using `async` adapter (configured in `spec/support/capybara.rb`)
- Exchange client stubbed

**Steps**:
1. Visit `/bots/{id}`
2. Wait for the page to load
3. Verify the initial realized profit stat shows "10.00" (`data-testid="stat-realized-profit"`)
4. Verify the initial trade count shows "3" (`data-testid="stat-trade-count"`)
5. From the test helper, broadcast a fill event to channel `"bot_{id}"`:
   ```ruby
   broadcast_to_bot(bot.id, {
     type: 'fill',
     realized_profit: '12.50',
     trade_count: 5,
     unrealized_pnl: '-0.30',
     active_levels: 18
   })
   ```
6. Without reloading the page, wait for the realized profit to update
7. Verify the realized profit stat now shows "12.50"
8. Verify the trade count stat now shows "5"

**Expected Result**:
- The realized profit `data-testid="stat-realized-profit"` updates from "10.00" to "12.50" without a page reload
- The trade count `data-testid="stat-trade-count"` updates from "3" to "5"
- No page reload occurs (the URL does not change; no full-page navigation)
- The update happens within 5 seconds (Capybara default wait)

**Edge Cases**:
- Broadcast with `type: 'status_change'`: the status badge updates to the new status
- Broadcast while the risk settings edit form is open: form is not interrupted; stats update in the background
- Multiple rapid broadcasts: the last broadcast value is reflected in the UI

**Playwright Hints**:
- This scenario is only fully testable via Capybara (the `broadcast_to_bot` helper runs server-side)
- For manual Playwright testing: trigger a fill event by directly calling the Rails console or a test endpoint
- Assertion: `expect(page.locator('[data-testid="stat-realized-profit"]')).toContainText('12.50')`
- The `useBotChannel` hook in `BotDetail.tsx` merges the broadcast payload into the bot query cache

---

### TC-010: Wizard Step 1 — Pair Selection

**Priority**: P0
**User Story**: US03 — Create Bot Wizard
**Spec file**: `spec/features/create_bot_wizard_spec.rb`

**Preconditions**:
- Backend running, frontend built
- Exchange client stubbed to return pairs including `ETHUSDT` (last_price: `'2500.00'`) and `BTCUSDT` (last_price: `'45000.00'`)
- `ExchangeAccount` seeded

**Steps**:
1. Visit `/bots/new`
2. Verify the wizard renders on Step 1 ("Select Pair")
3. Verify the stepper shows "Select Pair" as the active step
4. Verify the "Next" button is disabled (no pair selected yet)
5. Click the pair Autocomplete input (`data-testid="pair-select"`)
6. Type "ETH" in the input
7. Wait for the autocomplete dropdown to appear
8. Select "ETHUSDT" from the dropdown
9. Verify "ETHUSDT" is now shown in the input
10. Verify the "Next" button becomes enabled

**Expected Result**:
- Wizard renders at `/bots/new` with step 1 active (`data-testid="wizard-step-1"` visible)
- Stepper shows three steps: "Select Pair", "Set Parameters", "Investment"
- "Back" button is disabled on step 1
- "Next" button is disabled until a pair is selected
- After selecting ETHUSDT: "Next" button becomes enabled
- The Autocomplete shows pair options with symbol on the left and last price on the right

**Edge Cases**:
- Typing a non-existent symbol: dropdown shows "No options"
- Exchange returns empty pairs list: Autocomplete shows no options
- Clearing the selection after choosing: "Next" becomes disabled again

**Playwright Hints**:
- Selector: `[data-testid="pair-select"] input` (the inner input of MUI Autocomplete)
- Type: `await page.locator('[data-testid="pair-select"] input').fill('ETH')`
- Wait for: `[role="listbox"]` to appear
- Click option: `await page.locator('[role="option"]:has-text("ETHUSDT")').click()`
- Assertion: `expect(page.locator('[data-testid="wizard-next-btn"]')).toBeEnabled()`

---

### TC-011: Wizard Step 2 — Parameters and Validation

**Priority**: P0
**User Story**: US03 — Create Bot Wizard
**Spec file**: `spec/features/create_bot_wizard_spec.rb`

**Preconditions**:
- Same as TC-010, with ETHUSDT pre-selected before navigating to step 2

**Steps**:
1. Complete step 1 (select ETHUSDT, click Next)
2. Verify the wizard is on step 2 (`data-testid="wizard-step-2"` visible)
3. Verify the pair summary header shows "ETHUSDT — Last price: 2500.00"
4. Verify default values are pre-populated in lower price and upper price inputs
5. Enter an invalid lower price that equals the upper price (e.g., both `"2500.00"`)
6. Verify a validation error appears on the upper price field ("Upper must be greater than lower")
7. Verify the "Next" button is disabled
8. Clear the upper price and type a valid value: `"3000.00"`
9. Verify the validation error disappears
10. Verify the "Next" button becomes enabled
11. Verify the Live Preview shows a non-zero "Grid step size" and "Profit per grid" value
12. Click "Next" to advance to step 3

**Expected Result**:
- Step 2 container (`data-testid="wizard-step-2"`) is visible
- Lower price input (`data-testid="input-lower-price"`) is pre-filled with a computed default
- Upper price input (`data-testid="input-upper-price"`) is pre-filled with a computed default
- With invalid params: "Next" is disabled and error helper text is shown under the offending field
- With valid params: "Next" is enabled and Live Preview shows step size and profit percentage
- Grid count slider defaults to 20

**Edge Cases**:
- Lower price `"0"` or negative: validation error "Lower price must be positive"
- Upper price less than lower price: validation error on upper price field
- Grid count set to minimum (2) via slider: Live Preview recalculates
- Setting geometric spacing type: toggle button changes from "Arithmetic" to "Geometric"
- Setting stop-loss above lower price but below current: accepted (optional field)
- Setting stop-loss above upper price: validation error

**Playwright Hints**:
- Selector: `[data-testid="input-lower-price"]`, `[data-testid="input-upper-price"]`, `[data-testid="input-grid-count"]`
- Clear + fill: `await page.locator('[data-testid="input-upper-price"]').fill('2500.00')`
- Assertion for error: `expect(page.locator('[data-testid="input-upper-price"]').locator('xpath=ancestor::div[contains(@class,"MuiFormControl")]')).toContainText('Upper')`
- Assertion for Next disabled: `expect(page.locator('[data-testid="wizard-next-btn"]')).toBeDisabled()`

---

### TC-012: Wizard Step 3 — Investment Summary

**Priority**: P0
**User Story**: US03 — Create Bot Wizard
**Spec file**: `spec/features/create_bot_wizard_spec.rb`

**Preconditions**:
- Same as TC-011
- Exchange client stub returns wallet balance: USDT available `'10000.00'`
- Steps 1 and 2 completed with valid values: ETHUSDT selected, lower `'2000.00'`, upper `'3000.00'`, grid count 20

**Steps**:
1. Complete steps 1 and 2, click Next to reach step 3
2. Verify the wizard is on step 3 (`data-testid="wizard-step-3"` visible)
3. Verify "Available USDT: 10000.00" is displayed
4. Verify the investment slider defaults to 50%
5. Verify the investment amount shows "5000.00 USDT" (50% of 10000)
6. Verify the Order Summary card (`data-testid="order-summary"`) is visible and shows:
   - Pair: ETHUSDT
   - Range: 2000.00 — 3000.00
   - Grid Count: 20
   - Spacing: Arithmetic
   - Total Investment: 5000.00 USDT
7. Move the investment slider to 80%
8. Verify the investment amount updates to "8000.00 USDT"
9. Verify the Order Summary "Total Investment" updates to "8000.00 USDT"
10. Verify the "Create Bot" submit button is visible and enabled

**Expected Result**:
- Step 3 container is visible
- Exchange balance is displayed (requires the balance API stub to respond)
- Investment slider is interactive; changing it recalculates the amounts in real time
- Order Summary shows accurate values derived from steps 1 and 2
- "Create Bot" button is visible and not disabled
- "Back" button is enabled (allows returning to step 2)

**Edge Cases**:
- Exchange balance API fails: error alert "Failed to load balance" shown; no slider visible
- USDT balance is 0: investment amount stays 0 regardless of slider position
- Investment at 10% (minimum): summary shows 10% of available balance
- Investment at 100% (maximum): summary shows full available balance

**Playwright Hints**:
- Selector: `[data-testid="order-summary"]`, `[data-testid="wizard-submit-btn"]`
- Slider interaction: use `page.locator('[data-testid="input-investment-pct"]')` and drag or set value via `evaluate`
- Assertion: `expect(page.locator('[data-testid="order-summary"]')).toContainText('ETHUSDT')`
- Assertion: `expect(page.locator('[data-testid="wizard-submit-btn"]')).toBeEnabled()`

---

### TC-013: Wizard Full Happy Path

**Priority**: P0
**User Story**: US03 — Create Bot Wizard
**Spec file**: `spec/features/create_bot_wizard_spec.rb`

**Preconditions**:
- Exchange client stubbed: pairs list includes ETHUSDT (last_price `'2500.00'`), wallet balance USDT `'10000.00'`
- The `POST /api/v1/bots` API endpoint returns a created bot with `id: 42` (stubbed or via real DB insert)
- If using real DB: bot creation triggers no background jobs (Sidekiq stubbed or inline mode)

**Steps**:
1. Visit `/bots/new`
2. Step 1: Select "ETHUSDT" from the pair dropdown
3. Click "Next"
4. Step 2: Clear the lower price input and type `"2000.00"`
5. Clear the upper price input and type `"3000.00"`
6. Leave grid count at default (20)
7. Click "Next"
8. Step 3: Verify the Order Summary shows ETHUSDT, range 2000.00–3000.00
9. Click "Create Bot"
10. Wait for the API response
11. Verify the URL changes to `/bots/42` (or whatever id the API returned)
12. Verify the Bot Detail page renders with "ETHUSDT" in the header
13. Verify the status badge is present

**Expected Result**:
- All three wizard steps are completed without error
- The "Create Bot" button triggers a `POST /api/v1/bots` request
- On success, `navigate('/bots/42')` is called (as in `CreateBotWizard.tsx` line 92)
- The Bot Detail page loads and shows the bot's pair name "ETHUSDT"
- A status badge is present (initial status may be "pending" or "initializing")
- No error alert is shown during the wizard or on the detail page

**Edge Cases**:
- API returns an error: the error alert "Failed to create bot" is shown above the stepper on step 3
- API returns a bot without an `id`: `navigate('/bots')` is called instead (fallback in `CreateBotWizard.tsx`)
- Create Bot button shows a loading spinner while the request is pending

**Playwright Hints**:
- Selector: `[data-testid="wizard-submit-btn"]`
- Wait for navigation: `await page.waitForURL(/\/bots\/\d+/)`
- Assertion: `expect(page).toHaveURL(/\/bots\/42/)`
- Assertion: `expect(page.locator('h5')).toContainText('ETHUSDT')`
- Note: `isInitializing` check in `BotDetail.tsx` — if status is `pending`/`initializing`, only the spinner is shown. Verify the pair name in the header (always visible) rather than the stats grid.

---

## 9. Acceptance Criteria Cross-Reference

| AC | Test Case(s) |
|----|-------------|
| AC-001 (gems installed) | Pre-run infrastructure check |
| AC-002 (rspec runs headless) | All TC (suite-level) |
| AC-003 (504 existing specs unaffected) | Suite-level regression run |
| AC-004 (Dashboard: bot card display) | TC-001 |
| AC-005 (Bot Detail: ActionCable fill update) | TC-009 |
| AC-006 (Dashboard: empty state) | TC-003 |
| AC-007 (Bot Detail: grid viz buy/sell) | TC-004 |
| AC-008 (Bot Detail: trade history pagination) | TC-005 |
| AC-009 (Bot Detail: charts present) | TC-006 |
| AC-010 (Bot Detail: risk settings edit) | TC-008 |
| AC-011 (Wizard: pair selection + validation) | TC-010, TC-011 |
| AC-012 (Wizard: full flow to Bot Detail) | TC-013 |
| AC-013 (no real Bybit HTTP) | All TC (exchange stub required) |
| AC-014 (no real Redis) | All TC (MockRedis required) |

---

## 10. Risks and Mitigations

| Risk | Mitigation |
|------|-----------|
| `data-testid` attributes not added before specs are written | Frontend-dev-1 completes T6 before any spec can assert on those elements; spec authoring (T7–T9) depends on T6 |
| MUI dynamic class names break selectors | Use only `data-testid` attributes; never MUI class names |
| Charts require 2+ snapshots | `seed_bot_with_charts` helper always creates exactly 2 snapshots with different timestamps |
| React Query stale time returns cached data | `VITE_TEST_MODE=1` sets `staleTime: 0` and `retry: 0` |
| ActionCable `test` adapter not delivering to browser | `async` adapter activated for all `type: :feature` specs in `spec/support/capybara.rb` |
| Vite build required before suite | Build runs automatically in `before(:suite)` if `dist/index.html` is missing; skip stale check with `FORCE_VITE_BUILD=1` |
| Trade pagination requires 26+ trades | Bot helpers seed exactly 26 trades for the pagination scenario |
| Wizard redirect depends on API returning `bot.id` | Exchange stub and bot factory together produce a deterministic bot id; Capybara waits for the URL to match `/bots/\d+` |
