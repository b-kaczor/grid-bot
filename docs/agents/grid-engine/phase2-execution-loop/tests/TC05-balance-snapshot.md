# TC05 — BalanceSnapshotWorker Test Cases

**Component:** `app/workers/balance_snapshot_worker.rb`
**Acceptance Criteria:** AC-012

---

## Preconditions (all test cases)

- Sidekiq running with `default` queue
- Bot in `running` status with trade history
- Sidekiq-cron configured with 5-minute schedule

---

## Unit Test Cases (RSpec coverage)

### TC05-01: Snapshot created with correct total_value_quote

**Priority:** P1
**Description:** `BalanceSnapshotWorker` creates a `BalanceSnapshot` record with correct `total_value_quote` calculation. (AC-012)

**Steps (RSpec unit test):**
```ruby
# Arrange
bot = create(:bot, status: "running", base_coin: "ETH", quote_coin: "USDT",
             investment_amount: 1000, quantity_per_level: "0.1")

# Simulate filled buys: 3 buys at 2500, 2400, 2300
# Simulate filled sells: 1 sell at 2520
# Base held: 0.1 + 0.1 + 0.1 - 0.1 = 0.2 ETH
# Quote spent: 250 + 240 + 230 = 720 USDT
# Quote received from sell: 252 USDT
# Quote balance: 1000 - 720 + 252 = 532 USDT (approximately)

allow(client).to receive(:get_tickers).and_return(
  Exchange::Response.new(success: true, data: { list: [{ lastPrice: "2450.00" }] })
)

BalanceSnapshotWorker.new.perform

snapshot = BalanceSnapshot.where(bot: bot, granularity: "fine").last
expect(snapshot).to be_present
expect(snapshot.granularity).to eq("fine")
# total_value = quote_balance + (base_held * current_price)
# = 532 + (0.2 * 2450) = 532 + 490 = 1022 USDT
expect(snapshot.total_value_quote).to be_within(BigDecimal("1")).of(BigDecimal("1022"))
```

**Expected Result:**
- `BalanceSnapshot` created with `granularity: "fine"`
- `total_value_quote` = quote_balance + (base_held * current_price)
- Snapshot has a `created_at` timestamp

---

### TC05-02: realized_profit calculated from trades sum

**Priority:** P1
**Description:** `realized_profit` on the snapshot matches the sum of all `trades.net_profit` for the bot.

**Steps (RSpec unit test):**
```ruby
create(:trade, bot: bot, net_profit: BigDecimal("1.50"))
create(:trade, bot: bot, net_profit: BigDecimal("1.75"))
create(:trade, bot: bot, net_profit: BigDecimal("-0.25"))  # Edge: losing trade

BalanceSnapshotWorker.new.perform

snapshot = BalanceSnapshot.last
expect(snapshot.realized_profit).to eq(BigDecimal("3.00"))  # 1.50 + 1.75 - 0.25
```

**Expected Result:**
- `realized_profit` sums all `net_profit` values from the bot's trades
- Negative trades (losses) correctly reduce the sum

---

### TC05-03: unrealized_pnl calculation

**Priority:** P1
**Description:** `unrealized_pnl` reflects the value difference of held base vs average buy price.

**Steps (RSpec unit test):**
```ruby
# avg_buy_price from filled buy orders = 2400 (weighted average)
# base_held = 0.2 ETH
# current_price = 2500
# unrealized_pnl = (2500 - 2400) * 0.2 = 20 USDT

BalanceSnapshotWorker.new.perform

snapshot = BalanceSnapshot.last
expect(snapshot.unrealized_pnl).to be_within(BigDecimal("0.01")).of(BigDecimal("20.00"))
```

**Expected Result:**
- `unrealized_pnl = (current_price - avg_buy_price) * base_held`
- Negative when current price is below average buy price

---

### TC05-04: Error isolation — one bot failure does not block others

**Priority:** P1
**Description:** If snapshot creation fails for one bot, other bots are still processed. (AC-012)

**Steps (RSpec unit test):**
```ruby
bot1 = create(:bot, status: "running")
bot2 = create(:bot, status: "running")

# Bot 1 fails (price fetch fails)
allow(client).to receive(:get_tickers)
  .with(hash_including(symbol: bot1.pair)).and_return(Exchange::Response.new(success: false))
  .with(hash_including(symbol: bot2.pair)).and_return(success_response)

BalanceSnapshotWorker.new.perform

# Bot 2 still gets a snapshot
expect(BalanceSnapshot.where(bot: bot2).count).to eq(1)
expect(BalanceSnapshot.where(bot: bot1).count).to eq(0)

# Error is logged, not raised
# (No Sidekiq job failure)
```

