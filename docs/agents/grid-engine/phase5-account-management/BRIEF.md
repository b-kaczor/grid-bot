# Phase 5.5: Account Setup & Settings

## Problem to Solve

GridBot requires an `ExchangeAccount` record to function, but there's no UI to create one — users must use `rails console`. This makes the app unusable out of the box. Additionally, there's no way to view or update account credentials through the UI.

## Goals

- The app works end-to-end without touching rails console
- If no account exists, the app guides the user through setup
- A settings page lets users view account info and update credentials
- Keep it simple — single account, no multi-account dashboard grouping

## Scope

### In scope

**Backend:**
- `ExchangeAccountsController` with `show`, `create`, `update` actions
- `POST /api/v1/exchange_accounts/test` — verify API keys before saving
- Add `api_key`, `api_secret` to `Rails.application.config.filter_parameters`
- Account response never exposes full secrets (mask all but last 4 chars)

**Frontend:**
- Setup page (`/setup`) — shown when no account exists
  - Form: name, environment (testnet/demo/mainnet dropdown), API key, API secret
  - "Test Connection" button before saving
  - On success → redirect to dashboard
- Settings page (`/settings`) — view and edit existing account
  - Shows: name, exchange, environment, masked API key
  - Edit form: update name, environment, API key, API secret
  - "Test Connection" before saving changes
- App-level guard: if no account exists, redirect all routes to `/setup`
- Navigation: add Settings link to app header/sidebar

### Out of scope

- Multiple accounts
- Dashboard grouping by account
- Account deletion (only one account, just update it)
- WebSocket listener changes (still uses `ExchangeAccount.first`, which is fine for single account)
- Account selection in bot creation (still uses the one account)

## User Flows

### Flow 1: First-time setup
1. User opens app → no account exists → redirected to `/setup`
2. User enters: name, environment (demo recommended), API key, API secret
3. Clicks "Test Connection" → app calls Bybit `get_wallet_balance` with provided credentials
4. Success → clicks "Save" → account created → redirected to `/bots` (dashboard)
5. Dashboard shows empty state → "Create your first bot"

### Flow 2: Update credentials
1. User navigates to `/settings`
2. Sees current account: name, environment, masked API key (e.g., `••••••••ab3f`)
3. Clicks "Edit" → form appears with current name/environment, blank key/secret fields
4. Enters new credentials → "Test Connection" → "Save"
5. Credentials updated, stays on settings page with success message

## API Spec

### New endpoints

```
GET    /api/v1/exchange_accounts/current      → show the account (masked secrets)
POST   /api/v1/exchange_accounts              → create account (first-time setup)
PATCH  /api/v1/exchange_accounts/current      → update account
POST   /api/v1/exchange_accounts/test         → test credentials (doesn't save)
```

### Response shape

```json
{
  "account": {
    "id": 1,
    "name": "My Demo Account",
    "exchange": "bybit",
    "environment": "demo",
    "api_key_hint": "••••ab3f",
    "created_at": "2026-03-07T12:00:00Z",
    "updated_at": "2026-03-07T12:00:00Z"
  }
}
```

### Test endpoint

```
POST /api/v1/exchange_accounts/test
Body: { "environment": "demo", "api_key": "...", "api_secret": "..." }
Response: { "success": true, "balance": "10000.00 USDT" }
     or:  { "success": false, "error": "Invalid API key" }
```

### Error responses

```
GET /current when no account → 404 { "setup_required": true }
POST /create when account already exists → 422 { "error": "Account already exists. Use PATCH to update." }
```

## Acceptance Criteria

| # | Criterion | Priority |
|---|-----------|----------|
| AC-001 | Opening the app with no account redirects to `/setup` | P0 |
| AC-002 | Setup form creates an account with name, environment, API key, secret | P0 |
| AC-003 | "Test Connection" validates credentials against Bybit before saving | P0 |
| AC-004 | API responses never expose full api_key or api_secret | P0 |
| AC-005 | `api_key` and `api_secret` are in Rails filter_parameters | P0 |
| AC-006 | Settings page shows current account with masked key | P0 |
| AC-007 | Settings page allows updating credentials with connection test | P0 |
| AC-008 | After account creation, dashboard and bot wizard work normally | P0 |
| AC-009 | Settings link accessible from app navigation | P1 |
| AC-010 | Environment selector offers testnet, demo, mainnet with demo as default | P1 |

## Technical Notes

- No migration needed — ExchangeAccount model and table already exist
- `default_exchange_account` in BaseController stays as-is — it returns the one account
- Connection test creates a temporary `Bybit::RestClient` with provided creds and calls `get_wallet_balance`
- Masked key: show last 4 characters only, e.g., `••••••••ab3f`
- The setup guard should be a React-level check (query `/api/v1/exchange_accounts/current`, if 404 → redirect to `/setup`)
