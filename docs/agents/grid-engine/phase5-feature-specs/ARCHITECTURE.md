# Phase 5: Feature Specs -- Architecture

## 1. Overview

Phase 5 adds Capybara-based end-to-end browser tests that exercise the React frontend against the Rails API. The test stack is: RSpec + Capybara + Cuprite (headless Chrome via CDP) + pre-built Vite assets served by Rails.

All specs live in `spec/features/` and are tagged `:feature`. They reuse existing factories and the MockRedis pattern from Phase 4. No live Redis, no live exchange calls, no Vite dev server at runtime.

---

## 2. Key Architecture Decision: Pre-built Vite Assets (Not Dev Server)

**Decision:** Run `vite build` before the test suite and serve the static `dist/` output through Rails' public file server. Do NOT boot a Vite dev server during tests.

**Rationale:**

| Concern | Dev Server | Pre-built (chosen) |
|---------|-----------|-------------------|
| Startup time | 2-5s cold start per suite run | One-time build (~10s), amortized |
| Reliability | Vite HMR websocket adds noise; port conflicts | Static files, zero moving parts |
| CI compatibility | Must manage a background process | Just `npm run build` in setup |
| ActionCable | Two separate origins to coordinate | Single origin (Rails serves everything) |
| Debug ease | Live reload useful in dev, not in CI | Use `save_and_open_page` for debugging |

The Vite build outputs to `frontends/app/dist/`. Rails will serve these files from `public/` via a copy + symlink step, configured in the test helper.

**Environment variables baked into the build:**

```bash
VITE_API_URL=/api/v1          # Relative URL -- same origin as Rails
VITE_CABLE_URL=/cable          # WebSocket on same origin
VITE_TEST_MODE=1               # Signals React to disable retry/staleTime (see section 12.4)
```

These override the default `http://localhost:3000/...` values, making the frontend talk to the Capybara test server on whatever random port Capybara assigns.

---

## 3. Gem Changes

Add to `Gemfile`, `group :test`:

```ruby
group :test do
  gem 'capybara', '~> 3.40'
  gem 'cuprite', '~> 0.15'
  gem 'database_cleaner-active_record', '~> 2.2'
end
```

- **capybara** -- browser automation DSL for RSpec
- **cuprite** -- Ferrum-based Chrome driver; talks CDP directly, no Selenium/ChromeDriver binary management
- **database_cleaner-active_record** -- needed because JS-capable drivers use a separate connection; `use_transactional_fixtures` cannot be shared across processes

`rubocop-capybara` is already in the Gemfile (dev/test group).

---

## 4. Capybara + Cuprite Configuration

### 4.1 Driver Registration

New file: `spec/support/capybara.rb`

```ruby
require 'capybara/rspec'
require 'capybara/cuprite'

Capybara.register_driver :cuprite do |app|
  Capybara::Cuprite::Driver.new(
    app,
    window_size: [1280, 800],
    headless: true,           # CI-safe; no display server needed
    process_timeout: 15,
    timeout: 10,
    browser_options: {
      'no-sandbox' => nil,    # Required for CI containers
      'disable-gpu' => nil,
    }
  )
end

Capybara.default_driver    = :rack_test          # Keep fast driver for non-JS specs
Capybara.javascript_driver = :cuprite             # Feature specs use Cuprite
Capybara.default_max_wait_time = 5                # MUI renders can take a moment
Capybara.server = :puma, { Silent: true }         # Use Puma for ActionCable support
```

Key points:
- **Puma server** is mandatory. The default WEBrick/Thin servers do not support WebSocket upgrades needed by ActionCable. Capybara will boot a Puma instance on a random port for each test run.
- **`:rack_test` remains the default** so existing request/controller specs are unaffected.
- Feature specs automatically get `:cuprite` via `type: :feature` metadata (Capybara switches to `javascript_driver` for these).

### 4.2 Rails Serves the Frontend

New file: `spec/support/features/vite_assets.rb`

This file handles three responsibilities: building the Vite assets, placing them where Rails can serve them, and inserting the SPA middleware.