**Expected Result:**
- Bot 1 failure logged as error
- Bot 2 snapshot created successfully
- Sidekiq job completes (not marked as failed)

---

### TC05-05: Only running bots receive snapshots

**Priority:** P1
**Description:** Paused and stopped bots are not included in snapshot creation.

**Steps (RSpec unit test):**
```ruby
running_bot = create(:bot, status: "running")
paused_bot  = create(:bot, status: "paused")
stopped_bot = create(:bot, status: "stopped")

BalanceSnapshotWorker.new.perform

expect(BalanceSnapshot.where(bot: running_bot).count).to eq(1)
expect(BalanceSnapshot.where(bot: paused_bot).count).to eq(0)
expect(BalanceSnapshot.where(bot: stopped_bot).count).to eq(0)
```

**Expected Result:**
- Only `running` bots get snapshots

---

### TC05-06: Price fetch failure — snapshot skipped for that bot

**Priority:** P1
**Description:** If the ticker price fetch fails (returns non-success), no snapshot is created for that bot.

**Steps (RSpec unit test):**
```ruby
allow(client).to receive(:get_tickers).and_return(
  Exchange::Response.new(success: false, error_message: "Symbol not found")
)

BalanceSnapshotWorker.new.perform

expect(BalanceSnapshot.count).to eq(0)
# Error logged, worker continues
```

**Expected Result:**
- No snapshot created when price fetch fails
- Failure logged
- Worker does not raise

---

### TC05-07: Sidekiq-cron schedule — 5-minute interval

**Priority:** P1
**Description:** `BalanceSnapshotWorker` is scheduled to run every 5 minutes in `config/sidekiq.yml`.

**Steps (manual inspection):**
```ruby
# In Rails console
schedule = Sidekiq::Cron::Job.find("balance_snapshot_worker")
puts schedule.cron  # Should be "*/5 * * * *" or equivalent
puts schedule.klass  # "BalanceSnapshotWorker"
```

**Steps (RSpec):**
```ruby
# Load sidekiq.yml and verify the schedule entry exists
config = YAML.load_file(Rails.root.join("config/sidekiq.yml"))
snapshot_job = config.dig(:scheduler, "balance_snapshot_worker") ||
               config.dig("scheduler", "balance_snapshot_worker")
expect(snapshot_job["cron"]).to match(/\*\/5|\*\s\*/)
```

**Expected Result:**
- Job registered in Sidekiq scheduler with 5-minute interval
- Worker class name matches `"BalanceSnapshotWorker"`

---

## Integration Test (Rails console — testnet)

### TC05-08: Manual snapshot run on testnet

**Priority:** P1
**Description:** Verify a real snapshot is created with plausible values for a running testnet bot.

**Steps (Rails console):**
```ruby
bot = Bot.running.first
puts "Bot #{bot.id}: #{bot.pair}"
puts "Trades: #{bot.trades.count}"

# Run worker manually
BalanceSnapshotWorker.new.perform

snapshot = BalanceSnapshot.where(bot: bot, granularity: 'fine').last
puts "total_value_quote: #{snapshot.total_value_quote}"
puts "realized_profit: #{snapshot.realized_profit}"
puts "unrealized_pnl: #{snapshot.unrealized_pnl}"
puts "created_at: #{snapshot.created_at}"

# Cross-check: total_value should be close to investment_amount (± drift from profits/losses)
puts "Investment amount: #{bot.investment_amount}"
puts "Difference from investment: #{(snapshot.total_value_quote - bot.investment_amount).abs}"
```

**Expected Result:**
- Snapshot created within seconds
- `total_value_quote` within a reasonable range of `investment_amount` (should not be wildly different)
- `realized_profit` matches `bot.trades.sum(:net_profit)` exactly
- `created_at` is recent (within the last minute)

---

## Edge Cases

- **Bot with no trades:** `realized_profit = 0`, `unrealized_pnl` based on current price vs zero buys (0).
- **Bot with no filled orders:** `base_held = 0`, `total_value = quote_balance = investment_amount` (approximately).
- **Negative unrealized PnL:** When current price is below average buy price, `unrealized_pnl` is negative — this is valid and should be stored correctly.
