# US03 — Create Bot Wizard Test Cases

**User Story**: As a bot operator, I can use the Create Bot Wizard to configure and launch a new grid trading bot in three guided steps.

**Spec file**: `spec/features/create_bot_wizard_spec.rb`
**Scenarios**: 4
**Test cases**: TC-010, TC-011, TC-012, TC-013

---

## Shared Preconditions

- Rails API running
- React frontend built with `VITE_TEST_MODE=1`
- `Bybit::RestClient` stubbed to return:
  - Exchange pairs: ETHUSDT (`last_price: '2500.00'`, `tick_size: '0.01'`, `base_coin: 'ETH'`, `quote_coin: 'USDT'`) and BTCUSDT (`last_price: '45000.00'`)
  - Wallet balance: USDT coin with `available: '10000.00'`
- `MockRedis` injected
- DatabaseCleaner truncation active
- One `ExchangeAccount` seeded

---

### TC-010: Step 1 — Pair Selection

**Priority**: P0
**User Story**: US03 — Create Bot Wizard
**Acceptance Criteria**: AC-011

**Preconditions**:
- Shared preconditions above

**Steps**:
1. Visit `/bots/new`
2. Verify the wizard renders with the "Create Bot" heading
3. Verify the stepper shows three steps: "Select Pair", "Set Parameters", "Investment"
4. Verify "Select Pair" is the active step
5. Verify the `[data-testid="wizard-step-0"]` container is visible
6. Verify the instructional text "Search and select a trading pair to begin." is present
7. Verify the "Back" button (`[data-testid="wizard-back-btn"]`) is disabled
8. Verify the "Next" button (`[data-testid="wizard-next-btn"]`) is disabled (no pair selected)
9. Click the pair Autocomplete input (`[data-testid="pair-select"] input`)
10. Type "ETH" in the input
11. Wait for the dropdown listbox (`[role="listbox"]`) to appear
12. Verify "ETHUSDT" with last price "2500.00" is shown in the dropdown
13. Click on the "ETHUSDT" option
14. Verify the Autocomplete input displays "ETHUSDT"
15. Verify the "Next" button becomes enabled

**Expected Result**:
- Page renders at `/bots/new` with step 1 active
- Stepper labels "Select Pair", "Set Parameters", "Investment" are all visible
- "Back" button is disabled on step 1
- "Next" button is disabled until a pair is selected
- Autocomplete shows matching pairs as dropdown options when typing
- Each option shows the pair symbol and its last price
- After selecting ETHUSDT: Autocomplete shows "ETHUSDT"; Next button is enabled

**Edge Cases**:
- Typing a non-existent symbol (e.g., "XYZABC"): dropdown shows "No options"
- Clearing the selected pair (clicking the clear icon in Autocomplete): "Next" becomes disabled again
- Exchange pairs API fails to load: Autocomplete shows no options (loading skeleton shown first)
- Selecting BTCUSDT instead: input shows "BTCUSDT"; moving to step 2 pre-populates BTC defaults

**Playwright Hints**:
- Selector: `[data-testid="pair-select"] input` — the actual `<input>` element inside MUI Autocomplete
- Selector: `[data-testid="wizard-next-btn"]`, `[data-testid="wizard-back-btn"]`
- Wait for dropdown: `await page.waitForSelector('[role="listbox"]')`
- Click option: `await page.locator('[role="option"]:has-text("ETHUSDT")').click()`
- Assertion: `expect(page.locator('[data-testid="wizard-next-btn"]')).toBeEnabled()`
- Assertion: `expect(page.locator('[data-testid="wizard-next-btn"]')).toBeDisabled()` (before selection)
- Note: MUI Autocomplete renders the dropdown as a `[role="listbox"]` portal appended to `<body>`, not inside the component DOM

**Capybara pattern**:
```ruby
it 'enables Next only after a pair is selected' do
  visit '/bots/new'

  expect(page).to have_selector("[data-testid='wizard-step-1']")
  expect(find("[data-testid='wizard-next-btn']")[:disabled]).to eq('true')

  find("[data-testid='pair-select'] input").fill_in with: 'ETH'
  find('[role="option"]', text: 'ETHUSDT').click

  expect(find("[data-testid='wizard-next-btn']")[:disabled]).to be_nil
end
```

