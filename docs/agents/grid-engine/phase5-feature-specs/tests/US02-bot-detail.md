# US02 — Bot Detail Test Cases

**User Story**: As a bot operator, I can view a bot's detail page to inspect its grid state, trade history, performance charts, risk settings, and receive live status updates.

**Spec file**: `spec/features/bot_detail_spec.rb`
**Scenarios**: 6
**Test cases**: TC-004, TC-005, TC-006, TC-007, TC-008, TC-009

---

## Shared Preconditions

- Rails API running
- React frontend built with `VITE_TEST_MODE=1`
- `Bybit::RestClient` stubbed — no real HTTP
- `MockRedis` injected — no live Redis
- DatabaseCleaner truncation active
- One `ExchangeAccount` seeded
- ActionCable using `async` adapter for all feature specs (configured in `spec/support/capybara.rb`)

---

### TC-004: Grid Visualization — Buy and Sell Levels Rendered Distinguishably

**Priority**: P0
**User Story**: US02 — Bot Detail
**Acceptance Criteria**: AC-007

**Preconditions**:
- Bot seeded:
  - `status: 'running'`
  - `pair: 'BTCUSDT'`
  - `lower_price: '40000.00'`
  - `upper_price: '50000.00'`
  - `current_price: '45000.00'`
- 8 `GridLevel` records seeded for the bot:
  - Levels 0–3: `expected_side: 'buy'`, `status: 'active'`, prices `40000`, `42000`, `44000`, `44800`
  - Levels 4–7: `expected_side: 'sell'`, `status: 'active'`, prices `45200`, `46000`, `48000`, `50000`
- Redis state populated (`current_price: '45000.00'`)

**Steps**:
1. Visit `/bots/{id}`
2. Wait for the page header to display "BTCUSDT"
3. Locate the grid visualization container (`[data-testid="grid-visualization"]`)
4. Verify the container is visible
5. Verify at least 8 level rows are rendered (`[data-testid="grid-level-{index}"]`)
6. Verify that rows for buy-side levels have a different visual appearance from sell-side levels
7. Verify levels are displayed sorted by price, highest at top
8. Verify the current price label "Current: 45000.00" is present at the bottom of the container
9. Verify one level row has the current price marker (yellow highlight line)

**Expected Result**:
- `[data-testid="grid-visualization"]` is visible
- 8 `[data-testid="grid-level-{index}"]` elements are present
- Buy-side level bars have green background color (`#4caf50`)
- Sell-side level bars have red background color (`#f44336`)
- Highest price level (50000) appears first (top of list), lowest (40000) appears last
- Text "Current: 45000.00" is present
- At least one level row near the current price has the yellow marker overlay

**Edge Cases**:
- No grid levels seeded: "Not enough data yet." text is displayed instead of the grid
- Levels with `status: 'filled'` or `'pending'`: bar color is `#555` at 40% opacity
- Level whose price is within 0.1% of current price: yellow overlay marker is rendered on that row
- Grid with 200 levels: container scrolls (`maxHeight: 500px`) without layout breakage

**Playwright Hints**:
- Selector: `[data-testid="grid-visualization"]`
- Selector for individual levels: `[data-testid="grid-level-0"]`, `[data-testid="grid-level-1"]`, etc.
- Wait for: `[data-testid="grid-visualization"]` visible, then `[data-testid="grid-level-0"]` visible
- Color assertion (buy level bar): use `page.evaluate` to get computed backgroundColor
- Assertion: `expect(page.locator('[data-testid="grid-visualization"]')).toContainText('Current:')`
- Assertion: `expect(page.locator('[data-testid="grid-level-0"]')).toBeVisible()`

**Capybara pattern**:
```ruby
it 'renders buy and sell grid levels with visual distinction' do
  visit "/bots/#{bot.id}"

  expect(page).to have_selector("[data-testid='grid-visualization']")
  expect(page).to have_selector("[data-testid='grid-level-0']")
  expect(page).to have_selector("[data-testid='grid-level-7']")
  expect(page).to have_content('Current:')
end
```

---

### TC-005: Trade History Pagination

