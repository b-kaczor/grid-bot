# US01: Backend Account Management API — Test Cases

**User Story:** As a developer integrating the frontend, I want a RESTful API for managing the single ExchangeAccount, so that credentials can be created, viewed, updated, and tested without touching rails console.

**Base URL:** `http://localhost:4000/api/v1`

**Content-Type:** `application/json` for all requests

---

## TC-001: GET current — account exists returns 200 with masked key

**Priority:** P0
**User Story:** US01 — Backend Account Management API
**Acceptance Criteria:** AC-004, AC-006

**Preconditions:**
- Rails server running at localhost:4000
- One `ExchangeAccount` record exists in the database with:
  - `name`: "My Demo Account"
  - `exchange`: "bybit"
  - `environment`: "demo"
  - `api_key`: "ABCDEFGH12345678ab3f" (any 20-char string ending in "ab3f")
  - `api_secret`: "supersecretvalue"

**Steps:**
1. Send `GET http://localhost:4000/api/v1/exchange_account/current`
2. Check response status code
3. Parse response JSON body
4. Inspect all fields in the response

**Expected Result:**
- Status: `200 OK`
- Response body:
  ```json
  {
    "account": {
      "id": <integer>,
      "name": "My Demo Account",
      "exchange": "bybit",
      "environment": "demo",
      "api_key_hint": "••••••••ab3f",
      "created_at": "<ISO8601 timestamp>",
      "updated_at": "<ISO8601 timestamp>"
    }
  }
  ```
- `api_key_hint` shows exactly 8 bullet characters (`••••••••`) followed by the last 4 characters of the api_key
- The response body does NOT contain the key `"api_key"`
- The response body does NOT contain the key `"api_secret"`
- The response body does NOT contain the raw API key value anywhere

**Edge Cases:**
- `api_key` 4 chars long: hint should be `••••••••` + all 4 chars (total 12 chars visible)
- `api_key` exactly 4 chars: hint shows all 4 chars with 8 bullet prefix

**Capybara Hints:**
- Use `expect(response_body).not_to include('api_key')` (checking the raw JSON string)
- Use `expect(response_body).not_to include('api_secret')`
- Use `expect(json['account']['api_key_hint']).to match(/\A•{8}.{4}\z/)`

---

## TC-002: GET current — no account returns 404 with setup_required

**Priority:** P0
**User Story:** US01 — Backend Account Management API
**Acceptance Criteria:** AC-001

**Preconditions:**
- Rails server running at localhost:4000
- `ExchangeAccount` table is empty (no records)

**Steps:**
1. Send `GET http://localhost:4000/api/v1/exchange_account/current`
2. Check response status code
3. Parse response JSON body

**Expected Result:**
- Status: `404 Not Found`
- Response body:
  ```json
  {
    "setup_required": true
  }
  ```
- No `"account"` key present in the response

**Edge Cases:**
- Sending request with Accept header `application/json` should still return JSON (not HTML error page)

**Capybara Hints:**
- `expect(response).to have_http_status(404)`
- `expect(json['setup_required']).to be true`
- `expect(json).not_to have_key('account')`

---

## TC-003: POST create — creates account with valid params

**Priority:** P0
**User Story:** US01 — Backend Account Management API
**Acceptance Criteria:** AC-002

**Preconditions:**
- Rails server running at localhost:4000
- `ExchangeAccount` table is empty

**Steps:**
1. Send `POST http://localhost:4000/api/v1/exchange_account` with body:
   ```json
   {
     "exchange_account": {
       "name": "Test Account",
       "exchange": "bybit",
       "environment": "demo",
       "api_key": "TESTKEY1234567890abc",
       "api_secret": "TESTSECRET987654321xyz"
     }
   }
   ```
2. Check response status code
3. Parse response JSON body
4. Query the database to verify persistence

