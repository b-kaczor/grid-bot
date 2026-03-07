# US03: Setup Page and Settings Page — Test Cases

**User Story:** As a user, I want a setup form for first-time account creation and a settings page to update credentials, so that I can manage my Bybit connection entirely through the UI.

**Frontend URL:** `http://localhost:3000`
**Backend URL:** `http://localhost:4000`

---

## Setup Page Tests

---

## TC-022: Setup page renders all required form fields

**Priority:** P0
**User Story:** US03 — Setup Page
**Acceptance Criteria:** AC-002

**Preconditions:**
- Frontend and backend running
- `ExchangeAccount` table is empty
- Test Connection stub returns success

**Steps:**
1. Navigate to `http://localhost:3000/setup`
2. Observe the form elements on the page

**Expected Result:**
- Page heading or title indicates this is a setup/onboarding page
- Text field for account name is present (`data-testid="setup-name"`)
- Environment dropdown/select is present (`data-testid="setup-environment"`)
- Text field for API key is present (`data-testid="setup-api-key"`)
- Password field for API secret is present (`data-testid="setup-api-secret"`)
- "Test Connection" button is present (`data-testid="setup-test-btn"`)
- "Save" button is present (`data-testid="setup-save-btn"`)

**Playwright Hints:**
- `await expect(page.locator('[data-testid="setup-name"]')).toBeVisible()`
- `await expect(page.locator('[data-testid="setup-environment"]')).toBeVisible()`
- `await expect(page.locator('[data-testid="setup-api-key"]')).toBeVisible()`
- `await expect(page.locator('[data-testid="setup-api-secret"]')).toBeVisible()`
- `await expect(page.locator('[data-testid="setup-test-btn"]')).toBeVisible()`
- `await expect(page.locator('[data-testid="setup-save-btn"]')).toBeVisible()`

**Capybara Hints:**
- `expect(page).to have_css('[data-testid="setup-name"]')`
- `expect(page).to have_css('[data-testid="setup-environment"]')`
- `expect(page).to have_button('Test Connection')`
- `expect(page).to have_button('Save')`

---

## TC-023: Environment dropdown defaults to "demo" and offers testnet/demo/mainnet

**Priority:** P1
**User Story:** US03 — Setup Page
**Acceptance Criteria:** AC-010

**Preconditions:**
- Frontend and backend running
- `ExchangeAccount` table is empty

**Steps:**
1. Navigate to `http://localhost:3000/setup`
2. Observe the environment select/dropdown current value
3. Open the dropdown and inspect all available options

**Expected Result:**
- Default selected value is "demo"
- Available options include at minimum: "testnet", "demo", "mainnet"
- All three options are selectable

**Playwright Hints:**
- `await expect(page.locator('[data-testid="setup-environment"]')).toContainText('demo')`
- Open select, check for all three option labels

**Capybara Hints:**
- For MUI Select: `within('[data-testid="setup-environment"]') { expect(page).to have_content('demo') }`
- Click the select to open, then: `expect(page).to have_css('li', text: 'testnet')`

---

## TC-024: API secret field masks input (password type)

**Priority:** P1
**User Story:** US03 — Setup Page

**Preconditions:**
- Frontend running
- Navigate to `/setup`

**Steps:**
1. Navigate to `http://localhost:3000/setup`
2. Click on the API secret field (`data-testid="setup-api-secret"`)
3. Type "mysecretvalue"
4. Inspect the rendered characters in the field

**Expected Result:**
- Characters appear as dots/bullets (password masking), not as plain text
- The underlying input element has `type="password"`

**Playwright Hints:**
- `const input = page.locator('[data-testid="setup-api-secret"] input')`
- `await expect(input).toHaveAttribute('type', 'password')`

**Capybara Hints:**
- `find('[data-testid="setup-api-secret"] input')['type']` should equal `"password"`

---

## TC-025: Name field pre-fills with default value

**Priority:** P1
**User Story:** US03 — Setup Page

**Preconditions:**
- Frontend running
- Navigate to `/setup`

**Steps:**
1. Navigate to `http://localhost:3000/setup`
2. Observe the name field value without typing anything