---

### TC-011: Step 2 — Parameters Entry and Validation

**Priority**: P0
**User Story**: US03 — Create Bot Wizard
**Acceptance Criteria**: AC-011

**Preconditions**:
- ETHUSDT is pre-selected (arrive at step 2 via completing step 1)
- `computeDefaults('2500.00')` pre-fills lower and upper price defaults

**Steps**:
1. Complete step 1: select ETHUSDT, click "Next"
2. Verify the wizard is now on step 2 (`[data-testid="wizard-step-1"]` visible)
3. Verify the pair summary "ETHUSDT — Last price: 2500.00" is displayed
4. Verify the lower price input (`[data-testid="input-lower-price"]`) is pre-filled with a default value
5. Verify the upper price input (`[data-testid="input-upper-price"]`) is pre-filled with a default value
6. Verify the grid count slider (`[data-testid="input-grid-count"]`) defaults to 20 (label "Grid Count: 20")
7. Clear the lower price input and type "2500.00" (same as upper price default)
8. Clear the upper price input and type "2500.00"
9. Verify a validation error appears on the upper price field (e.g., "Upper must be greater than lower")
10. Verify the "Next" button is disabled
11. Clear the upper price input and type "3000.00"
12. Verify the validation error disappears from the upper price field
13. Verify the "Live Preview" card shows a non-zero "Grid step size"
14. Verify the "Live Preview" card shows a non-zero "Profit per grid" percentage
15. Verify the "Next" button is enabled
16. Click "Next" to advance to step 3

**Expected Result**:
- Step 2 renders with pair context "ETHUSDT — Last price: 2500.00"
- Lower and upper price inputs are pre-filled by `computeDefaults`
- Grid count slider defaults to 20
- With invalid params (upper <= lower): validation error shown; "Next" disabled
- With valid params (lower `'2000.00'`, upper `'3000.00'`, grid count 20): no errors; Live Preview shows step size and profit %
- Clicking "Next" advances to step 3

**Edge Cases**:
- Lower price `"0"`: validation error "Lower price must be positive" on lower price field
- Lower price negative: validation error
- Upper price exactly equal to lower: validation error "Upper must be greater than lower"
- Grid count adjusted to 2 (minimum via slider): Live Preview recalculates
- Grid count adjusted to 200 (maximum via slider): Live Preview recalculates
- Switching spacing to "Geometric": toggle button highlights "Geometric"
- Setting stop-loss above upper price: validation error on stop-loss field
- Setting take-profit below lower price: validation error on take-profit field
- Clicking "Back" from step 2: returns to step 1 with the previously selected pair still shown

**Playwright Hints**:
- Selector: `[data-testid="wizard-step-1"]`
- Selector: `[data-testid="input-lower-price"]`, `[data-testid="input-upper-price"]`
- Selector: `[data-testid="input-grid-count"]` (slider — may require `.fill()` or drag interaction)
- Validation error: find the helper text sibling of the MUI TextField — `page.locator('[data-testid="input-upper-price"]').locator('..').locator('p.MuiFormHelperText-root')` or use `toContainText` on the containing form control
- Assertion: `expect(page.locator('[data-testid="wizard-next-btn"]')).toBeDisabled()` (invalid state)
- Assertion: `expect(page.locator('[data-testid="wizard-next-btn"]')).toBeEnabled()` (valid state)
- Live Preview assertion: `expect(page.locator('text=Profit per grid')).toBeVisible()`

**Capybara pattern**:
```ruby
it 'shows validation errors for invalid parameters and enables Next for valid ones' do
  # Assume step 1 completed in a `before` block
  visit "/bots/new"
  # ... complete step 1 ...
  find("[data-testid='wizard-next-btn']").click

  expect(page).to have_selector("[data-testid='wizard-step-1']")

  fill_in_by_testid('input-lower-price', with: '2500.00')
  fill_in_by_testid('input-upper-price', with: '2500.00')

  expect(find("[data-testid='wizard-next-btn']")[:disabled]).to eq('true')
  expect(page).to have_content('Upper must be greater')

  fill_in_by_testid('input-upper-price', with: '3000.00')

  expect(find("[data-testid='wizard-next-btn']")[:disabled]).to be_nil
  expect(page).to have_content('Profit per grid')
end
```