**Expected Result:**
- Status: `201 Created`
- Response body contains `"account"` with:
  - `name`: "Test Account"
  - `exchange`: "bybit"
  - `environment`: "demo"
  - `api_key_hint`: "••••••••0abc" (last 4 chars of "TESTKEY1234567890abc")
  - Numeric `id`
  - `created_at` and `updated_at` timestamps
- `ExchangeAccount.count` in database is 1
- Stored `api_key` matches "TESTKEY1234567890abc"
- Stored `api_secret` matches "TESTSECRET987654321xyz"
- Response does NOT contain `"api_key"` or `"api_secret"` keys

**Edge Cases:**
- `exchange` field not provided: should default or accept without it (or return 422 if required)
- Extra fields in params (e.g., `"id": 99`): should be ignored (strong parameters)

**Capybara Hints:**
- `expect(response).to have_http_status(201)`
- `expect(ExchangeAccount.count).to eq(1)`
- `expect(ExchangeAccount.first.api_key).to eq('TESTKEY1234567890abc')`

---

## TC-004: POST create — response never exposes api_key or api_secret

**Priority:** P0
**User Story:** US01 — Backend Account Management API
**Acceptance Criteria:** AC-004

**Preconditions:**
- Rails server running at localhost:4000
- `ExchangeAccount` table is empty

**Steps:**
1. Send `POST http://localhost:4000/api/v1/exchange_account` with valid body (same as TC-003)
2. Capture the raw response body as a string
3. Search the raw string for the literal API key value ("TESTKEY1234567890abc")
4. Search the raw string for the key name "api_key"
5. Search the raw string for the key name "api_secret"
6. Search the raw string for the secret value ("TESTSECRET987654321xyz")

**Expected Result:**
- Raw response body does NOT contain "TESTKEY1234567890abc"
- Raw response body does NOT contain "api_key" as a JSON key
- Raw response body does NOT contain "api_secret" as a JSON key
- Raw response body does NOT contain "TESTSECRET987654321xyz"

**Capybara Hints:**
- `raw_body = response.body`
- `expect(raw_body).not_to include('TESTKEY1234567890abc')`
- `expect(raw_body).not_to include('"api_key"')`
- `expect(raw_body).not_to include('"api_secret"')`

---

## TC-005: POST create — 422 when account already exists

**Priority:** P0
**User Story:** US01 — Backend Account Management API

**Preconditions:**
- Rails server running at localhost:4000
- One `ExchangeAccount` record already exists

**Steps:**
1. Send `POST http://localhost:4000/api/v1/exchange_account` with valid body
2. Check response status code
3. Parse response JSON body

**Expected Result:**
- Status: `422 Unprocessable Entity`
- Response body:
  ```json
  {
    "error": "Account already exists. Use PATCH to update."
  }
  ```
- `ExchangeAccount.count` remains 1 (no duplicate created)

**Capybara Hints:**
- `expect(response).to have_http_status(422)`
- `expect(json['error']).to include('already exists')`
- `expect(ExchangeAccount.count).to eq(1)`

---

## TC-006: POST create — 422 with missing required params

**Priority:** P1
**User Story:** US01 — Backend Account Management API

**Preconditions:**
- Rails server running at localhost:4000
- `ExchangeAccount` table is empty

**Steps:**
1. Send `POST http://localhost:4000/api/v1/exchange_account` with body missing `api_key`:
   ```json
   {
     "exchange_account": {
       "name": "Test Account",
       "environment": "demo"
     }
   }
   ```
2. Check response status code

**Expected Result:**
- Status: `422 Unprocessable Entity` (model validation failure)
- Response body contains an error message describing the missing field
- No account record created in the database

**Capybara Hints:**
- `expect(response).to have_http_status(422)`
- `expect(ExchangeAccount.count).to eq(0)`

---

## TC-007: PATCH current — updates account fields

**Priority:** P0
**User Story:** US01 — Backend Account Management API
**Acceptance Criteria:** AC-007

**Preconditions:**
- Rails server running at localhost:4000
- One `ExchangeAccount` exists with `name`: "Old Name", `environment`: "testnet"