**Expected Result:**
- Name field has a default value of "My Demo Account" (or similar default from the implementation)

**Playwright Hints:**
- `await expect(page.locator('[data-testid="setup-name"] input')).toHaveValue('My Demo Account')`

**Capybara Hints:**
- `expect(find('[data-testid="setup-name"] input').value).to eq('My Demo Account')`

---

## TC-026: Save button is disabled before Test Connection is run

**Priority:** P0
**User Story:** US03 — Setup Page
**Acceptance Criteria:** AC-003

**Preconditions:**
- Frontend running
- Navigate to `/setup`

**Steps:**
1. Navigate to `http://localhost:3000/setup`
2. Fill in name, API key, and API secret fields
3. Do NOT click "Test Connection"
4. Observe the state of the "Save" button

**Expected Result:**
- "Save" button is disabled (not clickable)
- Button appears visually disabled (greyed out or has `disabled` attribute)

**Playwright Hints:**
- `await expect(page.locator('[data-testid="setup-save-btn"]')).toBeDisabled()`

**Capybara Hints:**
- `expect(page).to have_button('Save', disabled: true)`
- OR: `expect(find('[data-testid="setup-save-btn"]')[:disabled]).to eq('true')`

---

## TC-027: Test Connection button — success shows success alert

**Priority:** P0
**User Story:** US03 — Setup Page
**Acceptance Criteria:** AC-003

**Preconditions:**
- Frontend and backend running
- `POST /api/v1/exchange_account/test` stub returns `{ "success": true, "balance": "25000.00 USDT" }`

**Steps:**
1. Navigate to `http://localhost:3000/setup`
2. Fill in the API key field (`data-testid="setup-api-key"`) with any non-empty value
3. Fill in the API secret field (`data-testid="setup-api-secret"`) with any non-empty value
4. Click the "Test Connection" button (`data-testid="setup-test-btn"`)
5. Wait for the response

**Expected Result:**
- A success alert/message appears (`data-testid="setup-test-result"`)
- Message indicates success, e.g., "Connection successful" or shows the balance ("25000.00 USDT")
- Alert uses a success color/style (green)
- "Save" button becomes enabled after successful test

**Playwright Hints:**
- `await page.locator('[data-testid="setup-api-key"] input').fill('testkey')`
- `await page.locator('[data-testid="setup-api-secret"] input').fill('testsecret')`
- `await page.locator('[data-testid="setup-test-btn"]').click()`
- `await expect(page.locator('[data-testid="setup-test-result"]')).toBeVisible()`
- `await expect(page.locator('[data-testid="setup-save-btn"]')).toBeEnabled()`

**Capybara Hints:**
- ```ruby
  find('[data-testid="setup-api-key"] input').fill_in(with: 'testkey')
  find('[data-testid="setup-api-secret"] input').fill_in(with: 'testsecret')
  click_button 'Test Connection'
  expect(page).to have_css('[data-testid="setup-test-result"]')
  expect(page).to have_button('Save', disabled: false)
  ```

---

## TC-028: Test Connection button — failure shows error alert

**Priority:** P0
**User Story:** US03 — Setup Page
**Acceptance Criteria:** AC-003

**Preconditions:**
- Frontend and backend running
- `POST /api/v1/exchange_account/test` stub returns `{ "success": false, "error": "Invalid API key" }`

**Steps:**
1. Navigate to `http://localhost:3000/setup`
2. Fill in the API key field with an invalid value (e.g., "BADKEY")
3. Fill in the API secret field with an invalid value (e.g., "BADSECRET")
4. Click the "Test Connection" button
5. Wait for the response

**Expected Result:**
- An error alert appears (`data-testid="setup-test-result"`)
- Message indicates failure, e.g., "Invalid API key" or "Connection failed"
- Alert uses an error color/style (red)
- "Save" button remains disabled

**Playwright Hints:**
- `await expect(page.locator('[data-testid="setup-test-result"]')).toContainText('Invalid API key')`
- `await expect(page.locator('[data-testid="setup-save-btn"]')).toBeDisabled()`

**Capybara Hints:**
- ```ruby
  click_button 'Test Connection'
  expect(page).to have_css('[data-testid="setup-test-result"]')
  expect(page).to have_content('Invalid API key')
  expect(page).to have_button('Save', disabled: true)
  ```

