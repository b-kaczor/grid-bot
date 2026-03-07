# Phase 5.5: Account Setup & Settings — Architecture

## Overview

Add a backend controller for ExchangeAccount CRUD + connection testing, and two frontend pages (Setup, Settings) with an app-level guard that redirects to `/setup` when no account exists. Single-account only; no migration needed.

---

## 1. Backend

### 1.1 Controller: `Api::V1::ExchangeAccountsController`

**File:** `app/controllers/api/v1/exchange_accounts_controller.rb`

Inherits from `Api::V1::BaseController`. Four actions:

| Action | Route | Purpose |
|--------|-------|---------|
| `show` | `GET /api/v1/exchange_accounts/current` | Return the account with masked secrets. 404 with `{ setup_required: true }` if none exists. |
| `create` | `POST /api/v1/exchange_accounts` | Create the first account. 422 if one already exists. |
| `update` | `PATCH /api/v1/exchange_accounts/current` | Update the existing account. 404 if none exists. |
| `test` | `POST /api/v1/exchange_accounts/test` | Test credentials without saving. |

Key implementation details:

- **`show`**: `ExchangeAccount.first` — if nil, render `{ setup_required: true }` with 404 status. Otherwise render the account JSON with `api_key_hint`.
- **`create`**: Check `ExchangeAccount.exists?` first. If true, return 422 `"Account already exists. Use PATCH to update."`. Otherwise create with permitted params.
- **`update`**: Find `ExchangeAccount.first!` (raises RecordNotFound -> 404). Update with permitted params. Only update `api_key`/`api_secret` if they are present in the params (allows updating just the name/environment without re-entering secrets).
- **`test`**: Build a temporary `Bybit::RestClient.new(api_key:, api_secret:, environment:)` — note the constructor already supports these keyword args. Call `get_wallet_balance`. Return `{ success: true, balance: "10000.00 USDT" }` or `{ success: false, error: "..." }`.

**Credential masking** — private helper method `mask_key(key)`:
```ruby
def mask_key(key)
  return nil if key.blank?
  "#{'*' * 8}#{key[-4..]}"
end
```

**Account JSON** — inline hash (no jbuilder, consistent with existing controllers):
```ruby
def account_json(account)
  {
    id: account.id,
    name: account.name,
    exchange: account.exchange,
    environment: account.environment,
    api_key_hint: mask_key(account.api_key),
    created_at: account.created_at,
    updated_at: account.updated_at
  }
end
```

**Permitted params**: `params.require(:exchange_account).permit(:name, :exchange, :environment, :api_key, :api_secret)`

### 1.2 Routes

**File:** `config/routes.rb` — add inside the `api > v1` namespace:

```ruby
resource :exchange_account, only: [] do
  get :current, on: :collection
  patch :current, on: :collection
  post :test, on: :collection
end
resources :exchange_accounts, only: [:create]
```

This produces:
- `GET /api/v1/exchange_account/current`
- `PATCH /api/v1/exchange_account/current`
- `POST /api/v1/exchange_account/test`
- `POST /api/v1/exchange_accounts`

Alternative (simpler, preferred): use a single `resource` (singular) with custom member routes:

```ruby
resource :exchange_account, only: [:create] do
  collection do
    get :current
    patch :current
    post :test
  end
end
```

This gives us:
- `POST /api/v1/exchange_account` (create)
- `GET /api/v1/exchange_account/current`
- `PATCH /api/v1/exchange_account/current`
- `POST /api/v1/exchange_account/test`

The BRIEF spec uses `/api/v1/exchange_accounts` (plural) for create. Either is fine for a single-account app. Use singular `resource :exchange_account` for semantic clarity and adjust the frontend URLs accordingly.

### 1.3 Filter Parameters

**File:** `config/initializers/filter_parameter_logging.rb`

Add `api_key` and `api_secret` explicitly. The existing list has `_key` which partially matches `api_key`, but `api_secret` only matches `secret`. Both are already covered by the existing patterns (`_key` matches `api_key`, `secret` matches `api_secret`). However, for explicitness and safety, add them:

```ruby
Rails.application.config.filter_parameters += %i[
  passw secret token _key crypt salt certificate otp ssn
  api_key api_secret
]
```

### 1.4 Test Connection Implementation

The `test` action creates a temporary RestClient without persisting anything:

```ruby
def test
  client = Bybit::RestClient.new(
    api_key: params[:api_key],
    api_secret: params[:api_secret]
  )
  # Override environment for URL resolution
  response = client.get_wallet_balance

  if response.success?
    usdt = extract_usdt_balance(response.data)
    render json: { success: true, balance: "#{usdt} USDT" }
  else
    render json: { success: false, error: response.error_message }
  end
end
```

Note: `Bybit::RestClient.new` does not currently accept `environment:` as a standalone kwarg (it reads from `exchange_account.environment`). The constructor needs a minor adjustment — it already falls back to `ENV['BYBIT_ENVIRONMENT']` but we need to pass environment directly for the test endpoint. Two options:

