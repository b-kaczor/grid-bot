# Phase 5: Feature Specs (E2E Browser Testing)

## Problem to Solve

Phases 1–4 have built and verified the backend trading engine, execution loop, dashboard API, and risk management layer. The React frontend (Vite + MUI v6) has been developed alongside these phases but has no automated browser-level test coverage. As a result, regressions in UI flows — bot creation wizard, real-time status updates, grid visualization, risk settings editing — can only be caught by manual inspection. Phase 5 closes this gap by introducing Capybara-based E2E feature specs that exercise the full stack through a real browser.

## Goals

- Establish a Capybara + Cuprite infrastructure that drives the Vite React frontend against the Rails API in a test environment.
- Write feature specs covering all three frontend pages: Dashboard, Bot Detail, and the Create Bot Wizard.
- Ensure all feature specs run in CI alongside the existing 504 unit/integration specs without introducing flakiness or external dependencies (no live exchange, no live Redis).

## Scope

### In scope

- Capybara + Cuprite gem setup (headless Chrome, no Selenium)
- Capybara configuration to serve the Vite React frontend concurrently with the Rails test server
- `spec/features/` directory with shared helpers: bot factory, fill simulation, exchange mock
- MockRedis + stubbed exchange client reusing the same approach as `spec/integration/`
- Three feature spec files (see Feature Specs section below)
- CI compatibility (headless Chrome flag, no display server required)

### Out of scope

- Visual regression / screenshot diffing
- Performance benchmarking
- Phase 6 analytics pages (not yet built)
- Cross-browser testing (Chrome/Chromium only for now)

## User Persona

**Bot operator (single-user app):** The person running GridBot on their own server. They interact with the three frontend pages daily: checking bot health on the Dashboard, inspecting grid state on the Bot Detail page, and occasionally launching new bots via the wizard.

## Feature Description

### 5.1 Infrastructure Setup

**Gems to add:**
- `capybara` — standard browser automation DSL for RSpec
- `cuprite` — Ferrum-based headless Chrome driver; no Selenium, no ChromeDriver binary management

**Capybara configuration:**
- Register a `:cuprite` driver configured for headless Chrome
- Configure `Capybara.app_host` to point at the Vite dev server (or a production build served statically during tests)
- Ensure ActionCable WebSocket endpoint is reachable within the test environment

**Shared test helpers (`spec/support/features/`):**
- `BotHelpers` — create a bot record with seeded grid levels and trades via factories
- `FillSimulationHelpers` — simulate an order fill event to trigger ActionCable broadcasts
- `ExchangeMockHelpers` — stub `Bybit::RestClient` at the adapter boundary (no real HTTP)

**Test isolation:**
- Use `DatabaseCleaner` with truncation strategy for feature specs (JS-capable driver requires a separate DB connection)
- MockRedis injected for all Redis reads/writes
- Mocked exchange client returns canned instrument info, tickers, and order responses

### 5.2 Feature Specs

#### Dashboard Page (`spec/features/dashboard_spec.rb`)

| Scenario | Description |
|----------|-------------|
| Bot card display | A seeded running bot appears as a card showing pair, status badge, profit figure, and range visualizer bar |
| Navigate to detail | Clicking a bot card navigates to the Bot Detail page |
| Empty state | With no bots, the dashboard renders an empty state prompt with a link to create a bot |

#### Bot Detail Page (`spec/features/bot_detail_spec.rb`)

| Scenario | Description |
|----------|-------------|
| Grid visualization | Grid levels render as a vertical price axis; buy levels and sell levels are visually distinguished |
| Trade history pagination | Trade history table shows page 1 by default; navigating to page 2 loads the next set of trades |
| Performance charts | Portfolio value line chart and daily profit bar chart are present in the DOM and non-empty |
| Real-time fill update | Simulating a fill event via ActionCable updates the realized profit and trade count on the Bot Detail page without a page reload |
| Risk settings — view | Stop-loss price, take-profit price, and trailing toggle are displayed in the Risk Settings card |
| Risk settings — edit | User can edit the stop-loss price inline and save; the updated value persists (confirmed via API stub) |

