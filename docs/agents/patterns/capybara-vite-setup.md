# Capybara + Cuprite + Vite Pre-Build Setup

## When to Use

- You have a Rails API backend serving a React (Vite) SPA frontend
- You want full-stack E2E browser tests using RSpec feature specs
- You need ActionCable (WebSocket) to work within the test environment
- You want headless Chrome tests without Selenium/ChromeDriver version pinning

## Key Decisions

- **Pre-build Vite assets** (not a dev server at runtime) — avoids port conflicts, HMR noise, and multi-origin ActionCable issues. One-time `npm run build` is amortized across the suite run.
- **Cuprite over Selenium** — communicates directly via Chrome DevTools Protocol; no ChromeDriver binary to manage; supports WebSocket natively.
- **`async` ActionCable adapter** for feature specs — the default `test` adapter only buffers broadcasts for assertion and does NOT deliver them to connected browser WebSocket clients.
- **`DatabaseCleaner` truncation** for feature specs — Cuprite runs in a separate thread with its own DB connection; `use_transactional_fixtures` cannot share uncommitted data across threads.
- **`data-testid` attributes** on all React components — MUI generates dynamic class names; never use them as selectors.

## Steps

### 1. Add Gems

```ruby
# Gemfile, group :test
gem 'capybara', '~> 3.40'
gem 'cuprite', '~> 0.15'
gem 'database_cleaner-active_record', '~> 2.2'
```

### 2. Register Cuprite Driver

File: `spec/support/capybara.rb`

```ruby
require 'capybara/rspec'
require 'capybara/cuprite'

Capybara.register_driver :cuprite do |app|
  Capybara::Cuprite::Driver.new(
    app,
    window_size: [1280, 800],
    headless: true,
    process_timeout: 15,
    timeout: 10,
    browser_options: {
      'no-sandbox' => nil,   # Required in CI containers
      'disable-gpu' => nil,
    }
  )
end

Capybara.default_driver    = :rack_test   # Fast for non-JS specs
Capybara.javascript_driver = :cuprite     # Feature specs use Cuprite
Capybara.default_max_wait_time = 5        # Enough for MUI + ActionCable
Capybara.server = :puma, { Silent: true } # Puma required for ActionCable
```

Puma is mandatory — WEBrick/Thin do not support WebSocket upgrades.

### 3. Switch ActionCable to `async` Adapter for Feature Specs

Add to `spec/support/capybara.rb`:

```ruby
RSpec.configure do |config|
  config.before(:each, type: :feature) do
    ActionCable.server.config.cable = { 'adapter' => 'async' }
    ActionCable.server.restart
  end

  config.after(:each, type: :feature) do
    ActionCable.server.config.cable = { 'adapter' => 'test' }
    ActionCable.server.restart
  end
end
```

Keep `test: adapter: test` in `config/cable.yml` so channel unit tests continue using `assert_broadcast_on`.

### 4. Database Cleaner

File: `spec/support/database_cleaner.rb`

```ruby
require 'database_cleaner/active_record'

RSpec.configure do |config|
  config.before(:suite) do
    DatabaseCleaner.clean_with(:truncation)
  end

  config.before(:each, type: :feature) do
    self.use_transactional_tests = false
    DatabaseCleaner.strategy = :truncation
    DatabaseCleaner.start
  end

  config.after(:each, type: :feature) do
    DatabaseCleaner.clean
  end
end
```

### 5. Allow localhost in WebMock

```ruby
# spec/support/webmock.rb
config.before(:each, type: :feature) do
  WebMock.disable_net_connect!(allow_localhost: true)
end

config.after(:each, type: :feature) do
  WebMock.disable_net_connect!
end
```

Cuprite connects to Chrome via CDP on localhost; Capybara boots Puma on localhost. Both would be blocked by the global `WebMock.disable_net_connect!` without this.

### 6. Disable ActionCable Forgery Protection in Test

```ruby
# config/environments/test.rb
config.action_cable.disable_request_forgery_protection = true
```

### 7. Pre-build Vite Assets

Vite config change — use a non-colliding assets directory:

```ts
// frontends/app/vite.config.ts
export default defineConfig({
  plugins: [react()],
  build: {
    assetsDir: 'vite-assets',  // Avoids collision with Rails' public/assets/
  },
})
```

File: `spec/support/features/vite_assets.rb`

```ruby
VITE_APP_DIR  = Rails.root.join('frontends/app')
VITE_DIST_DIR = VITE_APP_DIR.join('dist')
VITE_INDEX    = Rails.root.join('public/index.html')
VITE_ASSETS   = Rails.root.join('public/vite-assets')

RSpec.configure do |config|
  config.before(:suite) do
    next unless RSpec.configuration.files_to_run.any? { |f| f.include?('spec/features') }

    if !VITE_DIST_DIR.join('index.html').exist? || ENV['FORCE_VITE_BUILD']
      system(
        { 'VITE_API_URL' => '/api/v1', 'VITE_CABLE_URL' => '/cable', 'VITE_TEST_MODE' => '1' },
        'npm', 'run', 'build',
        chdir: VITE_APP_DIR.to_s
      ) || raise('Vite build failed')
    end

    FileUtils.cp(VITE_DIST_DIR.join('index.html'), VITE_INDEX)
    FileUtils.rm_rf(VITE_ASSETS)
    FileUtils.ln_s(VITE_DIST_DIR.join('assets'), VITE_ASSETS)

    Rails.application.config.middleware.insert_before(0, RackSpaMiddleware, index_path: VITE_INDEX.to_s)
  end

  config.after(:suite) do
    FileUtils.rm_f(VITE_INDEX)
    FileUtils.rm_rf(VITE_ASSETS)
  end
end
```

### 8. SPA Routing Middleware

File: `spec/support/features/rack_spa_middleware.rb`

```ruby
class RackSpaMiddleware
  def initialize(app, index_path:)
    @app = app
    @index_path = index_path
  end

  def call(env)
    status, headers, body = @app.call(env)
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

React Router paths (`/bots`, `/bots/:id`, `/bots/new`) all 404 at the Rails router level. This middleware intercepts those 404s and serves the SPA's `index.html`.

### 9. React Query Test Mode

Bake `VITE_TEST_MODE=1` into the build so the frontend disables stale time and retries:

```tsx
// frontends/app/src/App.tsx
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

Without `staleTime: 0`, React Query serves cached data after DB changes, making feature spec assertions unreliable.

## Key Files

- `spec/support/capybara.rb` — Driver, server, ActionCable adapter hook
- `spec/support/database_cleaner.rb` — Truncation strategy for feature specs
- `spec/support/webmock.rb` — localhost allowance
- `spec/support/features/vite_assets.rb` — Vite pre-build + public/ setup
- `spec/support/features/rack_spa_middleware.rb` — SPA 404 fallback
- `frontends/app/vite.config.ts` — `assetsDir: 'vite-assets'`
- `frontends/app/src/App.tsx` — `VITE_TEST_MODE` override
- `config/environments/test.rb` — ActionCable forgery protection off

## Example

See: `grid-engine/phase5-feature-specs/` for the reference implementation, including:
- `spec/features/dashboard_spec.rb`
- `spec/features/bot_detail_spec.rb`
- `spec/features/create_bot_wizard_spec.rb`
- `spec/support/features/bot_helpers.rb`, `exchange_stubs.rb`, `cable_helpers.rb`