```ruby
# Serve pre-built Vite assets from Rails' public directory during tests.
# The build step runs once before the suite via a before(:suite) hook.

VITE_APP_DIR  = Rails.root.join('frontends/app')
VITE_DIST_DIR = VITE_APP_DIR.join('dist')
VITE_INDEX    = Rails.root.join('public/index.html')
VITE_ASSETS   = Rails.root.join('public/vite-assets')

RSpec.configure do |config|
  config.before(:suite) do
    next unless RSpec.configuration.files_to_run.any? { |f| f.include?('spec/features') }

    # Build Vite assets with test-appropriate env vars (skip if dist/ is fresh)
    if !VITE_DIST_DIR.join('index.html').exist? || ENV['FORCE_VITE_BUILD']
      system(
        {
          'VITE_API_URL' => '/api/v1',
          'VITE_CABLE_URL' => '/cable',
          'VITE_TEST_MODE' => '1',
        },
        'npm', 'run', 'build',
        chdir: VITE_APP_DIR.to_s
      ) || raise('Vite build failed')
    end

    # Copy index.html to public/ root so React Router paths work at /
    FileUtils.cp(VITE_DIST_DIR.join('index.html'), VITE_INDEX)

    # Symlink dist/assets -> public/vite-assets (unique name avoids collision
    # with Rails asset pipeline's public/assets directory)
    FileUtils.rm_rf(VITE_ASSETS)
    FileUtils.ln_s(VITE_DIST_DIR.join('assets'), VITE_ASSETS)

    # Insert SPA middleware for client-side routing fallback
    Rails.application.config.middleware.insert_before(
      0, RackSpaMiddleware, index_path: VITE_INDEX.to_s
    )
  end

  config.after(:suite) do
    FileUtils.rm_f(VITE_INDEX)
    FileUtils.rm_rf(VITE_ASSETS)
  end
end
```

**Vite build config change:** The Vite config must output assets to a `vite-assets/` directory (instead of the default `assets/`) to avoid collision with the Rails asset pipeline directory at `public/assets/`. Add to `frontends/app/vite.config.ts`:

```ts
export default defineConfig({
  plugins: [react()],
  build: {
    assetsDir: 'vite-assets',
  },
})
```

This way:
- `dist/index.html` references `/vite-assets/index-abc123.js`
- Copied to `public/index.html`, it resolves against `public/vite-assets/` (the symlink)
- React Router paths (`/bots`, `/bots/:id`, `/bots/new`) work at root without a base path prefix

---

## 5. Database Strategy

### 5.1 The Problem

`use_transactional_fixtures = true` (current setting) wraps each test in a transaction that is rolled back. This works because the test and the app share the same DB connection.

With Cuprite, the browser hits Puma in a **separate thread** that opens its **own DB connection**. That connection cannot see uncommitted data from the test's transaction. Tests would see empty tables.

### 5.2 The Solution

Use `database_cleaner-active_record` with **truncation strategy** for feature specs only. Keep transactional fixtures for all other specs.

New file: `spec/support/database_cleaner.rb`

```ruby
require 'database_cleaner/active_record'

RSpec.configure do |config|
  config.before(:suite) do
    DatabaseCleaner.clean_with(:truncation)
  end

  config.before(:each, type: :feature) do
    DatabaseCleaner.strategy = :truncation
    DatabaseCleaner.start
  end

  config.after(:each, type: :feature) do
    DatabaseCleaner.clean
  end

  # Disable transactional fixtures for feature specs
  config.before(:each, type: :feature) do
    self.use_transactional_tests = false
  end
end
```

Non-feature specs continue using `use_transactional_fixtures = true` unchanged. The `type: :feature` metadata is automatically inferred from `spec/features/` by `infer_spec_type_from_file_location!` (already enabled).

---

## 6. WebMock Configuration

**Current state:** `spec/support/webmock.rb` calls `WebMock.disable_net_connect!` globally.

**Problem:** Cuprite connects to Chrome via CDP over HTTP/WebSocket. The Capybara Puma server listens on localhost. WebMock would block both.

**Solution:** Allow localhost connections in feature specs:

Updated `spec/support/webmock.rb`:

```ruby
require 'webmock/rspec'

# Default: block all net connections
WebMock.disable_net_connect!

RSpec.configure do |config|
  # Feature specs need localhost for Capybara server + Chrome CDP
  config.before(:each, type: :feature) do
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  config.after(:each, type: :feature) do
    WebMock.disable_net_connect!
  end
end
```

This ensures non-feature specs remain strictly isolated from the network, while feature specs can talk to the local Puma server and Chrome.

---

## 7. ActionCable Testing Approach

