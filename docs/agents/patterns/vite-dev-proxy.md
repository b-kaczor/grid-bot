# Vite Dev Server Proxy for Rails Backend

## When to Use

- Vite (React) frontend and Rails API run on different ports in development (e.g., 3000 and 4000)
- You want to avoid CORS configuration in development
- You use ActionCable (WebSocket) and want the dev frontend to reach the Rails cable endpoint
- You want `/api/...` calls in the frontend to work identically in dev and production (no hardcoded port)

## Steps

### 1. Configure the Vite Proxy

File: `frontends/app/vite.config.ts`

```ts
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  build: {
    assetsDir: 'vite-assets',  // Avoids collision with Rails' public/assets/
  },
  server: {
    proxy: {
      '/api': 'http://localhost:4000',       // HTTP — Rails REST API
      '/cable': {
        target: 'ws://localhost:4000',       // WebSocket — ActionCable
        ws: true,
      },
    },
  },
})
```

The `server.proxy` block only applies to the Vite dev server (`npm run dev`). It has no effect on production builds.

### 2. Use Relative URLs in the API Client

File: `frontends/app/src/api/client.ts`

```ts
import axios from 'axios';

const apiClient = axios.create({
  baseURL: '/api/v1',   // Relative — works in both dev (proxied) and prod (same origin)
});

export default apiClient;
```

Never hardcode `http://localhost:4000` in the frontend code. Relative URLs work in dev (Vite proxies them) and in production (Rails serves both API and SPA from the same origin).

### 3. ActionCable Consumer

File: `frontends/app/src/cable/consumer.ts`

```ts
import { createConsumer } from '@rails/actioncable';

export default createConsumer('/cable');  // Relative — proxied in dev, same-origin in prod
```

### 4. Start Both Servers

Use `foreman` (or `Procfile.dev`) to start Rails and Vite together:

```
# Procfile.dev
api: bundle exec rails server -p 4000
web: npm run dev --prefix frontends/app
```

Then `foreman start -f Procfile.dev`. All frontend `/api/*` requests are proxied to `localhost:4000`.

## Verification

```bash
# With both servers running:
curl http://localhost:3000/api/v1/exchange_account/current
# Should return JSON from Rails, not Vite HTML
```

## Key Files

- `frontends/app/vite.config.ts` — `server.proxy` block
- `frontends/app/src/api/client.ts` — Relative `baseURL`
- `frontends/app/src/cable/consumer.ts` — Relative `/cable` URL
- `Procfile.dev` — Starts both servers together

## Notes

- The `server.proxy` config only affects `npm run dev`. Capybara feature specs use `npm run build` (pre-built assets) and do not go through the Vite dev server — they use `RackSpaMiddleware` instead (see `capybara-vite-setup.md`).
- WebSocket proxy (`ws: true`) is required for ActionCable live updates to work in dev. Without it, the Cable connection falls back to polling or fails silently.

## Example

See: `grid-engine/phase5-account-management/` — Vite proxy was added when manual testing revealed the frontend API client was targeting the wrong port (BUG-003).
