# Phase 2 Execution Loop — E2E Test Plan

## Overview

Phase 2 is **backend-only**. There is no React UI, no REST API, no browser interaction. All testing is performed via:

1. **RSpec unit tests** — component-level isolation with mocked exchange calls
2. **Rails console integration tests** — run against Bybit testnet with real exchange calls
3. **Process-level tests** — `bin/ws_listener` lifecycle testing

---

## Test Environments

### Unit Test Environment (RSpec)
- Ruby on Rails test environment (`RAILS_ENV=test`)
- In-memory or test PostgreSQL database
- Redis (test DB index, e.g., DB 15)
- All external HTTP/WS calls stubbed via RSpec mocks or WebMock
- No real Bybit API calls

**Run command:**
```bash
bundle exec rspec spec/services/grid/initializer_spec.rb
bundle exec rspec spec/workers/order_fill_worker_spec.rb
bundle exec rspec spec/workers/grid_reconciliation_worker_spec.rb
bundle exec rspec spec/services/bybit/websocket_listener_spec.rb
bundle exec rspec spec/workers/balance_snapshot_worker_spec.rb
bundle exec rspec spec/services/grid/redis_state_spec.rb
```

### Integration Test Environment (Testnet)
- Ruby on Rails development environment (`RAILS_ENV=development`)
- PostgreSQL development database
- Redis (development DB)
- **Live Bybit testnet** (`wss://stream-testnet.bybit.com/v5/private`, `https://api-testnet.bybit.com`)
- Sidekiq running locally

**Required environment variables:**
```bash
BYBIT_TESTNET_API_KEY=<key>
BYBIT_TESTNET_API_SECRET=<secret>
REDIS_URL=redis://localhost:6379/0
DATABASE_URL=postgresql://localhost/grid_bot_development
```

---

## Test Scope

### In Scope
- `Grid::Initializer` — full initialization flow, error recovery, batch placement
- `OrderFillWorker` — buy/sell fill processing, counter-orders, trade recording, optimistic locking, idempotency
- `GridReconciliationWorker` — gap detection, orphan adoption/cancellation, partial fill handling
- `Bybit::WebsocketListener` — connection, auth, subscriptions, heartbeat, reconnection, maintenance, shutdown
- `BalanceSnapshotWorker` — snapshot creation, calculations, error isolation
- `Grid::RedisState` — seed, update, cleanup
- End-to-end: 100 autonomous trades on ETHUSDT testnet

### Out of Scope
- React frontend (Phase 3)
- Rails API endpoints (Phase 3)
- Stop-loss / take-profit logic (Phase 4)
- Performance/load testing
- Multi-exchange support

---

## Test Priority

| Priority | Definition | Must Pass Before |
|----------|-----------|-----------------|
| P0 | Core trading loop, data integrity | Testnet milestone (TC07) |
| P1 | Reliability, error recovery, edge cases | Production readiness |
| P2 | Nice-to-have, defensive cases | Can defer to Phase 3 |

---

## Test Files

| File | Component | AC Covered |
|------|-----------|------------|
| `tests/TC01-grid-initializer.md` | `Grid::Initializer` | AC-001 |
| `tests/TC02-order-fill-worker.md` | `OrderFillWorker` | AC-003, AC-004, AC-005, AC-006, AC-014 |
| `tests/TC03-reconciliation.md` | `GridReconciliationWorker` | AC-008 |
| `tests/TC04-websocket-listener.md` | `Bybit::WebsocketListener` | AC-002, AC-009, AC-010, AC-013 |
| `tests/TC05-balance-snapshot.md` | `BalanceSnapshotWorker` | AC-012 |
| `tests/TC06-redis-state.md` | `Grid::RedisState` | AC-011 |
| `tests/TC07-testnet-milestone.md` | End-to-end | AC-007 |

---

## Acceptance Criteria Coverage