### 7.1 Cable Adapter: `async` for Feature Specs

**The `test` adapter does NOT work for browser WebSocket connections.** The `test` adapter is designed for unit-testing channels in isolation -- it stores broadcasts in an in-memory buffer for assertion, but does NOT actually deliver them to connected WebSocket clients. A real browser connecting via WebSocket to the Capybara Puma server would never receive any broadcast.

**Decision:** Feature specs must use the `async` adapter.

The `async` adapter runs an in-process pub/sub system that delivers broadcasts to all connected subscribers, including real WebSocket connections from the browser. It requires no external Redis dependency.

Implementation via a `before(:each)` hook:

```ruby
# spec/support/capybara.rb (or spec/support/features/cable_config.rb)
RSpec.configure do |config|
  config.before(:each, type: :feature) do
    # Switch to async adapter so broadcasts reach real browser WebSocket connections.
    # The default 'test' adapter only buffers broadcasts for assertion --
    # it does NOT deliver to connected clients.
    ActionCable.server.config.cable = { 'adapter' => 'async' }
    ActionCable.server.restart
  end

  config.after(:each, type: :feature) do
    # Restore test adapter for non-feature specs
    ActionCable.server.config.cable = { 'adapter' => 'test' }
    ActionCable.server.restart
  end
end
```

**Why not change `config/cable.yml` globally?** Keeping `test: adapter: test` in cable.yml preserves the existing channel unit test behavior (e.g., `assert_broadcast_on`). Only feature specs switch to `async` at runtime.

### 7.2 Simulating Server-Push Messages

To test real-time updates (e.g., fill events updating realized profit on the Bot Detail page), the test helper broadcasts directly via ActionCable:

```ruby
module Features
  module CableHelpers
    def broadcast_to_bot(bot_id, message)
      ActionCable.server.broadcast("bot_#{bot_id}", message)
    end
  end
end
```

With the `async` adapter active, this broadcast is delivered to the browser's WebSocket connection. Capybara's built-in waiting handles the assertion -- no explicit `sleep` needed:

```ruby
broadcast_to_bot(bot.id, { type: 'fill', realized_profit: '12.50', trade_count: 5, ... })
expect(page).to have_content('12.50')  # Capybara retries for up to 5s
```

**Important:** The real-time update scenario (AC-005) belongs to the **Bot Detail spec**, not the Dashboard spec. The Dashboard page (`BotDashboard.tsx`) does NOT subscribe to any ActionCable channel -- it only uses React Query polling. The `useBotChannel` hook is only used in `BotDetail.tsx`. See section 12.1 for the corrected spec structure.

### 7.3 ActionCable Forgery Protection

Add to `config/environments/test.rb`:

```ruby
config.action_cable.disable_request_forgery_protection = true
```

This mirrors the development config and prevents ActionCable from rejecting connections from the Capybara test server.

---

## 8. Exchange + Redis Mocking for Feature Specs

### 8.1 Exchange Client Stub

Feature specs stub `Bybit::RestClient` at the class level, same pattern as integration specs:

```ruby
module Features
  module ExchangeStubs
    def stub_exchange_client
      client = instance_double(Bybit::RestClient)
      allow(Bybit::RestClient).to receive(:new).and_return(client)

      allow(client).to receive_messages(
        get_instruments_info: instrument_info_response,
        get_tickers: ticker_response,
        get_wallet_balance: wallet_balance_response,
        set_dcp: ok_response,
        cancel_all_orders: ok_response,
        batch_place_orders: batch_orders_response,
        place_order: single_order_response,
        cancel_order: ok_response
      )

      client
    end

    # ... canned response methods (reuse from integration spec patterns)
  end
end
```

### 8.2 MockRedis

Reuse the existing `spec/support/mock_redis.rb`. Inject via:

```ruby
config.before(:each, type: :feature) do
  @mock_redis = MockRedis.new
  allow(Redis).to receive(:new).and_return(@mock_redis)
end
```

### 8.3 Grid::RedisState

```ruby
config.before(:each, type: :feature) do
  redis_state = Grid::RedisState.new(redis: @mock_redis)
  allow(Grid::RedisState).to receive(:new).and_return(redis_state)
end
```

---

## 9. File Organization