**Priority**: P0
**User Story**: US02 — Bot Detail
**Acceptance Criteria**: AC-008

**Preconditions**:
- Bot seeded with `status: 'running'`, `pair: 'ETHUSDT'`
- 26 `Trade` records seeded for the bot. Each trade has:
  - `completed_at`: a valid timestamp
  - `buy_price`: e.g., `'2000.00'`
  - `sell_price`: e.g., `'2100.00'`
  - `net_profit`: e.g., `'4.50'`
  - `quantity`: e.g., `'0.05'`
  - `total_fees`: e.g., `'0.21'`
  - `level_index`: 0–24 cycling
- Trades 1–25 have timestamps from 2 to 26 hours ago; trade 26 has timestamp 1 hour ago
- Redis state populated

**Steps**:
1. Visit `/bots/{id}`
2. Scroll to the "Trade History" section
3. Wait for `[data-testid="trade-history-table"]` to be visible
4. Verify the table displays exactly 25 rows in the body
5. Verify the table headers are: Date, Level, Buy Price, Sell Price, Qty, Net Profit, Fees
6. Verify pagination controls are visible (`[data-testid="trade-pagination"]`)
7. Verify the pagination shows a total of 26 trades
8. Click the "next page" arrow button (`[aria-label="Go to next page"]`)
9. Wait for the table to update
10. Verify the table now shows exactly 1 row (the 26th trade, most recent)
11. Verify the date in the row matches the trade created 1 hour ago
12. Click the "previous page" arrow button
13. Verify the table returns to showing 25 rows

**Expected Result**:
- Page 1: 25 trade rows in `<tbody>`
- Pagination footer shows: "1–25 of 26"
- After clicking next: 1 row in `<tbody>`, pagination shows "26–26 of 26"
- Net profit cells are color-coded: positive values in green (`success.main`), negative in red (`error.main`)
- Previous page navigation restores 25 rows

**Edge Cases**:
- 0 trades: No table rendered; "No trades completed yet. Waiting for the first grid cycle." message shown
- Exactly 25 trades: Table shows 25 rows; NO pagination controls rendered (only shown when `total_pages > 1`)
- 26th trade has negative profit: its Net Profit cell is styled red
- `total_fees` is `'0'`: cell shows "0" without color change

**Playwright Hints**:
- Selector: `[data-testid="trade-history-table"]`, `[data-testid="trade-pagination"]`
- Row count: `page.locator('[data-testid="trade-history-table"] tbody tr')`
- Next page: `page.locator('[aria-label="Go to next page"]').click()`
- Wait after page change: `expect(page.locator('[data-testid="trade-history-table"] tbody tr')).toHaveCount(1)`
- Assertion: `expect(page.locator('[data-testid="trade-history-table"] tbody tr')).toHaveCount(25)`

**Capybara pattern**:
```ruby
it 'paginates trade history across two pages' do
  visit "/bots/#{bot.id}"

  within("[data-testid='trade-history-table']") do
    expect(page).to have_css('tbody tr', count: 25)
  end

  expect(page).to have_selector("[data-testid='trade-pagination']")

  find('[aria-label="Go to next page"]').click

  within("[data-testid='trade-history-table']") do
    expect(page).to have_css('tbody tr', count: 1)
  end
end
```

---

### TC-006: Performance Charts Rendered with Data

**Priority**: P1
**User Story**: US02 — Bot Detail
**Acceptance Criteria**: AC-009

**Preconditions**:
- Bot seeded with `status: 'running'`, `pair: 'ETHUSDT'`
- 2 `BalanceSnapshot` records seeded via `seed_bot_with_charts(bot)`:
  - Snapshot 1: `snapshot_at: 2.hours.ago`, `total_value_quote: '10000.00'`, `realized_profit: '0.00'`
  - Snapshot 2: `snapshot_at: 1.hour.ago`, `total_value_quote: '10050.00'`, `realized_profit: '50.00'`
- Redis state populated