| AC | Description | Priority | Test File(s) |
|----|-------------|----------|-------------|
| AC-001 | Initializer places orders, creates DB records, sets running | P0 | TC01-01 |
| AC-002 | WebSocket connects, authenticates, receives order.spot events | P0 | TC04-01, TC04-02, TC04-03 |
| AC-003 | Buy fill → sell counter-order placed within latency window | P0 | TC02-01 |
| AC-004 | Sell fill → buy counter-order + cycle_count increment + Trade record | P0 | TC02-02 |
| AC-005 | net_quantity correct when fee_coin == base_coin | P0 | TC02-03, TC02-04 |
| AC-006 | Optimistic locking prevents duplicate counter-orders | P0 | TC02-06 |
| AC-007 | 100 autonomous trades on ETHUSDT testnet | P0 | TC07-01 |
| AC-008 | Reconciliation detects and repairs missed order within 15s | P0 | TC03-01, TC03-11 |
| AC-009 | WebSocket reconnects with exponential backoff, triggers reconciliation | P1 | TC04-06, TC04-07 |
| AC-010 | Close code 1001 / HTTP 503 pauses bots, auto-resumes | P1 | TC04-09, TC04-10 |
| AC-011 | Redis hot state populated and updated on fills | P1 | TC06-01, TC06-02, TC06-09 |
| AC-012 | BalanceSnapshotWorker creates fine snapshots every 5min | P1 | TC05-01, TC05-07 |
| AC-013 | SIGTERM closes WebSocket cleanly | P1 | TC04-12 |
| AC-014 | Duplicate fill messages result in exactly one DB update | P0 | TC02-05 |

---

## Test Execution Order

### Phase A — Unit Tests (RSpec, no exchange)
1. TC06 — Redis state (foundation for all other components)
2. TC01 — Initializer
3. TC02 — OrderFillWorker
4. TC03 — Reconciliation
5. TC05 — BalanceSnapshotWorker
6. TC04 — WebSocket listener (most complex to unit test)

### Phase B — Integration Tests (testnet, individual components)
1. TC01-01 — Initializer happy path on testnet
2. TC06-09 — Verify Redis seeded correctly
3. TC02-12 — Single buy→sell cycle on testnet
4. TC03-11 — Simulate missed fill (kill/restart listener)
5. TC04-14 — End-to-end: listener detects real fill
6. TC05-08 — Manual snapshot creation

### Phase C — Milestone Test
1. TC07-01 — 100 autonomous trades (only after Phase A and B pass)

---

## Prerequisites Checklist

Before running integration tests:

- [ ] Phase 2 DB migrations applied (`rails db:migrate`)
- [ ] `ExchangeAccount` record created with testnet API credentials
- [ ] `Bot` record created in `pending` status
- [ ] Bybit testnet account funded (USDT balance > 200)
- [ ] "Fee deduction using other coin" disabled in Bybit testnet account settings
- [ ] Sidekiq running with correct queue configuration
- [ ] Redis accessible at `REDIS_URL`
- [ ] `bin/ws_listener` is executable (`chmod +x bin/ws_listener`)
- [ ] `config/sidekiq.yml` includes `critical`, `default` queues and cron schedules

---

## Common Test Data Setup (Rails console)

```ruby
# Create exchange account
account = ExchangeAccount.create!(
  name: "Bybit Testnet",
  exchange: "bybit",
  api_key: ENV["BYBIT_TESTNET_API_KEY"],
  api_secret: ENV["BYBIT_TESTNET_API_SECRET"],
  testnet: true
)

# Get current price
client = Bybit::RestClient.new(exchange_account: account)
price = BigDecimal(client.get_tickers(symbol: "ETHUSDT").data[:list].first[:lastPrice])

# Create bot with tight range for frequent fills
bot = Bot.create!(
  exchange_account: account,
  pair: "ETHUSDT",
  base_coin: "ETH",
  quote_coin: "USDT",
  lower_price: (price * 0.97).round(2),
  upper_price: (price * 1.03).round(2),
  grid_count: 10,
  investment_amount: 150,
  spacing_type: "arithmetic",
  status: "pending"
)
puts "Bot #{bot.id} created. Price range: #{bot.lower_price} - #{bot.upper_price}"
```

---

## Known Limitations / Phase 2 Scope Constraints

1. **No UI testing** — All verification is via Rails console commands or RSpec.
2. **Partial fills handled by reconciliation, not real-time** — Partial fills < 95% are left open; >= 95% are resolved at next reconciliation cycle.
3. **Single exchange account** — WebSocket listener handles one exchange account at a time (multi-account is future scope).
4. **Third-coin fees not supported** — Account must have "fee deduction using other coin" disabled. If triggered, fee is logged as zero (defensive guard).
5. **100-trade milestone timing** — Depends on market volatility on testnet. May require 6-24 hours of bot operation.