---

## TC-029: Test Connection can be re-run after failure to clear error

**Priority:** P1
**User Story:** US03 — Setup Page

**Preconditions:**
- Frontend and backend running
- First test call returns failure; second test call returns success

**Steps:**
1. Navigate to `/setup`, fill in bad credentials, click "Test Connection"
2. Observe error alert
3. Update API key/secret fields with valid values
4. Click "Test Connection" again
5. Observe result

**Expected Result:**
- Second test result replaces (or updates) the first result alert
- On second success: alert shows success, Save button becomes enabled

**Capybara Hints:**
- Test requires controlling stub responses across two calls; may need a sequence of stubs

---

## TC-030: Save button becomes enabled only after successful test

**Priority:** P0
**User Story:** US03 — Setup Page
**Acceptance Criteria:** AC-003

**Preconditions:**
- Frontend and backend running
- Test connection stub returns success

**Steps:**
1. Navigate to `/setup`
2. Verify Save button is disabled (no test run yet)
3. Fill in API key and secret fields
4. Click "Test Connection"
5. Wait for success result
6. Verify Save button state

**Expected Result:**
- Before test: Save button is disabled
- After failed test: Save button is disabled
- After successful test: Save button is enabled

**Capybara Hints:**
- `expect(page).to have_button('Save', disabled: true)` (before test)
- After successful test: `expect(page).to have_button('Save', disabled: false)`

---

## TC-031: Full happy path — setup creates account and redirects to /bots

**Priority:** P0
**User Story:** US03 — Setup Page
**Acceptance Criteria:** AC-002, AC-008

**Preconditions:**
- Frontend and backend running
- `ExchangeAccount` table is empty
- Test connection stub returns success
- Create account endpoint (`POST /api/v1/exchange_account`) works and returns 201

**Steps:**
1. Navigate to `http://localhost:3000/setup` (or `http://localhost:3000/` which redirects there)
2. Observe that the setup page is shown
3. Fill in the name field with "My Test Account" (`data-testid="setup-name"`)
4. Set environment to "demo" (`data-testid="setup-environment"`)
5. Fill in API key with "VALIDKEY1234567890ab" (`data-testid="setup-api-key"`)
6. Fill in API secret with "VALIDSECRET987654xyz" (`data-testid="setup-api-secret"`)
7. Click "Test Connection" (`data-testid="setup-test-btn"`)
8. Wait for success alert to appear
9. Click "Save" (`data-testid="setup-save-btn"`)
10. Wait for redirect

**Expected Result:**
- After clicking Save, browser navigates to `/bots`
- Dashboard is shown (empty state: "No bots yet" or "Create your first grid trading bot")
- `ExchangeAccount.count` in database is 1
- New account has correct name, environment, and encrypted credentials

**Playwright Hints:**
- `await page.waitForURL('**/bots')`
- `await expect(page.locator('text=No bots yet').or(page.locator('text=Create your first'))).toBeVisible()`

**Capybara Hints:**
- ```ruby
  visit '/setup'
  find('[data-testid="setup-name"] input').fill_in(with: 'My Test Account')
  # Set environment via MUI Select interaction
  find('[data-testid="setup-api-key"] input').fill_in(with: 'VALIDKEY1234567890ab')
  find('[data-testid="setup-api-secret"] input').fill_in(with: 'VALIDSECRET987654xyz')
  click_button 'Test Connection'
  expect(page).to have_css('[data-testid="setup-test-result"]')
  click_button 'Save'
  expect(page).to have_current_path('/bots')
  expect(page).to have_content(/no bots yet|create your first/i)
  expect(ExchangeAccount.count).to eq(1)
  ```

---

## TC-032: After setup, bot wizard is accessible and functional

**Priority:** P0
**User Story:** US03 — Setup Page
**Acceptance Criteria:** AC-008

**Preconditions:**
- Frontend and backend running
- One `ExchangeAccount` record exists (e.g., created via TC-031)

**Steps:**
1. Navigate to `http://localhost:3000/bots`
2. Click the "Create Bot" button (or navigate to `/bots/new`)
3. Verify step 1 of the wizard renders