**Option A (preferred)**: Add `environment:` keyword to RestClient constructor:
```ruby
def initialize(exchange_account: nil, api_key: nil, api_secret: nil, environment: nil, rate_limiter: nil)
  super()
  @api_key = api_key || exchange_account&.api_key || ENV.fetch('BYBIT_API_KEY', nil)
  @api_secret = api_secret || exchange_account&.api_secret || ENV.fetch('BYBIT_API_SECRET', nil)
  @environment = environment || exchange_account&.environment || ENV.fetch('BYBIT_ENVIRONMENT', 'testnet')
  # ... rest unchanged
end
```

**File to modify:** `app/services/bybit/rest_client.rb` (line 18) — add `environment: nil` parameter.

**Option B**: Build a temporary unsaved ExchangeAccount and pass it. Option A is cleaner.

### 1.5 Backend Specs

**File:** `spec/controllers/api/v1/exchange_accounts_controller_spec.rb` (new)

Test cases:
- `GET current` with no account -> 404 with `setup_required: true`
- `GET current` with account -> 200 with masked key, no full secrets in response
- `POST create` -> 201, account persisted
- `POST create` when account exists -> 422
- `PATCH current` -> 200, fields updated
- `PATCH current` with only name (no secrets) -> secrets unchanged
- `POST test` with valid creds -> `{ success: true, balance: "..." }`
- `POST test` with invalid creds -> `{ success: false, error: "..." }`
- Verify `api_key` and `api_secret` never appear in any response body

---

## 2. Frontend

### 2.1 New TypeScript Types

**File:** `frontends/app/src/types/account.ts` (new)

```typescript
export interface ExchangeAccount {
  id: number;
  name: string;
  exchange: string;
  environment: string;
  api_key_hint: string;
  created_at: string;
  updated_at: string;
}

export interface TestConnectionResult {
  success: boolean;
  balance?: string;
  error?: string;
}
```

### 2.2 API Module

**File:** `frontends/app/src/api/account.ts` (new)

```typescript
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import apiClient from './client.ts';
import type { ExchangeAccount, TestConnectionResult } from '../types/account.ts';

export const ACCOUNT_QUERY_KEY = ['exchange_account'];

export const useExchangeAccount = () =>
  useQuery<ExchangeAccount | null>({
    queryKey: ACCOUNT_QUERY_KEY,
    queryFn: () =>
      apiClient.get('/exchange_account/current').then((r) => r.data.account),
    retry: false,  // Don't retry 404s
  });

export const useCreateAccount = () => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (data: { name: string; exchange: string; environment: string; api_key: string; api_secret: string }) =>
      apiClient.post('/exchange_account', { exchange_account: data }),
    onSuccess: () => qc.invalidateQueries({ queryKey: ACCOUNT_QUERY_KEY }),
  });
};

export const useUpdateAccount = () => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (data: Partial<{ name: string; environment: string; api_key: string; api_secret: string }>) =>
      apiClient.patch('/exchange_account/current', { exchange_account: data }),
    onSuccess: () => qc.invalidateQueries({ queryKey: ACCOUNT_QUERY_KEY }),
  });
};

export const useTestConnection = () =>
  useMutation<TestConnectionResult, Error, { environment: string; api_key: string; api_secret: string }>({
    mutationFn: (data) =>
      apiClient.post('/exchange_account/test', data).then((r) => r.data),
  });
```

The `useExchangeAccount` hook is the foundation for the app-level guard. When it returns a 404/error, we know setup is required.

### 2.3 App-Level Guard

**File:** `frontends/app/src/components/AccountGuard.tsx` (new)

A wrapper component that:
1. Calls `useExchangeAccount()`
2. While loading: shows a centered `CircularProgress`
3. If error (404 / no account): renders `<Navigate to="/setup" />` (unless already on `/setup`)
4. If account exists: renders `children`

```typescript
// Pseudocode structure
export const AccountGuard = ({ children }: { children: ReactNode }) => {
  const { data, isLoading, isError } = useExchangeAccount();
  const location = useLocation();

  if (isLoading) return <CircularProgress />;
  if (isError || !data) {
    if (location.pathname === '/setup') return <>{children}</>;
    return <Navigate to="/setup" replace />;
  }
  return <>{children}</>;
};
```

**File to modify:** `frontends/app/src/App.tsx`

Wrap all routes (except `/setup`) in `AccountGuard`:

```tsx
<Routes>
  <Route path="/setup" element={<SetupPage />} />
  <Route element={<AccountGuard><AppLayout><Outlet /></AppLayout></AccountGuard>}>
    <Route path="/" element={<Navigate to="/bots" replace />} />
    <Route path="/bots" element={<BotDashboard />} />
    <Route path="/bots/new" element={<CreateBotWizard />} />
    <Route path="/bots/:id" element={<BotDetail />} />
    <Route path="/settings" element={<SettingsPage />} />
  </Route>
</Routes>
```

Note: The `/setup` route is **outside** the guard so it is always accessible. The guard wraps an `<Outlet />` layout route so it only runs once, not per-page.

### 2.4 Setup Page

