# US02: App-Level Account Guard — Test Cases

**User Story:** As a user opening the app for the first time, I want to be automatically redirected to the setup page when no account exists, so that the app is usable without touching the terminal.

**Frontend URL:** `http://localhost:3000`
**Backend URL:** `http://localhost:4000`

---

## TC-015: Visiting any route with no account redirects to /setup

**Priority:** P0
**User Story:** US02 — App-Level Account Guard
**Acceptance Criteria:** AC-001

**Preconditions:**
- Both frontend and backend servers running
- `ExchangeAccount` table is empty
- Backend returns `404 { "setup_required": true }` for `GET /api/v1/exchange_account/current`

**Steps:**
1. Open browser and navigate to `http://localhost:3000/bots`
2. Wait for the page to finish loading (network idle)
3. Observe the current URL

**Expected Result:**
- Browser is redirected to `http://localhost:3000/setup`
- The setup page renders (not a blank page or error)
- The URL bar shows `/setup`

**Edge Cases:**
- Direct navigation to `/bots/new` should also redirect to `/setup`
- Direct navigation to `/bots/123` should also redirect to `/setup`
- Direct navigation to `/settings` should also redirect to `/setup`

**Playwright Hints:**
- Wait for: network idle after navigation
- Assertion: `expect(page).to have_current_path('/setup')`
- Selector: none needed (URL check only)

**Capybara Hints:**
- `visit '/bots'`
- `expect(page).to have_current_path('/setup')`

---

## TC-016: Visiting root path / with no account redirects to /setup

**Priority:** P0
**User Story:** US02 — App-Level Account Guard
**Acceptance Criteria:** AC-001

**Preconditions:**
- Both frontend and backend servers running
- `ExchangeAccount` table is empty

**Steps:**
1. Navigate to `http://localhost:3000/`
2. Wait for page to finish loading

**Expected Result:**
- Browser ends up at `/setup` (root redirects to `/bots` which is then guarded to `/setup`)
- Setup page content is visible

**Playwright Hints:**
- `await page.goto('http://localhost:3000/')`
- `await page.waitForURL('**/setup')`

**Capybara Hints:**
- `visit '/'`
- `expect(page).to have_current_path('/setup')`

---

## TC-017: Visiting /setup when no account does NOT cause a redirect loop

**Priority:** P0
**User Story:** US02 — App-Level Account Guard
**Acceptance Criteria:** AC-001 (no loop condition)

**Preconditions:**
- Both frontend and backend servers running
- `ExchangeAccount` table is empty

**Steps:**
1. Navigate directly to `http://localhost:3000/setup`
2. Wait for page to load
3. Verify the setup form renders
4. Check that the browser does NOT repeatedly redirect

**Expected Result:**
- Page stays at `/setup` — no redirect occurs
- Setup page form is visible (name field, environment select, API key, API secret, Test Connection button)
- No JavaScript console errors about redirect loops or maximum call stack

**Edge Cases:**
- `AccountGuard` must detect it is already on `/setup` and render children instead of redirecting

**Playwright Hints:**
- `await page.goto('http://localhost:3000/setup')`
- `expect(page.url()).toContain('/setup')` (not redirected away)
- `await expect(page.locator('[data-testid="setup-name"]')).toBeVisible()`

**Capybara Hints:**
- `visit '/setup'`
- `expect(page).to have_current_path('/setup')`
- `expect(page).to have_css('[data-testid="setup-name"]')`

---

## TC-018: Loading state shows spinner while account check is in progress

**Priority:** P1
**User Story:** US02 — App-Level Account Guard
**Acceptance Criteria:** AC-001 (loading state)

**Preconditions:**
- Both frontend and backend servers running
- Network can be throttled or the API response delayed (for manual test)

**Steps:**
1. Throttle network or add artificial delay to `GET /api/v1/exchange_account/current`
2. Navigate to `http://localhost:3000/bots`
3. Observe the page during the loading period

**Expected Result:**
- A loading spinner (`CircularProgress`) is visible while the account query is pending
- No content flash or broken layout during load
- After the response resolves, the spinner disappears and redirect (or content) appears

**Playwright Hints:**
- Use `page.route()` to delay the API response
- `await expect(page.locator('role=progressbar')).toBeVisible()` (MUI CircularProgress renders as role=progressbar)

**Capybara Hints:**
- Difficult to test reliably with Capybara; note as a manual-only test case
- Alternative: test the AccountGuard component in a React unit test with mocked loading state

---

## TC-019: After account creation, navigating to /bots works without redirect

**Priority:** P0
**User Story:** US02 — App-Level Account Guard
**Acceptance Criteria:** AC-001, AC-008

**Preconditions:**
- Both frontend and backend servers running
- One `ExchangeAccount` record exists
- Backend returns `200` with account data for `GET /api/v1/exchange_account/current`

**Steps:**
1. Navigate to `http://localhost:3000/bots`
2. Wait for page to load

**Expected Result:**
- Browser stays at `/bots`
- Dashboard content renders (either bot cards or empty state "No bots yet")
- No redirect to `/setup`

**Playwright Hints:**
- `await page.goto('http://localhost:3000/bots')`
- `expect(page.url()).toContain('/bots')` (not `/setup`)
- `await expect(page.locator('text=No bots yet').or(page.locator('[data-testid^="bot-card-"]'))).toBeVisible()`

**Capybara Hints:**
- `visit '/bots'`
- `expect(page).to have_current_path('/bots')`
- `expect(page).to have_content('No bots yet').or have_css('[data-testid^="bot-card-"]')`

---

## TC-020: After account creation, navigating to /settings works without redirect

**Priority:** P0
**User Story:** US02 — App-Level Account Guard
**Acceptance Criteria:** AC-001, AC-006

**Preconditions:**
- Both frontend and backend servers running
- One `ExchangeAccount` record exists

**Steps:**
1. Navigate to `http://localhost:3000/settings`
2. Wait for page to load

**Expected Result:**
- Browser stays at `/settings`
- Settings page content renders (account name, environment, masked API key hint)
- No redirect to `/setup`

**Playwright Hints:**
- `await page.goto('http://localhost:3000/settings')`
- `expect(page.url()).toContain('/settings')`
- `await expect(page.locator('[data-testid="settings-card"]')).toBeVisible()`

**Capybara Hints:**
- `visit '/settings'`
- `expect(page).to have_current_path('/settings')`
- `expect(page).to have_css('[data-testid="settings-card"]')`

---

## TC-021: Visiting /setup when account already exists redirects to /bots

**Priority:** P1
**User Story:** US02 — App-Level Account Guard

**Preconditions:**
- Both frontend and backend servers running
- One `ExchangeAccount` record exists (account already configured)

**Steps:**
1. Navigate to `http://localhost:3000/setup`
2. Wait for page to load

**Expected Result:**
- Browser is redirected away from `/setup` (since account already exists)
- Destination: `/bots` (dashboard)
- Setup form does NOT render

**Note:** This behavior depends on implementation. The `AccountGuard` as designed only redirects TO `/setup` when no account exists; it does not redirect AWAY from `/setup` when an account exists. The `/setup` route is outside the guard. Verify actual behavior with the implementation team — the guard may or may not redirect from `/setup` when an account is already present. Update expected result accordingly.

**Playwright Hints:**
- `await page.goto('http://localhost:3000/setup')`
- Document actual behavior (redirect or stay on /setup)

**Capybara Hints:**
- `visit '/setup'`
- Document whether `page.current_path` is `/setup` or `/bots` and adjust expectation