---

### TC-012: Step 3 — Investment Summary and Slider

**Priority**: P0
**User Story**: US03 — Create Bot Wizard
**Acceptance Criteria**: AC-012 (step 3 aspect)

**Preconditions**:
- Steps 1 and 2 completed: ETHUSDT selected, lower `'2000.00'`, upper `'3000.00'`, grid count 20
- Exchange client stub returns wallet balance: USDT `available: '10000.00'`

**Steps**:
1. Complete steps 1 and 2, click "Next" to reach step 3
2. Verify the wizard is on step 3 (`[data-testid="wizard-step-2"]` visible)
3. Verify "Available USDT: 10000.00" text is displayed
4. Verify the investment slider (`[data-testid="input-investment-pct"]`) is present
5. Verify the investment label reads "Investment: 50% (5000.00 USDT)" (default is 50%)
6. Verify the Order Summary card (`[data-testid="order-summary"]`) is visible
7. Verify the Order Summary contains: "ETHUSDT", "2000.00 — 3000.00", "20", "Arithmetic", "5000.00 USDT"
8. Move the investment slider to approximately 80%:
   - Use Playwright: set slider value via JavaScript evaluation or keyboard arrow keys
9. Verify the investment label updates to "Investment: 80% (8000.00 USDT)"
10. Verify the Order Summary "Total Investment" updates to "8000.00 USDT"
11. Verify the "Create Bot" button (`[data-testid="wizard-submit-btn"]`) is visible and enabled
12. Verify the "Back" button is enabled

**Expected Result**:
- Step 3 container is visible
- Available USDT balance is shown (pulled from exchange stub)
- Investment slider defaults to 50%
- Slider interaction recalculates investment amount in real time
- Order Summary shows all values from steps 1 and 2
- "Create Bot" button is enabled and ready to submit
- "Back" button returns to step 2 without losing the pair or parameter choices

**Edge Cases**:
- Exchange balance API fails: error alert "Failed to load balance. Please try again." is shown; slider is not rendered
- USDT balance `'0.00'`: investment amount stays 0 regardless of slider; Qty per Level shows "—"
- Slider at 10% (minimum): label shows "Investment: 10% (1000.00 USDT)"
- Slider at 100% (maximum): label shows "Investment: 100% (10000.00 USDT)"
- Geometric spacing selected in step 2: Order Summary "Spacing" shows "Geometric"
- Stop-loss and take-profit set in step 2: they are not shown in the Order Summary (summary only shows range, grid count, spacing, investment)

**Playwright Hints**:
- Selector: `[data-testid="wizard-step-2"]`, `[data-testid="order-summary"]`, `[data-testid="wizard-submit-btn"]`
- Slider interaction options:
  1. JavaScript: `page.evaluate('document.querySelector("[data-testid=input-investment-pct]").value = 80')` then trigger change event
  2. Keyboard: focus the slider element, press ArrowRight multiple times
  3. Mouse drag: calculate slider track width and drag proportionally
- Assertion: `expect(page.locator('[data-testid="order-summary"]')).toContainText('ETHUSDT')`
- Assertion: `expect(page.locator('[data-testid="order-summary"]')).toContainText('5000.00 USDT')`
- Assertion: `expect(page.locator('[data-testid="wizard-submit-btn"]')).toBeEnabled()`

**Capybara pattern**:
```ruby
it 'shows the order summary with correct values from previous steps' do
  # Assume steps 1 and 2 completed in `before` block
  # ... navigate to step 3 ...

  expect(page).to have_selector("[data-testid='wizard-step-2']")
  expect(page).to have_content('Available USDT: 10000.00')

  within("[data-testid='order-summary']") do
    expect(page).to have_content('ETHUSDT')
    expect(page).to have_content('2000.00')
    expect(page).to have_content('3000.00')
    expect(page).to have_content('20')
    expect(page).to have_content('5000.00 USDT')
  end

  expect(page).to have_selector("[data-testid='wizard-submit-btn']")
end
```