#### Create Bot Wizard (`spec/features/create_bot_wizard_spec.rb`)

| Scenario | Description |
|----------|-------------|
| Step 1 — pair selection | Wizard opens on step 1; user selects ETHUSDT from the pair dropdown and advances |
| Step 2 — parameter entry | User enters lower price, upper price, grid count; validation errors appear for out-of-range values; valid values allow advancing |
| Step 3 — summary | Investment amount slider and summary preview (profit per grid estimate) render; user clicks Confirm and the bot creation API call is made |
| Full happy path | Completing all three steps creates a bot and redirects to the Bot Detail page where the bot's pair and status are displayed |

### 5.3 Phase 5 Milestone

- Capybara + Cuprite configured and all drivers registered in `spec/rails_helper.rb`
- `spec/features/` directory exists with three spec files and shared helpers
- All feature specs pass in headless Chrome
- `bundle exec rspec spec/features/` runs cleanly alongside `bundle exec rspec spec/` (504 pre-existing specs unaffected)
- No live exchange calls, no live Redis dependency in any feature spec

## Acceptance Criteria

| # | Criterion | Priority |
|---|-----------|----------|
| AC-001 | `cuprite` and `capybara` gems are present in the `test` group of `Gemfile` and `bundle install` succeeds | P0 |
| AC-002 | Running `bundle exec rspec spec/features/` executes all feature specs using headless Chrome without requiring a display server | P0 |
| AC-003 | All pre-existing 504 specs continue to pass after Phase 5 infrastructure changes | P0 |
| AC-004 | Dashboard spec: bot card displays status, profit, and range visualizer for a seeded running bot | P0 |
| AC-005 | Bot Detail spec: ActionCable fill event updates the realized profit and trade count without a page reload | P1 |
| AC-006 | Dashboard spec: empty state is shown when no bots exist | P1 |
| AC-007 | Bot Detail spec: grid visualization renders buy and sell levels distinguishably | P0 |
| AC-008 | Bot Detail spec: trade history table paginates correctly across at least 2 pages | P0 |
| AC-009 | Bot Detail spec: performance charts (line + bar) are present and contain data | P1 |
| AC-010 | Bot Detail spec: risk settings card allows inline editing of stop-loss price and persists the change | P0 |
| AC-011 | Wizard spec: step 1 pair selection works; step 2 shows validation errors for invalid parameters | P0 |
| AC-012 | Wizard spec: completing all three steps triggers bot creation and redirects to the Bot Detail page | P0 |
| AC-013 | No feature spec makes a real HTTP request to Bybit or any external service | P0 |
| AC-014 | No feature spec requires a live Redis server (MockRedis used throughout) | P0 |

## Technical Notes

- **Driver choice:** Cuprite (Ferrum-based) is preferred over Selenium because it communicates directly with Chrome via the DevTools Protocol, has no ChromeDriver version-pinning issues, and supports ActionCable WebSockets natively.
- **Vite + Capybara:** The Vite dev server must be running (or a static build must be served) for Capybara to drive the React app. The implementation team should decide between running `vite build` before the suite or booting a Vite dev server as a test helper process.
- **ActionCable in tests:** Feature specs must use the `async` cable adapter (not the default `test` adapter) so that broadcasts reach real browser WebSocket connections. Use direct `ActionCable::Server::Broadcasting` calls in helpers to simulate server-pushed messages without a running WebSocket listener process.
- **Database strategy:** Feature specs must use `truncation` (not `transaction`) for `DatabaseCleaner` because Cuprite runs in a separate thread/process that cannot share the test transaction.
- **Existing pattern:** Reuse `spec/support/mock_redis.rb` (introduced in Phase 4) and the exchange stub pattern from `spec/integration/trading_loop_spec.rb`.