**Steps**:
1. Visit `/bots/{id}`
2. Wait for the page to load (pair name "ETHUSDT" visible in header)
3. Locate the equity curve chart container (`[data-testid="chart-portfolio"]`)
4. Verify it is visible
5. Verify it contains an SVG element (Recharts renders to SVG)
6. Verify the section heading "Equity Curve" is present
7. Locate the daily profit bar chart container (`[data-testid="chart-daily-profit"]`)
8. Verify it is visible
9. Verify it contains an SVG element
10. Verify the section heading "Daily Profit" is present
11. Verify neither chart shows the "Not enough data yet." placeholder text

**Expected Result**:
- `[data-testid="chart-portfolio"]` is visible and contains `<svg>` element
- `[data-testid="chart-daily-profit"]` is visible and contains `<svg>` element
- "Equity Curve" heading text is present
- "Daily Profit" heading text is present
- "Not enough data yet." text is NOT present anywhere on the page

**Edge Cases**:
- Only 1 snapshot: "Not enough data yet. Charts appear after the first few minutes of running." is shown; neither chart container is rendered
- 0 snapshots: same "not enough data" message
- Snapshots on the same day: daily profit chart renders a single bar; equity curve has 2 points
- Snapshots on different days: daily profit chart has one bar per day

**Playwright Hints**:
- Selector: `[data-testid="chart-portfolio"] svg`, `[data-testid="chart-daily-profit"] svg`
- Wait for: `[data-testid="chart-portfolio"]` to be visible
- Assertion: `expect(page.locator('[data-testid="chart-portfolio"] svg')).toBeVisible()`
- Assertion: `expect(page.locator('[data-testid="chart-daily-profit"] svg')).toBeVisible()`
- Negative assertion: `expect(page.locator('body')).not.toContainText('Not enough data yet')`

**Capybara pattern**:
```ruby
it 'renders equity curve and daily profit charts when snapshots exist' do
  visit "/bots/#{bot.id}"

  expect(page).to have_selector("[data-testid='chart-portfolio'] svg")
  expect(page).to have_selector("[data-testid='chart-daily-profit'] svg")
  expect(page).to have_content('Equity Curve')
  expect(page).to have_content('Daily Profit')
  expect(page).not_to have_content('Not enough data yet')
end
```

---

### TC-007: Risk Settings — View Mode

**Priority**: P0
**User Story**: US02 — Bot Detail
**Acceptance Criteria**: AC-010 (view aspect)

**Preconditions**:
- Bot seeded:
  - `status: 'running'`
  - `pair: 'ETHUSDT'`
  - `stop_loss_price: '1800.00'`
  - `take_profit_price: '3200.00'`
  - `trailing_up_enabled: false`
- Redis state populated

**Steps**:
1. Visit `/bots/{id}`
2. Wait for the page to load
3. Locate the risk settings card (`[data-testid="risk-settings-card"]`)
4. Verify the card heading "Risk Settings" is visible
5. Verify stop-loss is displayed as "Stop Loss: $1800.00"
6. Verify take-profit is displayed as "Take Profit: $3200.00"
7. Verify trailing grid status is displayed as "Trailing Grid: OFF"
8. Verify the "Edit" button (`[data-testid="risk-settings-edit-btn"]`) is visible (bot is running)

**Expected Result**:
- `[data-testid="risk-settings-card"]` is visible
- Text "Risk Settings" heading is present
- Text "Stop Loss: $1800.00" is present
- Text "Take Profit: $3200.00" is present
- Text "Trailing Grid: OFF" is present
- `[data-testid="risk-settings-edit-btn"]` button is visible

**Edge Cases**:
- `stop_loss_price: nil` — displays "Stop Loss: Not set"
- `take_profit_price: nil` — displays "Take Profit: Not set"
- `trailing_up_enabled: true` — displays "Trailing Grid: ON"
- `status: 'stopped'` — Edit button is NOT rendered (`canEdit` is false; only running/paused bots can be edited)
- `status: 'paused'` — Edit button IS rendered
- `stop_reason: 'stop_loss'` with `status: 'stopped'` — warning alert "Stopped: Stop Loss triggered" shown above risk settings
- `status: 'stopping'` — error alert "Emergency stop in progress" shown above risk settings