**Steps:**
1. Send `PATCH http://localhost:4000/api/v1/exchange_account/current` with body:
   ```json
   {
     "exchange_account": {
       "name": "Updated Name",
       "environment": "demo",
       "api_key": "NEWKEY1234567890wxyz",
       "api_secret": "NEWSECRET987654321pqr"
     }
   }
   ```
2. Check response status code
3. Parse response JSON body
4. Verify database record updated

**Expected Result:**
- Status: `200 OK`
- Response `account.name` is "Updated Name"
- Response `account.environment` is "demo"
- Response `account.api_key_hint` reflects last 4 chars of new key ("wxyz"): `"••••••••wxyz"`
- Response does NOT contain `"api_key"` or `"api_secret"` keys
- Database record has updated `name`, `environment`, `api_key`, `api_secret`

**Capybara Hints:**
- `expect(response).to have_http_status(200)`
- `expect(json['account']['name']).to eq('Updated Name')`
- `expect(ExchangeAccount.first.reload.name).to eq('Updated Name')`

---

## TC-008: PATCH current — partial update leaves secrets unchanged

**Priority:** P0
**User Story:** US01 — Backend Account Management API
**Acceptance Criteria:** AC-007

**Preconditions:**
- Rails server running at localhost:4000
- One `ExchangeAccount` exists with `api_key`: "ORIGINALKEY1234abcd", `name`: "My Account"

**Steps:**
1. Send `PATCH http://localhost:4000/api/v1/exchange_account/current` with body containing ONLY name:
   ```json
   {
     "exchange_account": {
       "name": "Renamed Account"
     }
   }
   ```
2. Check response status code
3. Query the database for the existing account

**Expected Result:**
- Status: `200 OK`
- Response `account.name` is "Renamed Account"
- Response `account.api_key_hint` still reflects the original key ("abcd"): `"••••••••abcd"`
- Database record: `api_key` is still "ORIGINALKEY1234abcd" (not overwritten with nil or empty)
- Database record: `api_secret` is unchanged

**Edge Cases:**
- Sending `api_key: ""` (empty string) in the PATCH body: behavior should be defined — either ignore empty strings or return validation error. Document the actual behavior.

**Capybara Hints:**
- `expect(ExchangeAccount.first.reload.api_key).to eq('ORIGINALKEY1234abcd')`
- `expect(json['account']['api_key_hint']).to match(/abcd\z/)`

---

## TC-009: PATCH current — 404 when no account exists

**Priority:** P0
**User Story:** US01 — Backend Account Management API

**Preconditions:**
- Rails server running at localhost:4000
- `ExchangeAccount` table is empty

**Steps:**
1. Send `PATCH http://localhost:4000/api/v1/exchange_account/current` with any valid body

**Expected Result:**
- Status: `404 Not Found`

**Capybara Hints:**
- `expect(response).to have_http_status(404)`

---

## TC-010: POST test — valid credentials return success with balance

**Priority:** P0
**User Story:** US01 — Backend Account Management API
**Acceptance Criteria:** AC-003

**Preconditions:**
- Rails server running at localhost:4000
- `Bybit::RestClient` is stubbed (FakeBybitClient) to return successful `get_wallet_balance`

**Steps:**
1. Send `POST http://localhost:4000/api/v1/exchange_account/test` with body:
   ```json
   {
     "environment": "demo",
     "api_key": "TESTKEY1234567890abc",
     "api_secret": "TESTSECRET987654321xyz"
   }
   ```
2. Check response status code
3. Parse response JSON body

**Expected Result:**
- Status: `200 OK`
- Response body:
  ```json
  {
    "success": true,
    "balance": "<number> USDT"
  }
  ```
- `success` is `true`
- `balance` is a non-empty string containing "USDT"
- Response does NOT contain `"api_key"` or `"api_secret"` keys
- No `ExchangeAccount` record created in the database

**Capybara Hints:**
- `expect(json['success']).to be true`
- `expect(json['balance']).to match(/USDT\z/)`
- `expect(ExchangeAccount.count).to eq(0)`