**Expected Result:**
- Wizard renders at `/bots/new`
- Step 1 (pair selection) is visible (`data-testid="wizard-step-0"`)
- No redirect to `/setup` occurs

**Capybara Hints:**
- ```ruby
  visit '/bots/new'
  expect(page).to have_current_path('/bots/new')
  expect(page).to have_css('[data-testid="wizard-step-0"]')
  ```

---

## Settings Page Tests

---

## TC-033: Settings page view mode shows account info with masked key

**Priority:** P0
**User Story:** US03 — Settings Page
**Acceptance Criteria:** AC-006

**Preconditions:**
- Frontend and backend running
- One `ExchangeAccount` exists:
  - `name`: "My Demo Account"
  - `exchange`: "bybit"
  - `environment`: "demo"
  - `api_key`: "ABCDEF1234567890ab3f"

**Steps:**
1. Navigate to `http://localhost:3000/settings`
2. Observe the settings card content

**Expected Result:**
- Settings card is visible (`data-testid="settings-card"`)
- Account name "My Demo Account" is displayed
- Exchange "bybit" is displayed
- Environment "demo" is displayed
- Masked API key hint "••••••••ab3f" is displayed (not the full key)
- Full API key and API secret are NOT shown anywhere on the page
- "Edit" button is visible (`data-testid="settings-edit-btn"`)

**Playwright Hints:**
- `await expect(page.locator('[data-testid="settings-card"]')).toBeVisible()`
- `await expect(page.locator('[data-testid="settings-card"]')).toContainText('My Demo Account')`
- `await expect(page.locator('[data-testid="settings-card"]')).toContainText('••••••••ab3f')`
- `await expect(page.locator('[data-testid="settings-card"]')).not.toContainText('ABCDEF1234567890ab3f')`

**Capybara Hints:**
- ```ruby
  visit '/settings'
  within('[data-testid="settings-card"]') do
    expect(page).to have_content('My Demo Account')
    expect(page).to have_content('demo')
    expect(page).to have_content('ab3f')
    expect(page).not_to have_content('ABCDEF1234567890ab3f')
  end
  ```

---

## TC-034: Settings view mode shows correct environment value

**Priority:** P1
**User Story:** US03 — Settings Page
**Acceptance Criteria:** AC-010

**Preconditions:**
- Frontend and backend running
- `ExchangeAccount` with `environment`: "testnet"

**Steps:**
1. Navigate to `/settings`
2. Read the environment field in the view card

**Expected Result:**
- Environment "testnet" is displayed in the card
- No environment dropdown is shown (view mode, not edit mode)

**Capybara Hints:**
- `expect(page).to have_content('testnet')`

---

## TC-035: Clicking Edit button switches settings card to edit mode

**Priority:** P0
**User Story:** US03 — Settings Page
**Acceptance Criteria:** AC-007

**Preconditions:**
- Frontend and backend running
- One `ExchangeAccount` exists

**Steps:**
1. Navigate to `http://localhost:3000/settings`
2. Click the "Edit" button (`data-testid="settings-edit-btn"`)
3. Observe the card content

**Expected Result:**
- Edit mode form appears
- Name field is visible and editable (`data-testid="settings-name"`)
- Environment select is visible and editable (`data-testid="settings-environment"`)
- API key field is visible and blank (`data-testid="settings-api-key"`)
- API secret field is visible and blank (`data-testid="settings-api-secret"`)
- "Test Connection" button is visible (`data-testid="settings-test-btn"`)
- "Save" button is visible (`data-testid="settings-save-btn"`)
- "Cancel" button is visible (`data-testid="settings-cancel-btn"`)
- "Edit" button is no longer shown (mode switched)

**Playwright Hints:**
- `await page.locator('[data-testid="settings-edit-btn"]').click()`
- `await expect(page.locator('[data-testid="settings-name"]')).toBeVisible()`
- `await expect(page.locator('[data-testid="settings-api-key"] input')).toHaveValue('')`

**Capybara Hints:**
- ```ruby
  click_button 'Edit'
  expect(page).to have_css('[data-testid="settings-name"]')
  expect(page).to have_css('[data-testid="settings-api-key"]')
  expect(find('[data-testid="settings-api-key"] input').value).to be_empty
  ```

