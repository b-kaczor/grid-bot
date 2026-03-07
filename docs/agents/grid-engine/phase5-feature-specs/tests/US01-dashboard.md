# US01 — Dashboard Test Cases

**User Story**: As a bot operator, I can view my running bots on a dashboard so that I can quickly assess their status and profit at a glance.

**Spec file**: `spec/features/dashboard_spec.rb`
**Scenarios**: 3
**Test cases**: TC-001, TC-002, TC-003

---

## Shared Preconditions

- Rails API running at `localhost:4000` (automated) or configured port
- React frontend built with `VITE_TEST_MODE=1` and served
- `Bybit::RestClient` stubbed — no real HTTP requests
- `MockRedis` injected — no live Redis required
- DatabaseCleaner truncation strategy active for this spec (data seeded fresh per test)

---

### TC-001: Bot Card Display

**Priority**: P0
**User Story**: US01 — Dashboard
**Acceptance Criteria**: AC-004

**Preconditions**:
- One `ExchangeAccount` record seeded
- One `Bot` record seeded:
  - `status: 'running'`
  - `pair: 'ETHUSDT'`
  - `base_coin: 'ETH'`
  - `quote_coin: 'USDT'`
  - `lower_price: '2000.00'`
  - `upper_price: '3000.00'`
  - `current_price: '2500.00'`
  - `investment_amount: '5000.00'`
  - `realized_profit: '42.50'`
  - `trade_count: 7`
  - `uptime_seconds: 3600`
- Redis state populated with current price via `seed_bot_redis_state(bot)`

**Steps**:
1. Visit `/bots`
2. Wait for the loading skeletons to disappear and bot cards to appear
3. Locate the bot card for ETHUSDT using `[data-testid="bot-card-{id}"]`
4. Within the card, verify the pair name "ETHUSDT" is displayed
5. Within the card, verify the status badge reads "running"
6. Within the card, verify the profit figure "42.50" is visible
7. Within the card, verify the range visualizer element is present
8. Within the card, verify the trade count "7" is visible
9. Within the card, verify an uptime value is shown (e.g., "1h")

**Expected Result**:
- The page renders at `/bots` without any error alert
- Exactly one bot card is displayed
- `[data-testid="bot-card-{id}"]` is present in the DOM
- Text "ETHUSDT" is visible within the card
- `[data-testid="status-badge"]` contains text "running" and has success color
- Text "42.50" is visible (profit figure)
- `[data-testid="range-visualizer"]` element is visible within the card
- Text "7" is visible (trade count)
- Uptime text "1h" or similar is visible

**Edge Cases**:
- `uptime_seconds: 0` — Daily APR shows "--", uptime shows "0m"
- `realized_profit: '0'` — Profit shows "0"
- `realized_profit: nil` — Profit shows "0" (component uses `?? '0'` fallback)
- `current_price: nil` — Range visualizer renders with no dot marker (current price absent)
- Multiple bots — Each gets its own card; all render without collision

**Playwright Hints**:
- Selector: `[data-testid="bot-card-{id}"]` where `{id}` is the bot's integer id
- Selector: `[data-testid="status-badge"]`
- Selector: `[data-testid="range-visualizer"]`
- Wait for: skeletons gone — `expect(page.locator('[data-testid="bot-card-{id}"]')).toBeVisible()`
- Assertion: `expect(page.locator('[data-testid="status-badge"]')).toContainText('running')`
- Assertion: `expect(page.locator('[data-testid="bot-card-{id}"]')).toContainText('42.50')`

**Capybara pattern**:
```ruby
it 'shows the bot card with status, profit, and range' do
  visit '/bots'

  within("[data-testid='bot-card-#{bot.id}']") do
    expect(page).to have_content('ETHUSDT')
    expect(page).to have_selector("[data-testid='status-badge']", text: 'running')
    expect(page).to have_content('42.50')
    expect(page).to have_selector("[data-testid='range-visualizer']")
  end
end
```

---

### TC-002: Navigate to Bot Detail from Card

**Priority**: P0
**User Story**: US01 — Dashboard
**Acceptance Criteria**: AC-004 (navigation aspect)

**Preconditions**:
- Same bot as TC-001 seeded
- Bot `id` is known (e.g., let it be 1 for this example)

