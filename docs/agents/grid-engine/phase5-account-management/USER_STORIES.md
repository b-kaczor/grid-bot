# User Stories: Phase 5.5 — Account Setup & Settings

## US01: Backend Account Management API

**As a** developer integrating the frontend,
**I want** a RESTful API for managing the single ExchangeAccount,
**so that** credentials can be created, viewed, updated, and tested without touching rails console.

### Acceptance Criteria
- `GET /api/v1/exchange_account/current` returns the account with masked key, or 404 with `setup_required: true`
- `POST /api/v1/exchange_account` creates the first account; 422 if one already exists
- `PATCH /api/v1/exchange_account/current` updates the account; secrets not overwritten if omitted
- `POST /api/v1/exchange_account/test` validates credentials against Bybit without persisting
- `api_key` and `api_secret` never appear in any response body
- Both fields are in Rails `filter_parameters`
- `Bybit::RestClient` accepts `environment:` kwarg for credential testing without an account record

### Tasks
- T1: RestClient environment kwarg + filter_parameters (backend-dev-1)
- T2: ExchangeAccountsController + routes + specs (backend-dev-1)

---

## US02: App-Level Account Guard

**As a** user opening the app for the first time,
**I want** to be automatically redirected to the setup page when no account exists,
**so that** the app is usable without touching the terminal.

### Acceptance Criteria
- Navigating to any route with no account redirects to `/setup`
- Navigating to `/setup` when already there does not cause a redirect loop
- Loading state shows a spinner while the account check is in progress
- After setup, normal navigation to `/bots` works

### Tasks
- T3: TypeScript types + API module (frontend-dev-1)
- T4: AccountGuard component + App.tsx routing (frontend-dev-1)

---

## US03: Setup Page and Settings Page

**As a** user,
**I want** a setup form for first-time account creation and a settings page to update credentials,
**so that** I can manage my Bybit connection entirely through the UI.

### Acceptance Criteria
- Setup page has name, environment (demo default), API key, API secret fields
- "Test Connection" validates before save; Save is disabled until test passes
- After successful setup, user lands on the bot dashboard
- Settings page shows current account with masked API key
- Settings edit mode allows updating any field; blank key/secret fields are not sent
- Settings nav icon is visible in the app header and navigates to `/settings`

### Tasks
- T5: SetupPage component (frontend-dev-1)
- T6: SettingsPage component + AppLayout navigation (frontend-dev-1)