```
spec/
  support/
    capybara.rb                       # Driver registration, server config, async cable hook
    database_cleaner.rb               # Truncation strategy for features
    webmock.rb                        # Updated: allow_localhost for features
    mock_redis.rb                     # Existing (unchanged)
    lockbox.rb                        # Existing (unchanged)
    shoulda_matchers.rb               # Existing (unchanged)
    features/
      vite_assets.rb                  # Build + copy/symlink Vite dist/ into public/
      bot_helpers.rb                  # Create seeded bots with levels/trades/snapshots
      exchange_stubs.rb               # Stubbed Bybit::RestClient
      cable_helpers.rb                # ActionCable broadcast helpers
      navigation_helpers.rb           # visit_dashboard, visit_bot_detail, etc.
      rack_spa_middleware.rb          # SPA fallback middleware for client-side routes
  features/
    dashboard_spec.rb                 # 3 scenarios
    bot_detail_spec.rb                # 6 scenarios
    create_bot_wizard_spec.rb         # 4 scenarios
```

### 9.1 Shared Helper Inclusion

All feature helpers are included via RSpec metadata:

```ruby
# spec/support/capybara.rb (bottom)
RSpec.configure do |config|
  config.include Features::BotHelpers,        type: :feature
  config.include Features::ExchangeStubs,     type: :feature
  config.include Features::CableHelpers,      type: :feature
  config.include Features::NavigationHelpers,  type: :feature
end
```

---

## 10. SPA Routing Middleware

The React app uses client-side routing (`/bots`, `/bots/:id`, `/bots/new`). When Capybara navigates to these URLs, Rails needs to serve the SPA's `index.html` for any path that does not match an API route or a static file.

New file: `spec/support/features/rack_spa_middleware.rb`

```ruby
class RackSpaMiddleware
  def initialize(app, index_path:)
    @app = app
    @index_path = index_path
  end

  def call(env)
    status, headers, body = @app.call(env)

    # If Rails returned 404 and the request is not for API/cable/assets,
    # serve the SPA index.html instead
    if status == 404 && !api_request?(env['PATH_INFO'])
      [200, { 'Content-Type' => 'text/html' }, [File.read(@index_path)]]
    else
      [status, headers, body]
    end
  end

  private

  def api_request?(path)
    path.start_with?('/api/', '/cable', '/vite-assets/')
  end
end
```

Injected in `spec/support/features/vite_assets.rb` (see section 4.2) during the `before(:suite)` hook. Only active when feature specs are being run.

**Alternative considered:** Adding a catch-all route in `config/routes.rb`. Rejected because it would affect non-test environments unless guarded, and middleware is cleaner for this purpose.

---

## 11. Vite Asset Serving Summary

To avoid confusion, this section consolidates the single approach used (sections 4.2 and 10 describe parts of the same flow):

1. **Build:** `VITE_API_URL=/api/v1 VITE_CABLE_URL=/cable VITE_TEST_MODE=1 npm run build` in `frontends/app/`
2. **Vite config:** `build.assetsDir` set to `vite-assets` so output references `/vite-assets/...` paths
3. **Copy index.html:** `dist/index.html` is copied to `public/index.html`
4. **Symlink assets:** `dist/assets/` is symlinked to `public/vite-assets/`
5. **SPA middleware:** `RackSpaMiddleware` catches 404s for non-API paths and serves `public/index.html`
6. **Cleanup:** `after(:suite)` removes `public/index.html` and `public/vite-assets`

The result is that React Router paths (`/bots`, `/bots/:id`, `/bots/new`) resolve to the SPA entry point, API requests pass through to Rails, and static assets (JS/CSS bundles) are served from the symlinked directory.

---

## 12. Spec Structure and Patterns

### 12.1 Corrected Scenario Allocation

The real-time ActionCable update scenario belongs to the **Bot Detail spec**, not the Dashboard spec. The Dashboard page (`BotDashboard.tsx`) does not subscribe to any ActionCable channel -- it fetches data via React Query (`useBots()`) only. The `useBotChannel` hook is called exclusively in `BotDetail.tsx`.

**Dashboard spec** (3 scenarios): bot card display, navigate to detail, empty state

**Bot Detail spec** (6 scenarios): grid visualization, trade history pagination, performance charts, real-time fill update (ActionCable), risk settings view, risk settings edit