**Steps**:
1. Visit `/bots`
2. Wait for the bot card `[data-testid="bot-card-{id}"]` to be visible
3. Click anywhere within the bot card (the `CardActionArea` covers the entire card content area)
4. Wait for navigation to complete
5. Verify the current URL is `/bots/{id}`
6. Verify the Bot Detail page header contains "ETHUSDT"
7. Verify the status badge is present on the detail page

**Expected Result**:
- After clicking the card, the browser navigates to `/bots/{id}`
- No full-page reload (client-side navigation via React Router)
- Bot Detail page renders with the pair name "ETHUSDT" in the `<h5>` heading
- Status badge is present and shows "running"
- No error alert is displayed

**Edge Cases**:
- Clicking the floating "+" FAB button (bottom-right corner) navigates to `/bots/new` instead
- Clicking a paused bot card navigates to its detail page showing "paused" status
- Clicking a stopped bot card navigates to its detail page showing "stopped" status and a Delete button

**Playwright Hints**:
- Selector: `[data-testid="bot-card-{id}"]` — click anywhere inside the card
- Wait for: URL change — `await page.waitForURL(/\/bots\/\d+/)`
- Assertion: `expect(page).toHaveURL(/\/bots\/1/)`
- Assertion: `expect(page.locator('h5')).toContainText('ETHUSDT')`
- Note: The `CardActionArea` in `BotCard.tsx` handles `onClick={() => navigate('/bots/${bot.id}')}` — the whole card content is clickable

**Capybara pattern**:
```ruby
it 'navigates to the bot detail page when the card is clicked' do
  visit '/bots'

  find("[data-testid='bot-card-#{bot.id}']").click

  expect(page).to have_current_path("/bots/#{bot.id}")
  expect(page).to have_content('ETHUSDT')
  expect(page).to have_selector("[data-testid='status-badge']")
end
```

---

### TC-003: Dashboard Empty State

**Priority**: P1
**User Story**: US01 — Dashboard
**Acceptance Criteria**: AC-006

**Preconditions**:
- No `Bot` records in the database
- `ExchangeAccount` may exist (does not affect empty state rendering)
- Exchange client stubbed

**Steps**:
1. Visit `/bots`
2. Wait for loading to complete (skeletons disappear)
3. Verify the empty state container is displayed (`[data-testid="empty-state"]`)
4. Verify the heading "No bots yet" is visible
5. Verify the body text "Create your first grid trading bot to get started." is visible
6. Verify a "Create Bot" button is present (`[data-testid="empty-state-create-btn"]`)
7. Click the "Create Bot" button
8. Verify navigation to `/bots/new`

**Expected Result**:
- The empty state container is rendered instead of a bot card grid
- Text "No bots yet" is visible
- Text "Create your first grid trading bot to get started." is visible
- `[data-testid="empty-state-create-btn"]` button is visible and clickable
- Clicking it navigates to `/bots/new` (the Create Bot Wizard)
- No bot cards are rendered
- No error alert is shown

**Edge Cases**:
- API returns error (network failure): Error alert "Failed to load bots. Please check your connection." is shown; empty state is NOT shown
- After creating a bot via the wizard and being redirected to Bot Detail, navigating back to `/bots` shows the newly created card (not the empty state)

**Playwright Hints**:
- Selector: `[data-testid="empty-state"]`, `[data-testid="empty-state-create-btn"]`
- Wait for: `[data-testid="empty-state"]` to be visible (confirms page loaded and determined no bots exist)
- Assertion: `expect(page.locator('[data-testid="empty-state"]')).toBeVisible()`
- Assertion: `expect(page.locator('[data-testid="empty-state"]')).toContainText('No bots yet')`
- After click assertion: `expect(page).toHaveURL('/bots/new')`

**Capybara pattern**:
```ruby
it 'shows the empty state with a create bot link when no bots exist' do
  visit '/bots'

  expect(page).to have_selector("[data-testid='empty-state']")
  expect(page).to have_content('No bots yet')
  expect(page).to have_content('Create your first grid trading bot')

  find("[data-testid='empty-state-create-btn']").click

  expect(page).to have_current_path('/bots/new')
end
```