**Playwright Hints**:
- Selector: `[data-testid="risk-settings-card"]`, `[data-testid="risk-settings-edit-btn"]`
- Wait for: `[data-testid="risk-settings-card"]` visible
- Assertion: `expect(page.locator('[data-testid="risk-settings-card"]')).toContainText('$1800.00')`
- Assertion: `expect(page.locator('[data-testid="risk-settings-card"]')).toContainText('Trailing Grid: OFF')`
- Assertion: `expect(page.locator('[data-testid="risk-settings-edit-btn"]')).toBeVisible()`

**Capybara pattern**:
```ruby
it 'displays stop-loss, take-profit, and trailing settings in view mode' do
  visit "/bots/#{bot.id}"

  within("[data-testid='risk-settings-card']") do
    expect(page).to have_content('Risk Settings')
    expect(page).to have_content('Stop Loss: $1800.00')
    expect(page).to have_content('Take Profit: $3200.00')
    expect(page).to have_content('Trailing Grid: OFF')
    expect(page).to have_selector("[data-testid='risk-settings-edit-btn']")
  end
end
```

---

### TC-008: Risk Settings — Inline Edit and Save

**Priority**: P0
**User Story**: US02 — Bot Detail
**Acceptance Criteria**: AC-010

**Preconditions**:
- Bot seeded:
  - `status: 'running'`
  - `pair: 'ETHUSDT'`
  - `stop_loss_price: '1800.00'`
  - `take_profit_price: '3200.00'`
  - `trailing_up_enabled: false`
- Redis state populated
- The `PATCH /api/v1/bots/{id}` endpoint must be available (via real DB update in test environment)

**Steps**:
1. Visit `/bots/{id}`
2. Wait for the risk settings card to be visible
3. Click the "Edit" button (`[data-testid="risk-settings-edit-btn"]`)
4. Verify the form inputs appear:
   - Stop Loss Price text field (`[data-testid="input-stop-loss"]`) pre-filled with "1800.00"
   - Take Profit Price text field (`[data-testid="input-take-profit"]`) pre-filled with "3200.00"
   - Trailing Grid switch visible
5. Clear the stop-loss input
6. Type "1750.00" into the stop-loss input
7. Verify Take Profit still shows "3200.00" (unchanged)
8. Click the "Save" button (`[data-testid="risk-settings-save-btn"]`)
9. Wait for the form to close (edit mode ends)
10. Verify the view mode shows "Stop Loss: $1750.00"
11. Verify "Take Profit: $3200.00" is unchanged
12. Verify the "Edit" button is visible again (view mode restored)

**Expected Result**:
- Clicking Edit transitions from view mode to edit mode
- Stop-loss input is pre-populated with "1800.00"
- After clearing and typing "1750.00", the Save button triggers `PATCH /api/v1/bots/{id}` with `stop_loss_price: '1750.00'`
- On API success: form closes, view mode renders "Stop Loss: $1750.00"
- No error alert is displayed
- The Edit button reappears

**Edge Cases**:
- Clicking Cancel instead of Save: form closes; "Stop Loss: $1800.00" still shown (no change persisted)
- Saving with a blank stop-loss field: sends `stop_loss_price: null`; view shows "Stop Loss: Not set"
- API returns an error during save: error alert "Failed to update risk settings" appears within the card; form stays open
- Enabling the Trailing Grid switch: `trailing_up_enabled: true` is sent on Save; view shows "Trailing Grid: ON"
- Save button is disabled while request is in-flight (`updateBot.isPending`)

**Playwright Hints**:
- Selector: `[data-testid="input-stop-loss"]` — this is the `<input>` inside the MUI TextField
- Clear: `await page.locator('[data-testid="input-stop-loss"]').clear()`
- Fill: `await page.locator('[data-testid="input-stop-loss"]').fill('1750.00')`
- Save: `await page.locator('[data-testid="risk-settings-save-btn"]').click()`
- Wait for edit mode to close: wait for `[data-testid="risk-settings-edit-btn"]` to be visible again
- Assertion: `expect(page.locator('[data-testid="risk-settings-card"]')).toContainText('$1750.00')`
- Note: MUI TextField input element has type="number"; the `data-testid` must be on the `inputProps` of the `<input>` element, not the wrapper