---

## TC-011: POST test — invalid credentials return failure with error message

**Priority:** P0
**User Story:** US01 — Backend Account Management API
**Acceptance Criteria:** AC-003

**Preconditions:**
- Rails server running at localhost:4000
- `Bybit::RestClient` is stubbed to return a failed `get_wallet_balance` with error message "Invalid API key"

**Steps:**
1. Send `POST http://localhost:4000/api/v1/exchange_account/test` with body:
   ```json
   {
     "environment": "demo",
     "api_key": "BADKEY",
     "api_secret": "BADSECRET"
   }
   ```
2. Check response status code
3. Parse response JSON body

**Expected Result:**
- Status: `200 OK` (the test endpoint itself succeeded; the credential test failed)
- Response body:
  ```json
  {
    "success": false,
    "error": "Invalid API key"
  }
  ```
- `success` is `false`
- `error` is a non-empty descriptive string
- No `ExchangeAccount` record created

**Capybara Hints:**
- `expect(json['success']).to be false`
- `expect(json['error']).to be_present`

---

## TC-012: POST test — missing required params returns error

**Priority:** P1
**User Story:** US01 — Backend Account Management API

**Preconditions:**
- Rails server running at localhost:4000

**Steps:**
1. Send `POST http://localhost:4000/api/v1/exchange_account/test` with body missing `api_secret`:
   ```json
   {
     "environment": "demo",
     "api_key": "SOMEKEY"
   }
   ```
2. Check response status

**Expected Result:**
- Status: `422 Unprocessable Entity` OR `200 OK` with `{ "success": false, "error": "..." }`
- Response indicates failure; no crash (no 500)

**Capybara Hints:**
- `expect(response.status).not_to eq(500)`
- `expect(json['success']).to be_falsey` (if 200 returned) OR `expect(response).to have_http_status(422)`

---

## TC-013: filter_parameters — api_key and api_secret are filtered from logs

**Priority:** P0
**User Story:** US01 — Backend Account Management API
**Acceptance Criteria:** AC-005

**Preconditions:**
- Rails application initialized

**Steps:**
1. Open `config/initializers/filter_parameter_logging.rb`
2. Verify the filter_parameters list includes both `api_key` and `api_secret` (either explicitly or via pattern match like `:_key` and `:secret`)
3. Optionally: Run the Rails app, send a POST request with `api_key` and `api_secret` in the body, and check the Rails log output

**Expected Result:**
- `Rails.application.config.filter_parameters` contains patterns that match both `api_key` and `api_secret`
- In Rails logs, these parameters appear as `[FILTERED]` rather than their actual values

**Capybara Hints:**
- This is primarily a unit/config test:
  ```ruby
  expect(Rails.application.config.filter_parameters).to include(:api_key).or include(:_key)
  expect(Rails.application.config.filter_parameters).to include(:api_secret).or include(:secret)
  ```

---

## TC-014: RestClient accepts environment kwarg without ExchangeAccount record

**Priority:** P0
**User Story:** US01 — Backend Account Management API

**Preconditions:**
- Rails environment loaded

**Steps:**
1. Instantiate `Bybit::RestClient.new(api_key: 'key', api_secret: 'secret', environment: 'demo')`
2. Verify the client initializes without error
3. Verify `client.instance_variable_get(:@environment)` equals "demo"

**Expected Result:**
- No exception raised during instantiation
- `@environment` is set to the provided value ("demo")
- `@api_key` is set to "key"
- `@api_secret` is set to "secret"

**Edge Cases:**
- `environment: nil` — should fall back to `ENV['BYBIT_ENVIRONMENT']` or "testnet" default
- No `environment:` kwarg at all — backward compatible, existing behavior preserved

**Capybara Hints:**
- Unit spec, not a feature spec:
  ```ruby
  client = Bybit::RestClient.new(api_key: 'key', api_secret: 'secret', environment: 'demo')
  expect(client.instance_variable_get(:@environment)).to eq('demo')
  ```