**File:** `frontends/app/src/pages/SetupPage.tsx` (new)

Single-page form, no stepper needed (only one step). Fields:
- **Name** — text field, required (default: "My Demo Account")
- **Environment** — select dropdown: testnet, demo (default), mainnet
- **API Key** — text field, required
- **API Secret** — text field (password type), required

Buttons:
- **Test Connection** — calls `useTestConnection()`, shows success/error Alert
- **Save** — disabled until test passes. Calls `useCreateAccount()`, on success navigates to `/bots`

Exchange is hardcoded to `"bybit"` (only supported exchange). Not shown in the form.

Data test IDs: `setup-name`, `setup-environment`, `setup-api-key`, `setup-api-secret`, `setup-test-btn`, `setup-save-btn`, `setup-test-result`.

### 2.5 Settings Page

**File:** `frontends/app/src/pages/SettingsPage.tsx` (new)

Two modes: **view** and **edit** (same pattern as `RiskSettingsCard`).

**View mode:**
- Card showing: name, exchange, environment, masked API key (`api_key_hint`)
- "Edit" button

**Edit mode:**
- Form fields: name, environment (select), API key (text), API secret (password)
- API key/secret fields start blank (placeholder shows current hint)
- If left blank, they are not sent in the PATCH (server keeps existing values)
- "Test Connection" button — required before save if new keys are entered
- "Save" / "Cancel" buttons

Data test IDs: `settings-card`, `settings-edit-btn`, `settings-name`, `settings-environment`, `settings-api-key`, `settings-api-secret`, `settings-test-btn`, `settings-save-btn`, `settings-cancel-btn`.

### 2.6 Navigation Update

**File to modify:** `frontends/app/src/components/AppLayout.tsx`

Add a Settings icon button (MUI `SettingsIcon`) to the AppBar Toolbar, next to the GridBot title. Uses `useNavigate('/settings')` on click.

```tsx
<Toolbar>
  <Typography variant="h6" sx={{ cursor: 'pointer', flexGrow: 1 }} onClick={() => navigate('/bots')}>
    GridBot
  </Typography>
  <IconButton color="inherit" onClick={() => navigate('/settings')} data-testid="nav-settings">
    <SettingsIcon />
  </IconButton>
</Toolbar>
```

---

## 3. File Summary

### New Files

| File | Purpose |
|------|---------|
| `app/controllers/api/v1/exchange_accounts_controller.rb` | Backend CRUD + test endpoint |
| `spec/controllers/api/v1/exchange_accounts_controller_spec.rb` | Controller specs |
| `frontends/app/src/types/account.ts` | TypeScript types |
| `frontends/app/src/api/account.ts` | React Query hooks for account API |
| `frontends/app/src/components/AccountGuard.tsx` | App-level redirect guard |
| `frontends/app/src/pages/SetupPage.tsx` | First-time setup form |
| `frontends/app/src/pages/SettingsPage.tsx` | Account settings view/edit |

### Modified Files

| File | Change |
|------|--------|
| `config/routes.rb` | Add `resource :exchange_account` routes |
| `config/initializers/filter_parameter_logging.rb` | Add explicit `api_key`, `api_secret` |
| `app/services/bybit/rest_client.rb` | Add `environment:` keyword arg to constructor |
| `frontends/app/src/App.tsx` | Add `/setup`, `/settings` routes; wrap existing routes in `AccountGuard` |
| `frontends/app/src/components/AppLayout.tsx` | Add Settings icon to navigation bar |

---

## 4. Design Decisions

**Why no jbuilder views?** — Existing controllers (BotsController, BalancesController) all render inline `render json: { ... }`. Single-resource responses are simple enough that a view layer adds no value. Stay consistent.

**Why singular `resource :exchange_account`?** — There is exactly one account. Singular resource semantics (`/exchange_account/current`) communicate this better than plural with an ID. The `current` suffix is used instead of an ID parameter.

**Why require test-before-save on frontend, not backend?** — The test endpoint is separate from create/update. The backend does not enforce "must test first" because that would require server-side state (test token/session). Instead, the frontend disables the Save button until a successful test. This is simpler and sufficient for a single-user app.

**Why `environment:` kwarg on RestClient?** — The test endpoint needs to create a temporary client with a specific environment without persisting an ExchangeAccount. Adding the kwarg is a minimal, backwards-compatible change (defaults to nil, falls through to existing logic).

---

## 5. Risk Considerations

**Credential exposure** — The `api_key_hint` masking and `filter_parameters` config prevent accidental logging. The controller must never include `api_key` or `api_secret` in response JSON. Specs should assert this explicitly.

**Race condition on create** — Two simultaneous POST requests could create duplicate accounts. Mitigation: add a uniqueness check (`ExchangeAccount.exists?`) before create. The existing model uniqueness validation on `[name, exchange, environment]` provides a DB-level safety net. For a single-user app, this is sufficient.

**Test endpoint abuse** — The test endpoint makes a real API call to Bybit. No rate limiting is applied beyond Bybit's own limits. Acceptable for a single-user local app.