---

### TC-013: Full Happy Path — Bot Creation and Redirect

**Priority**: P0
**User Story**: US03 — Create Bot Wizard
**Acceptance Criteria**: AC-012

**Preconditions**:
- Exchange client stub as described in shared preconditions
- The `POST /api/v1/bots` endpoint inserts a real bot record in the test DB (no stub needed; use real DB insert)
- Sidekiq jobs are stubbed inline or disabled so that bot initialization does not fail the test
- `ExchangeAccount` seeded

**Steps**:
1. Visit `/bots/new`
2. Step 1: Type "ETH" in the pair Autocomplete, select "ETHUSDT", click "Next"
3. Step 2: Verify pre-filled defaults are reasonable (lower < upper); click "Next" without changing values
4. Step 3: Verify the Order Summary shows ETHUSDT and a non-zero investment amount
5. Click the "Create Bot" button (`[data-testid="wizard-submit-btn"]`)
6. Verify the button shows a loading spinner while the request is in-flight
7. Wait for the redirect to complete
8. Verify the URL changed to `/bots/{new-id}` (matching `/bots/\d+`)
9. Verify the Bot Detail page header contains "ETHUSDT"
10. Verify a status badge is present (showing "pending" or "initializing" as initial status)
11. Verify no error alert is displayed on the detail page

**Expected Result**:
- All three wizard steps complete without validation errors
- "Create Bot" button triggers `POST /api/v1/bots`
- Loading spinner appears on the button while pending
- On success: React Router navigates to `/bots/{id}` (as in `CreateBotWizard.tsx` line 92: `navigate('/bots/${botId}')`)
- Bot Detail page renders with "ETHUSDT" in the `<h5>` heading
- Status badge shows the initial status ("pending" or "initializing")
- No error alert is shown on the detail page

**Edge Cases**:
- `POST /api/v1/bots` returns an API error: error alert "Failed to create bot. Please try again." shown above the stepper on step 3; wizard stays open; user can retry
- API returns a bot with no `id`: `navigate('/bots')` is called (dashboard fallback — see `CreateBotWizard.tsx` line 92)
- Bot immediately transitions to "initializing" while the page loads: spinner + "Setting up your bot..." message shown instead of stats grid (see `BotDetail.tsx` `isInitializing` branch)
- Clicking "Back" from step 3 to step 2 and re-clicking "Next" and "Create Bot": wizard submits with the most recent values

**Playwright Hints**:
- Wait for submission: `await page.locator('[data-testid="wizard-submit-btn"]').click()`
- Wait for redirect: `await page.waitForURL(/\/bots\/\d+/)`
- Assertion: `expect(page).toHaveURL(/\/bots\/\d+/)`
- Assertion: `expect(page.locator('h5')).toContainText('ETHUSDT')`
- Note: The pair heading in `BotDetail.tsx` uses `<Typography variant="h5">{bot.pair}</Typography>` — always rendered regardless of `isInitializing`
- Spinner on button: `expect(page.locator('[data-testid="wizard-submit-btn"] svg')).toBeVisible()` during pending (optional assertion)

**Capybara pattern**:
```ruby
it 'creates a bot and redirects to the bot detail page' do
  visit '/bots/new'

  # Step 1: select pair
  find("[data-testid='pair-select'] input").fill_in with: 'ETH'
  find('[role="option"]', text: 'ETHUSDT').click
  find("[data-testid='wizard-next-btn']").click

  # Step 2: accept defaults
  find("[data-testid='wizard-next-btn']").click

  # Step 3: confirm and submit
  expect(page).to have_selector("[data-testid='order-summary']")
  find("[data-testid='wizard-submit-btn']").click

  # Verify redirect to bot detail
  expect(page).to have_current_path(/\/bots\/\d+/)
  expect(page).to have_content('ETHUSDT')
  expect(page).to have_selector("[data-testid='status-badge']")
end
```