**Create Bot Wizard spec** (4 scenarios): step 1 pair selection, step 2 parameter entry with validation, step 3 summary, full happy path (redirects to Bot Detail page, not Dashboard -- see `CreateBotWizard.tsx` line 91: `navigate(botId ? '/bots/${botId}' : '/bots')`)

### 12.2 Common Pattern for Each Spec

```ruby
# spec/features/dashboard_spec.rb
require 'rails_helper'

RSpec.describe 'Dashboard', type: :feature do
  let!(:exchange_account) { create(:exchange_account) }

  before do
    stub_exchange_client
  end

  describe 'bot card display' do
    let!(:bot) do
      create(:bot, exchange_account:, status: 'running', pair: 'ETHUSDT')
    end

    before { seed_bot_redis_state(bot) }

    it 'shows the bot card with status, profit, and range' do
      visit '/bots'

      within('[data-testid="bot-card"]') do
        expect(page).to have_content('ETHUSDT')
        expect(page).to have_content('running')
      end
    end
  end
end
```

### 12.3 Data Attributes for Test Selectors

The implementation team should add `data-testid` attributes to key React components. This decouples tests from CSS class names and MUI internals. Recommended testids:

| Component | data-testid |
|-----------|------------|
| BotCard | `bot-card-{id}` |
| StatusBadge | `status-badge` |
| RangeVisualizer | `range-visualizer` |
| GridVisualization levels | `grid-level-{index}` |
| TradeHistoryTable | `trade-history-table` |
| TradeHistoryTable pagination | `trade-pagination` |
| PerformanceCharts (line) | `chart-portfolio` |
| PerformanceCharts (bar) | `chart-daily-profit` |
| RiskSettingsCard | `risk-settings-card` |
| Stop-loss input | `input-stop-loss` |
| Wizard step container | `wizard-step-{n}` |
| Pair select dropdown | `pair-select` |
| Lower price input | `input-lower-price` |
| Upper price input | `input-upper-price` |
| Grid count input | `input-grid-count` |

### 12.4 React Query Test Mode Override

The production `App.tsx` configures React Query with `staleTime: 30_000` and `retry: 1`. These defaults cause problems in feature specs:

- `staleTime: 30_000` means React Query will not refetch data for 30 seconds, causing stale UI after database changes
- `retry: 1` adds a retry delay on failed requests, slowing down failure scenarios

**Solution:** Check the `VITE_TEST_MODE` env var and override defaults:

```tsx
// In App.tsx (or a wrapper)
const isTestMode = import.meta.env.VITE_TEST_MODE === '1';

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: isTestMode ? 0 : 30_000,
      retry: isTestMode ? 0 : 1,
    },
  },
});
```

The `VITE_TEST_MODE=1` env var is baked into the Vite build during the test setup (section 4.2). It has no effect on development or production builds since those do not set it.

### 12.5 Wait Strategies

Capybara's built-in waiting (up to `default_max_wait_time`) handles most async rendering. For ActionCable-driven updates, use explicit `have_content` matchers that Capybara will retry:

```ruby
# Good -- Capybara retries until timeout
expect(page).to have_content('$12.50')

# Bad -- snapshot assertion, no retry
expect(page.text).to include('$12.50')
```

With the `async` adapter, broadcasts are delivered promptly. Capybara's default 5-second wait is sufficient. No explicit `sleep` calls should be needed.

### 12.6 Bot Helpers: Seeding Data for Charts

The `PerformanceCharts` component (`frontends/app/src/components/PerformanceCharts.tsx`) has an early-return guard at line 46:

```tsx
if (!data?.snapshots?.length || data.snapshots.length < 2) {
  return <Typography>Not enough data yet...</Typography>;
}
```

**Constraint for bot_helpers:** Any test that asserts on performance charts (AC-009) must seed **at least 2 `BalanceSnapshot` records** for the bot. The `seed_bot_with_charts` helper should create snapshots at different timestamps with different `realized_profit` values to ensure both the equity curve and daily profit bar chart render.

```ruby
# spec/support/features/bot_helpers.rb
module Features
  module BotHelpers
    def seed_bot_with_charts(bot)
      seed_bot_redis_state(bot)

      create(:balance_snapshot, bot:,
             snapshot_at: 2.hours.ago,
             total_value_quote: '10000.00',
             realized_profit: '0.00')
      create(:balance_snapshot, bot:,
             snapshot_at: 1.hour.ago,
             total_value_quote: '10050.00',
             realized_profit: '50.00')
    end
  end
end
```