**Capybara pattern**:
```ruby
it 'allows editing stop-loss price inline and persists the change' do
  visit "/bots/#{bot.id}"

  within("[data-testid='risk-settings-card']") do
    find("[data-testid='risk-settings-edit-btn']").click

    fill_in_by_testid('input-stop-loss', with: '1750.00')

    find("[data-testid='risk-settings-save-btn']").click

    expect(page).to have_content('Stop Loss: $1750.00')
    expect(page).to have_selector("[data-testid='risk-settings-edit-btn']")
  end
end
```

---

### TC-009: Real-Time ActionCable Fill Update

**Priority**: P1
**User Story**: US02 — Bot Detail
**Acceptance Criteria**: AC-005

**Preconditions**:
- Bot seeded:
  - `status: 'running'`
  - `pair: 'ETHUSDT'`
  - `realized_profit: '10.00'`
  - `trade_count: 3`
  - `unrealized_pnl: '2.50'`
  - `active_levels: 16`
- Redis state populated
- ActionCable `async` adapter active (set in `spec/support/capybara.rb` `before(:each, type: :feature)`)
- `Features::CableHelpers` included (`broadcast_to_bot(bot_id, payload)`)

**Steps**:
1. Visit `/bots/{id}`
2. Wait for the page to load (pair name "ETHUSDT" visible)
3. Verify `[data-testid="stat-realized-profit"]` displays "10.00"
4. Verify `[data-testid="stat-trade-count"]` displays "3"
5. From the test code, broadcast a fill event:
   ```ruby
   broadcast_to_bot(bot.id, {
     type: 'fill',
     realized_profit: '12.50',
     trade_count: 5,
     unrealized_pnl: '-0.30',
     active_levels: 18
   })
   ```
6. WITHOUT reloading the page, wait for the UI to update
7. Verify `[data-testid="stat-realized-profit"]` now displays "12.50"
8. Verify `[data-testid="stat-trade-count"]` now displays "5"

**Expected Result**:
- Initial values "10.00" and "3" are visible before the broadcast
- After broadcasting, the realized profit stat updates to "12.50" without a page reload
- The trade count stat updates to "5" without a page reload
- The URL remains `/bots/{id}` (no navigation occurred)
- The update happens within 5 seconds (Capybara's default wait is sufficient)

**Edge Cases**:
- Multiple rapid broadcasts: final values from the last broadcast are shown
- Broadcast while risk settings edit form is open: stat cards update in the background; the open edit form is not disrupted
- Broadcast with `type: 'status_change'` and `status: 'paused'`: status badge updates to "paused"; Pause button becomes Resume button
- Broadcast with `type: 'error'` and `status: 'error'`: error alert "Bot encountered an error" appears
- Browser tab in background (Capybara Cuprite): WebSocket connection remains active; broadcast still delivered

**Playwright Hints**:
- This test case is primarily for Capybara automation; manual Playwright execution requires server-side intervention
- For manual testing: open Rails console and run:
  ```ruby
  ActionCable.server.broadcast("bot_1", {type: 'fill', realized_profit: '12.50', trade_count: 5})
  ```
- Assertion (Capybara): `expect(page).to have_selector("[data-testid='stat-realized-profit']", text: '12.50')`
- Note: `have_content` / `have_selector` with text automatically retries for up to `default_max_wait_time` (5s)
- Note: `useBotChannel` hook in `BotDetail.tsx` merges the ActionCable payload into the React Query bot cache

**Capybara pattern**:
```ruby
it 'updates realized profit and trade count via ActionCable without page reload' do
  visit "/bots/#{bot.id}"

  expect(page).to have_selector("[data-testid='stat-realized-profit']", text: '10.00')
  expect(page).to have_selector("[data-testid='stat-trade-count']", text: '3')

  broadcast_to_bot(bot.id, {
    type: 'fill',
    realized_profit: '12.50',
    trade_count: 5,
    unrealized_pnl: '-0.30',
    active_levels: 18
  })

  expect(page).to have_selector("[data-testid='stat-realized-profit']", text: '12.50')
  expect(page).to have_selector("[data-testid='stat-trade-count']", text: '5')
end
```