---

## TC-036: Edit mode API key/secret fields start blank with hint as placeholder

**Priority:** P1
**User Story:** US03 — Settings Page
**Acceptance Criteria:** AC-007

**Preconditions:**
- Frontend and backend running
- `ExchangeAccount` with `api_key` ending in "ab3f"

**Steps:**
1. Navigate to `/settings`
2. Click "Edit"
3. Observe the API key and API secret fields

**Expected Result:**
- API key input value is empty (`""`)
- API key input placeholder shows the hint (e.g., "••••••••ab3f" or "Current: ••••••••ab3f")
- API secret input value is empty
- If neither field is touched, they should NOT be sent in the PATCH request

**Playwright Hints:**
- `await expect(page.locator('[data-testid="settings-api-key"] input')).toHaveValue('')`
- `await expect(page.locator('[data-testid="settings-api-key"] input')).toHaveAttribute('placeholder', expect.stringContaining('ab3f'))`

**Capybara Hints:**
- `find('[data-testid="settings-api-key"] input').value` should be `""`

---

## TC-037: Cancel button in edit mode returns to view mode without saving

**Priority:** P1
**User Story:** US03 — Settings Page
**Acceptance Criteria:** AC-007

**Preconditions:**
- Frontend and backend running
- `ExchangeAccount` with `name`: "My Demo Account"

**Steps:**
1. Navigate to `/settings`
2. Click "Edit"
3. Change the name field to "Changed Name"
4. Click "Cancel" (`data-testid="settings-cancel-btn"`)
5. Observe the card state

**Expected Result:**
- Card returns to view mode
- Account name still shows "My Demo Account" (not "Changed Name")
- "Edit" button is visible again
- No PATCH request was sent to the backend
- Database record is unchanged

**Playwright Hints:**
- `await page.locator('[data-testid="settings-cancel-btn"]').click()`
- `await expect(page.locator('[data-testid="settings-card"]')).toContainText('My Demo Account')`
- `await expect(page.locator('[data-testid="settings-edit-btn"]')).toBeVisible()`

**Capybara Hints:**
- ```ruby
  click_button 'Edit'
  find('[data-testid="settings-name"] input').fill_in(with: 'Changed Name')
  click_button 'Cancel'
  within('[data-testid="settings-card"]') do
    expect(page).to have_content('My Demo Account')
    expect(page).not_to have_content('Changed Name')
  end
  expect(ExchangeAccount.first.reload.name).to eq('My Demo Account')
  ```

---

## TC-038: Settings edit mode — Save disabled before Test Connection when new keys entered

**Priority:** P0
**User Story:** US03 — Settings Page
**Acceptance Criteria:** AC-003, AC-007

**Preconditions:**
- Frontend and backend running
- One `ExchangeAccount` exists

**Steps:**
1. Navigate to `/settings`
2. Click "Edit"
3. Enter a new value in the API key field
4. Enter a new value in the API secret field
5. Do NOT click "Test Connection"
6. Observe the Save button state

**Expected Result:**
- Save button is disabled when new keys have been entered but test has not been run

**Note:** If only non-secret fields (name, environment) are changed and API key/secret remain blank, the Save button behavior may differ — it may be enabled without requiring a test. Verify with the implementation team and adjust expectation.

**Capybara Hints:**
- ```ruby
  click_button 'Edit'
  find('[data-testid="settings-api-key"] input').fill_in(with: 'NEWKEY')
  find('[data-testid="settings-api-secret"] input').fill_in(with: 'NEWSECRET')
  expect(page).to have_button('Save', disabled: true)
  ```

---

## TC-039: Settings full update — happy path with Test Connection and Save

**Priority:** P0
**User Story:** US03 — Settings Page
**Acceptance Criteria:** AC-007

**Preconditions:**
- Frontend and backend running
- `ExchangeAccount` with `name`: "Old Name", `environment`: "testnet"
- Test connection stub returns success
- PATCH endpoint returns 200

