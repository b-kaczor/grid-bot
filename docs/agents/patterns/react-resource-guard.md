# React Resource Guard

## When to Use

- A React SPA requires a resource to exist before any page is usable (e.g., account setup, onboarding)
- You want to redirect unauthenticated or uninitialized users to a setup page without a backend session mechanism
- The check is a simple API call that returns 404 when the resource is absent

## Steps

### 1. Create the Guard Component

File: `frontends/app/src/components/AccountGuard.tsx` (or equivalent)

```tsx
import { Navigate, Outlet, useLocation } from 'react-router-dom';
import { CircularProgress, Box } from '@mui/material';
import { useExchangeAccount } from '../api/account';

export const AccountGuard = () => {
  const { data, isLoading, isError } = useExchangeAccount();
  const location = useLocation();

  if (isLoading) {
    return (
      <Box display="flex" justifyContent="center" mt={8}>
        <CircularProgress />
      </Box>
    );
  }

  if (isError || !data) {
    if (location.pathname === '/setup') return <Outlet />;
    return <Navigate to="/setup" replace />;
  }

  return <Outlet />;
};
```

Key points:
- Use `<Outlet />` (not `{children}`) so the guard can be a layout route — runs once per navigation, not per child page.
- Guard against redirect loop: if already on the guarded path (`/setup`), render normally.
- Use `replace` on `<Navigate>` so the browser back button does not loop.

### 2. Wire into the Router

File: `frontends/app/src/App.tsx`

```tsx
<Routes>
  {/* Setup is OUTSIDE the guard — always accessible */}
  <Route path="/setup" element={<SetupPage />} />

  {/* All other routes go through the guard */}
  <Route element={<AccountGuard />}>
    <Route element={<AppLayout />}>
      <Route path="/" element={<Navigate to="/bots" replace />} />
      <Route path="/bots" element={<BotDashboard />} />
      <Route path="/bots/:id" element={<BotDetail />} />
      <Route path="/settings" element={<SettingsPage />} />
    </Route>
  </Route>
</Routes>
```

The guarded route has no `path` — it acts as a layout wrapper. The `/setup` route sits outside so it is always reachable regardless of guard state.

### 3. Handle 404 Correctly in the API Hook

File: `frontends/app/src/api/account.ts`

```ts
export const useExchangeAccount = () =>
  useQuery<ExchangeAccount | null>({
    queryKey: ['exchange_account'],
    queryFn: () =>
      apiClient
        .get('/exchange_account/current')
        .then((r) => r.data.account)
        .catch((err) => {
          if (err.response?.status === 404) return null;
          throw err;
        }),
    retry: false,  // Do not retry 404s
  });
```

Return `null` on 404 (resource not yet created) and let the guard treat `!data` as "redirect to setup". Re-throw non-404 errors so they surface as `isError`.

### 4. Backend: Signal Setup Required

```ruby
# GET /api/v1/exchange_account/current
def show
  account = ExchangeAccount.first
  if account.nil?
    render json: { setup_required: true }, status: :not_found
  else
    render json: { account: account_json(account) }
  end
end
```

The `setup_required: true` body is optional but helps with debugging. The guard only needs the 404 status.

## Key Files

- `frontends/app/src/components/AccountGuard.tsx` — Guard component
- `frontends/app/src/api/account.ts` — Query hook with 404 null-return
- `frontends/app/src/App.tsx` — Router wiring (guard as layout route)
- `app/controllers/api/v1/exchange_accounts_controller.rb` — Backend 404 signal

## Gotchas

- **React Query undefined warning**: When the API body is `{ setup_required: true }` and the hook returns `null`, React Query may log `"Query data cannot be undefined"`. This is cosmetic — return `null` (not `undefined`) to suppress it, or configure `placeholderData`.
- **Guard runs on every navigation**: Because it uses `useQuery`, the result is cached — subsequent navigations hit the React Query cache, not the network.
- **Do not guard the guarded path inside the guard**: The `/setup` path must be outside the `<Route element={<AccountGuard />}>` wrapper, not just conditionally skipped inside the guard logic.

## Example

See: `grid-engine/phase5-account-management/` for the reference implementation.