---

## 13. Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|-----------|
| Vite build adds ~10s to suite startup | Developer friction | Only build when dist/ is stale; skip with `SKIP_VITE_BUILD=1` env var |
| Chrome not installed in CI | Suite cannot run | Document Chrome/Chromium as a CI dependency; Cuprite/Ferrum auto-downloads if needed |
| WebMock blocking Chrome CDP | Cuprite crashes | `allow_localhost: true` in feature spec config (section 6) |
| MUI uses dynamic class names | Selectors break | Use `data-testid` attributes, never MUI class selectors |
| Truncation strategy is slower than transactions | Feature specs slower | Accept -- feature specs are inherently slower; keep the count low (~13 scenarios) |
| React Query staleTime causes stale UI | Flaky assertions | Override via `VITE_TEST_MODE=1` env var (section 12.4) |
| Database state not visible to Puma thread | Tests see empty UI | DatabaseCleaner truncation (not transaction) -- section 5 |
| `async` adapter broadcasts not delivered in time | ActionCable test flaky | Capybara's 5s wait handles this; increase `default_max_wait_time` if needed |
| Charts require 2+ snapshots to render | Empty chart assertions fail | `seed_bot_with_charts` helper always creates 2+ snapshots (section 12.6) |

---

## 14. What Exists vs. What Needs to Be Built

### Exists (no changes needed)
- `spec/support/mock_redis.rb` -- reusable as-is
- `spec/factories/` -- all 6 factories (exchange_accounts, bots, grid_levels, orders, trades, balance_snapshots)
- `spec/support/lockbox.rb` -- test encryption key
- `spec/support/shoulda_matchers.rb` -- unchanged
- `config/cable.yml` -- keep `test: adapter: test` as default; feature specs override to `async` at runtime
- `config/environments/test.rb` -- public file server enabled
- `frontends/app/dist/` -- build already exists (will be rebuilt with test env vars)

### Needs modification
- `Gemfile` -- add capybara, cuprite, database_cleaner-active_record to test group
- `spec/support/webmock.rb` -- add `allow_localhost: true` for feature specs
- `config/environments/test.rb` -- add `config.action_cable.disable_request_forgery_protection = true`
- `frontends/app/vite.config.ts` -- set `build.assetsDir` to `'vite-assets'`
- `frontends/app/src/App.tsx` -- add `VITE_TEST_MODE` check to override React Query staleTime/retry
- React components -- add `data-testid` attributes (see section 12.3)

### Needs creation
- `spec/support/capybara.rb` -- driver registration, server config, async cable adapter hook
- `spec/support/database_cleaner.rb` -- truncation for feature specs
- `spec/support/features/vite_assets.rb` -- build + copy/symlink Vite dist into public/
- `spec/support/features/rack_spa_middleware.rb` -- SPA fallback for client routes
- `spec/support/features/bot_helpers.rb` -- create seeded bots with Redis state and snapshots
- `spec/support/features/exchange_stubs.rb` -- stubbed exchange client
- `spec/support/features/cable_helpers.rb` -- ActionCable broadcast helpers
- `spec/support/features/navigation_helpers.rb` -- page visit shortcuts
- `spec/features/dashboard_spec.rb` -- 3 scenarios
- `spec/features/bot_detail_spec.rb` -- 6 scenarios
- `spec/features/create_bot_wizard_spec.rb` -- 4 scenarios

---

## 15. Implementation Order

1. **Gems + Capybara config** -- Gemfile, driver registration, Puma server, async cable hook
2. **Database strategy** -- DatabaseCleaner setup, WebMock adjustment
3. **Vite build integration** -- vite.config.ts assetsDir, vite_assets.rb, SPA middleware
4. **React Query test mode** -- `VITE_TEST_MODE` check in App.tsx
5. **Shared helpers** -- exchange stubs, bot helpers (including chart seeding), cable helpers
6. **React data-testid attributes** -- add to all components listed in 12.3
7. **Dashboard spec** -- start with simplest (empty state), then card display, then navigation
8. **Create Bot Wizard spec** -- step-by-step progression, then full happy path (verify redirect to Bot Detail)
9. **Bot Detail spec** -- grid viz, trade history, charts, ActionCable fill update, risk settings
10. **Verify existing 504 specs still pass** -- full `bundle exec rspec` run