**Steps:**
1. Navigate to `http://localhost:3000/settings`
2. Click "Edit"
3. Clear and fill the name field with "Updated Name" (`data-testid="settings-name"`)
4. Change environment to "demo" (`data-testid="settings-environment"`)
5. Enter new API key "NEWKEY1234567890wxyz" (`data-testid="settings-api-key"`)
6. Enter new API secret "NEWSECRET987654pqr" (`data-testid="settings-api-secret"`)
7. Click "Test Connection" (`data-testid="settings-test-btn"`)
8. Wait for success result
9. Click "Save" (`data-testid="settings-save-btn"`)
10. Wait for the card to return to view mode

**Expected Result:**
- Card returns to view mode (no edit form visible)
- Shows "Updated Name" as the account name
- Shows "demo" as the environment
- Shows updated `api_key_hint` (last 4 chars of "NEWKEY1234567890wxyz" = "wxyz"): "••••••••wxyz"
- A success message is visible (e.g., "Settings saved" or similar)
- Database record updated: `name` = "Updated Name", `environment` = "demo", `api_key` = new value

**Playwright Hints:**
- `await expect(page.locator('[data-testid="settings-card"]')).toContainText('Updated Name')`
- `await expect(page.locator('[data-testid="settings-card"]')).toContainText('wxyz')`

**Capybara Hints:**
- ```ruby
  visit '/settings'
  click_button 'Edit'
  name_input = find('[data-testid="settings-name"] input')
  name_input.fill_in(with: '')
  name_input.fill_in(with: 'Updated Name')
  find('[data-testid="settings-api-key"] input').fill_in(with: 'NEWKEY1234567890wxyz')
  find('[data-testid="settings-api-secret"] input').fill_in(with: 'NEWSECRET987654pqr')
  click_button 'Test Connection'
  expect(page).to have_css('[data-testid^="settings-test"]')
  click_button 'Save'
  within('[data-testid="settings-card"]') do
    expect(page).to have_content('Updated Name')
    expect(page).to have_content('wxyz')
  end
  expect(ExchangeAccount.first.reload.name).to eq('Updated Name')
  ```

---

## TC-040: Settings partial update — name only without re-entering keys

**Priority:** P0
**User Story:** US03 — Settings Page
**Acceptance Criteria:** AC-007

**Preconditions:**
- Frontend and backend running
- `ExchangeAccount` with `name`: "Old Name", `api_key`: "ORIGINALKEY1234abcd"

**Steps:**
1. Navigate to `/settings`
2. Click "Edit"
3. Change the name field to "New Name"
4. Leave API key and API secret fields blank (do not type in them)
5. Click "Save" (should be enabled since no new keys were entered)
6. Wait for view mode to return

**Expected Result:**
- Settings card shows "New Name"
- `api_key_hint` still shows "abcd" at the end (original key unchanged)
- Database `api_key` is still "ORIGINALKEY1234abcd" (not overwritten)
- No "Test Connection" was required (only non-secret fields updated)

**Capybara Hints:**
- ```ruby
  click_button 'Edit'
  name_input = find('[data-testid="settings-name"] input')
  name_input.fill_in(with: '')
  name_input.fill_in(with: 'New Name')
  click_button 'Save'
  within('[data-testid="settings-card"]') do
    expect(page).to have_content('New Name')
    expect(page).to have_content('abcd')
  end
  expect(ExchangeAccount.first.reload.api_key).to eq('ORIGINALKEY1234abcd')
  ```

---

## TC-041: Settings edit — Test Connection failure keeps Save disabled

**Priority:** P0
**User Story:** US03 — Settings Page
**Acceptance Criteria:** AC-003, AC-007

**Preconditions:**
- Frontend and backend running
- One `ExchangeAccount` exists
- Test connection stub returns `{ "success": false, "error": "Invalid API key" }`

**Steps:**
1. Navigate to `/settings`
2. Click "Edit"
3. Enter new API key and API secret values
4. Click "Test Connection"
5. Wait for error result
6. Observe Save button state

**Expected Result:**
- Error alert appears indicating the test failed
- Save button remains disabled
- Account data is NOT modified in the database

