# E2E Test Plan: Phase 5.5 — Account Setup & Settings

## Overview

This document defines the end-to-end test strategy for the Account Setup & Settings feature. The feature enables users to create and manage a single `ExchangeAccount` through the UI, replacing the previous requirement to use `rails console`.

**Branch:** `phase5-account-management`
**Stories covered:** US01 (Backend API), US02 (Account Guard), US03 (Setup & Settings pages)

---

## Test Environments

| Environment | URL | Notes |
|-------------|-----|-------|
| Backend (Rails) | `http://localhost:4000` | Rails API server with test database |
| Frontend (Vite) | `http://localhost:3000` | React app, VITE_TEST_MODE=1 for specs |
| Bybit Testnet | `https://api-testnet.bybit.com` | External; stubbed in automated specs |
| Bybit Demo | `https://api-demo.bybit.com` | External; stubbed in automated specs |

---

## Prerequisites

### System Prerequisites

- Ruby on Rails API running on port 4000
- React frontend running on port 3000
- PostgreSQL with test database seeded
- Redis running (required for bot operations)
- For automated Capybara specs: Chrome/Chromium and chromedriver installed

### Test Data Prerequisites

- **No-account state**: `ExchangeAccount` table empty (for setup flow tests)
- **With-account state**: One `ExchangeAccount` record present (for settings tests)
- Test API credentials: Any non-empty strings for testnet/demo environment tests (the test endpoint calls Bybit; use real testnet credentials for manual testing, or stubs for automated specs)

### Feature Flags / Config

- `BYBIT_ENVIRONMENT` env var does not affect the test endpoint (credentials passed inline)
- `api_key` and `api_secret` must be in `Rails.application.config.filter_parameters`

---

## Test Scope

### In Scope

| Area | Coverage |
|------|----------|
| Backend API — `GET /api/v1/exchange_account/current` | Happy path, no-account 404, response masking |
| Backend API — `POST /api/v1/exchange_account` | Create success, duplicate 422, missing params |
| Backend API — `PATCH /api/v1/exchange_account/current` | Update fields, partial update (no secrets), 404 |
| Backend API — `POST /api/v1/exchange_account/test` | Valid creds, invalid creds, missing params |
| Security: credential masking | api_key_hint format, no raw secrets in any response |
| Security: filter_parameters | api_key/api_secret filtered from Rails logs |
| App-level guard (AccountGuard) | Redirect on no account, no redirect loop, loading state |
| Setup page UI | Form fields, validation, test connection, save flow, redirect |
| Settings page UI | View mode, edit mode, partial update, cancel, save flow |
| Navigation | Settings icon in header, route `/settings` accessible |
| Integration: guard + setup + dashboard | Full first-time user flow |

### Out of Scope

- Multiple account management
- Account deletion
- WebSocket / ActionCable behavior (covered in existing bot specs)
- Bot creation flow (covered in `create_bot_wizard_spec.rb`)
- Rate limiting on the test endpoint

---

## Test Categories and Priorities

| Priority | Description | Examples |
|----------|-------------|---------|
| P0 | Core functionality — must pass before merge | AC-001 through AC-008 |
| P1 | Important UX — should pass before merge | AC-009, AC-010, navigation, edge cases |
| P2 | Nice-to-have — can follow in a subsequent PR | Loading states, network error UI |

---

## Test Files

| File | Coverage |
|------|----------|
| `tests/US01-backend-api.md` | All four API endpoints (TC-001 through TC-014) |
| `tests/US02-account-guard.md` | AccountGuard redirect behavior (TC-015 through TC-021) |
| `tests/US03-setup-and-settings.md` | Setup page and Settings page UI (TC-022 through TC-044) |

---

## Capybara Spec Mapping

The test cases in this plan are designed for two execution modes:

1. **Manual execution** using Playwright CLI against locally running services
2. **Automated Capybara feature specs** — the primary delivery artifact (`spec/features/account_management_spec.rb`)

### Capybara Setup Notes

- All feature specs inherit from `spec/support/features/` helpers
- Exchange client is intercepted globally via `Features::BybitOverride` (see `exchange_stubs.rb`)
- The `FakeBybitClient#get_wallet_balance` already returns a successful response — use this to stub the test-connection endpoint for happy-path specs
- For invalid-credential scenarios, add a `FakeBybitClientFailure` in `exchange_stubs.rb` or use a direct stub on the controller action
- Navigation helpers (`visit_setup`, `visit_settings`) to be added to `navigation_helpers.rb`

### Data-testid Reference

| Element | data-testid |
|---------|-------------|
| Setup: name field | `setup-name` |
| Setup: environment select | `setup-environment` |
| Setup: API key field | `setup-api-key` |
| Setup: API secret field | `setup-api-secret` |
| Setup: Test Connection button | `setup-test-btn` |
| Setup: Save button | `setup-save-btn` |
| Setup: test result alert | `setup-test-result` |
| Settings: card container | `settings-card` |
| Settings: Edit button | `settings-edit-btn` |
| Settings: name field | `settings-name` |
| Settings: environment select | `settings-environment` |
| Settings: API key field | `settings-api-key` |
| Settings: API secret field | `settings-api-secret` |
| Settings: Test Connection button | `settings-test-btn` |
| Settings: Save button | `settings-save-btn` |
| Settings: Cancel button | `settings-cancel-btn` |
| Navigation: Settings icon | `nav-settings` |

---

## Risk Areas

| Risk | Mitigation |
|------|-----------|
| Credential exposure in API responses | TC-004, TC-006: assert `api_key`/`api_secret` absent from JSON |
| Credential exposure in Rails logs | TC-013: assert filter_parameters config |
| Redirect loop on `/setup` | TC-017: explicit test that `/setup` does not redirect |
| AccountGuard breaking existing routes | TC-018 through TC-020: existing routes still work post-account-creation |
| Race condition on duplicate account creation | TC-008: POST when account exists returns 422 |
| Save button enabled before test passes | TC-030: Save button remains disabled until test connection succeeds |
| Partial PATCH overwrites secrets unintentionally | TC-011: PATCH without api_key/api_secret keeps existing values |

---

## Acceptance Criteria Traceability

| AC | Criterion | Test Cases |
|----|-----------|-----------|
| AC-001 | No account redirects to `/setup` | TC-015, TC-016 |
| AC-002 | Setup form creates account | TC-022, TC-031 |
| AC-003 | Test Connection validates before save | TC-027, TC-028, TC-030 |
| AC-004 | Responses never expose full api_key/api_secret | TC-004, TC-006, TC-010 |
| AC-005 | api_key/api_secret in filter_parameters | TC-013 |
| AC-006 | Settings page shows masked key | TC-033 |
| AC-007 | Settings allows update with connection test | TC-036, TC-037, TC-039 |
| AC-008 | After setup, dashboard and wizard work | TC-032 |
| AC-009 | Settings link in navigation | TC-043 |
| AC-010 | Environment selector with demo default | TC-023, TC-034 |