**Capybara Hints:**
- ```ruby
  click_button 'Edit'
  find('[data-testid="settings-api-key"] input').fill_in(with: 'BADKEY')
  find('[data-testid="settings-api-secret"] input').fill_in(with: 'BADSECRET')
  click_button 'Test Connection'
  expect(page).to have_button('Save', disabled: true)
  ```

---

## TC-042: Settings edit — Test Connection result shows balance on success

**Priority:** P1
**User Story:** US03 — Settings Page

**Preconditions:**
- Frontend and backend running
- One `ExchangeAccount` exists
- Test connection stub returns `{ "success": true, "balance": "25000.00 USDT" }`

**Steps:**
1. Navigate to `/settings`
2. Click "Edit"
3. Enter any API key and secret values
4. Click "Test Connection"
5. Observe the result area

**Expected Result:**
- Success alert visible
- Balance "25000.00 USDT" is shown in the alert or nearby

**Capybara Hints:**
- `expect(page).to have_content('25000.00 USDT')`

---

## Navigation Tests

---

## TC-043: Settings icon in navigation header is visible and navigates to /settings

**Priority:** P1
**User Story:** US03 — Settings Page
**Acceptance Criteria:** AC-009

**Preconditions:**
- Frontend and backend running
- One `ExchangeAccount` exists (so guard allows navigation)

**Steps:**
1. Navigate to `http://localhost:3000/bots`
2. Locate the settings icon in the app header/toolbar
3. Click the settings icon (`data-testid="nav-settings"`)
4. Wait for navigation

**Expected Result:**
- A settings icon (gear/cog) is visible in the top navigation bar
- After clicking, browser navigates to `/settings`
- Settings page renders correctly

**Playwright Hints:**
- `await expect(page.locator('[data-testid="nav-settings"]')).toBeVisible()`
- `await page.locator('[data-testid="nav-settings"]').click()`
- `await expect(page).toHaveURL('**/settings')`

**Capybara Hints:**
- ```ruby
  visit '/bots'
  find('[data-testid="nav-settings"]').click
  expect(page).to have_current_path('/settings')
  expect(page).to have_css('[data-testid="settings-card"]')
  ```

---

## TC-044: Full first-time user flow — setup to dashboard to settings

**Priority:** P0
**User Story:** US03 — Integration
**Acceptance Criteria:** AC-001, AC-002, AC-003, AC-008, AC-009

**Preconditions:**
- Frontend and backend running
- `ExchangeAccount` table is empty
- Test connection stub returns success
- Exchange client stub active for bot dashboard

**Steps:**
1. Navigate to `http://localhost:3000/` (root)
2. Verify redirect to `/setup`
3. Fill in setup form:
   - Name: "Demo Account"
   - Environment: "demo"
   - API key: any non-empty value
   - API secret: any non-empty value
4. Click "Test Connection", wait for success
5. Click "Save", wait for redirect
6. Verify landing on `/bots` (dashboard)
7. Verify empty state or bot list is shown
8. Click the Settings icon in the navigation
9. Verify navigation to `/settings`
10. Verify account name "Demo Account" is shown in settings card

**Expected Result:**
- Step 2: Current path is `/setup`
- Step 5: After Save, path becomes `/bots`
- Step 6: Dashboard content visible (no redirect back to `/setup`)
- Step 8: Settings icon click navigates to `/settings`
- Step 10: Settings card shows "Demo Account" and environment "demo"

**Playwright Hints:**
- This is an integration test spanning multiple pages; use `page.waitForURL()` between navigation steps

**Capybara Hints:**
- ```ruby
  visit '/'
  expect(page).to have_current_path('/setup')

  find('[data-testid="setup-name"] input').fill_in(with: 'Demo Account')
  find('[data-testid="setup-api-key"] input').fill_in(with: 'key123')
  find('[data-testid="setup-api-secret"] input').fill_in(with: 'secret456')
  click_button 'Test Connection'
  expect(page).to have_css('[data-testid="setup-test-result"]')
  click_button 'Save'

  expect(page).to have_current_path('/bots')

  find('[data-testid="nav-settings"]').click
  expect(page).to have_current_path('/settings')
  within('[data-testid="settings-card"]') do
    expect(page).to have_content('Demo Account')
    expect(page).to have_content('demo')
  end
  ```
