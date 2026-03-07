# TC07 — Testnet Milestone: 100 Autonomous Trades

**Acceptance Criteria:** AC-007

---

## Overview

This is the Phase 2 end-to-end validation test. The goal is to demonstrate that the GridBot can complete **100 autonomous buy→sell trade cycles** on Bybit ETHUSDT testnet with **zero manual intervention** after the initial `Grid::Initializer.new(bot).call`.

A "trade" here means a completed buy→sell cycle, recorded as a `Trade` record in the database.

**Target Configuration:**
- Pair: `ETHUSDT`
- Grid levels: 10
- Spacing: arithmetic
- The range should be set tightly around current testnet price to maximize fill frequency

---

## Prerequisites

### System Requirements
- Ruby on Rails app running (Rails 7.1)
- PostgreSQL database with Phase 2 schema migrations applied
- Redis running
- Sidekiq running with `critical` and `default` queues
- `bin/ws_listener` process available

### Bybit Testnet Account
- API key + secret with Spot trading permissions
- ExchangeAccount record in DB configured for testnet (`testnet: true`)
- Testnet USDT balance: at least 200 USDT (for buy-side orders)
- Testnet ETH balance: 0 acceptable (initializer will market-buy ETH for sell orders)
- "Fee deduction using other coin" is DISABLED in Bybit account settings

### Verification Tool
- Rails console access (`bundle exec rails c`)
- Sidekiq Web UI accessible (optional, for job monitoring)

---

## Setup Steps

### Step 1: Apply DB Migrations

```bash
bundle exec rails db:migrate
# Verify: quantity_per_level on bots, paired_order_id on orders
```

### Step 2: Create ExchangeAccount

```ruby
# Rails console
account = ExchangeAccount.create!(
  name: "Bybit Testnet",
  exchange: "bybit",
  api_key: ENV["BYBIT_TESTNET_API_KEY"],
  api_secret: ENV["BYBIT_TESTNET_API_SECRET"],
  testnet: true
)
puts "ExchangeAccount ID: #{account.id}"
```

### Step 3: Determine current ETHUSDT testnet price

```ruby
client = Bybit::RestClient.new(exchange_account: account)
ticker = client.get_tickers(symbol: "ETHUSDT")
current_price = BigDecimal(ticker.data[:list].first[:lastPrice])
puts "Current ETHUSDT price: #{current_price}"
```

### Step 4: Create Bot

```ruby
# Set grid range ±3% around current price for frequent fills
lower = (current_price * BigDecimal("0.97")).round(2)
upper = (current_price * BigDecimal("1.03")).round(2)

bot = Bot.create!(
  exchange_account: account,
  pair: "ETHUSDT",
  base_coin: "ETH",
  quote_coin: "USDT",
  lower_price: lower,
  upper_price: upper,
  grid_count: 10,
  investment_amount: 150,  # 150 USDT
  spacing_type: "arithmetic",
  status: "pending"
)
puts "Bot ID: #{bot.id}, range: #{lower} - #{upper}"
```

### Step 5: Start Services

```bash
# Terminal 1: Sidekiq
bundle exec sidekiq -C config/sidekiq.yml

# Terminal 2: WebSocket listener
bundle exec bin/ws_listener

# Terminal 3: Rails console (for monitoring)
bundle exec rails c
```

### Step 6: Initialize Bot

```ruby
# Rails console
bot = Bot.find(<bot_id>)
Grid::Initializer.new(bot).call
bot.reload
puts "Status: #{bot.status}"  # Should be "running"
puts "Grid levels: #{bot.grid_levels.count}"
puts "Open orders: #{bot.orders.where(status: 'open').count}"
puts "quantity_per_level: #{bot.quantity_per_level}"
```

---

## Monitoring Commands

Run these periodically during the 100-trade milestone run:

```ruby
# Progress summary
bot = Bot.find(<bot_id>).reload

trade_count = bot.trades.count
realized_profit = bot.trades.sum(:net_profit)
open_orders = bot.orders.where(status: 'open').count
filled_orders = bot.orders.where(status: 'filled').count
redis = Redis.new

puts "=== Bot #{bot.id} Status ==="
puts "Status: #{bot.status}"
puts "Trades completed: #{trade_count}/100"
puts "Realized profit: #{realized_profit.round(4)} USDT"
puts "Open orders: #{open_orders}"
puts "Filled orders: #{filled_orders}"
puts ""
puts "=== Redis State ==="
puts "Status: #{redis.get("grid:#{bot.id}:status")}"
puts "Current price: #{redis.get("grid:#{bot.id}:current_price")}"
stats = redis.hgetall("grid:#{bot.id}:stats")
puts "Redis trade count: #{stats['trade_count']}"
puts "Redis realized profit: #{stats['realized_profit']}"
puts ""
puts "=== Recent Trades ==="
bot.trades.recent.limit(5).each do |t|
  puts "Trade ##{t.id}: buy=#{t.buy_price} sell=#{t.sell_price} profit=#{t.net_profit.round(4)}"
end
```

```ruby
# Grid health check: all levels accounted for
bot = Bot.find(<bot_id>)
puts "Grid level statuses:"
bot.grid_levels.order(:level_index).each do |l|
  order_status = l.orders.order(:placed_at).last&.status || "none"
  puts "  Level #{l.level_index} @ #{l.price}: #{l.status} / #{l.expected_side} / last_order=#{order_status}"
end
```

---

## TC07-01: Milestone Acceptance Test — 100 Autonomous Trades

**Priority:** P0
**Description:** Full end-to-end validation. Bot completes 100 trades autonomously.

### Verification Criteria

After the bot has been running (no manual intervention beyond Step 6):

#### 1. Trade Count Verification

```ruby
bot = Bot.find(<bot_id>).reload
expect(bot.trades.count).to be >= 100
```

#### 2. No Manual Intervention Required

- WebSocket listener ran continuously (or reconnected automatically if it dropped)
- No manual Sidekiq job submissions
- No manual order placements via Rails console
- No manual DB edits

#### 3. Bot Remains in Running Status

```ruby
bot.reload
puts bot.status  # Must be "running", not "error" or "paused"
```

#### 4. All Trades Have Correct Records

```ruby
bot.trades.each do |trade|
  # Every field populated
  raise "Missing buy_price on trade #{trade.id}" unless trade.buy_price > 0
  raise "Missing sell_price on trade #{trade.id}" unless trade.sell_price > 0
  raise "Missing quantity on trade #{trade.id}" unless trade.quantity > 0
  raise "Missing gross_profit on trade #{trade.id}" if trade.gross_profit.nil?
  raise "Missing total_fees on trade #{trade.id}" if trade.total_fees.nil?
  raise "Missing net_profit on trade #{trade.id}" if trade.net_profit.nil?
  raise "Missing completed_at on trade #{trade.id}" unless trade.completed_at

  # sell_price > buy_price (should always be for a grid buy-low-sell-high strategy)
  raise "Inverted trade #{trade.id}: sell #{trade.sell_price} < buy #{trade.buy_price}" \
    unless trade.sell_price > trade.buy_price

  # paired_order linkage intact
  sell_order = trade.sell_order
  buy_order = trade.buy_order
  raise "Sell order missing buy link on trade #{trade.id}" \
    unless sell_order.paired_order_id == buy_order.id
end
puts "All #{bot.trades.count} trades valid"
```

#### 5. Redis State Consistent with DB

```ruby
redis = Redis.new
stats = redis.hgetall("grid:#{bot.id}:stats")

db_count = bot.trades.count
db_profit = bot.trades.sum(:net_profit)
redis_count = stats["trade_count"].to_i
redis_profit = BigDecimal(stats["realized_profit"])

puts "DB trades: #{db_count}, Redis: #{redis_count}"
puts "DB profit: #{db_profit.round(4)}, Redis: #{redis_profit.round(4)}"
# Note: minor discrepancy acceptable if a fill was processed after last Redis update
raise "Trade count mismatch" if (db_count - redis_count).abs > 1
raise "Profit mismatch" if (db_profit - redis_profit).abs > BigDecimal("0.01")
```

#### 6. Grid Integrity — No Orphaned Levels

```ruby
# No levels should be stuck in 'pending' (initializer should have set all to active/skipped)
stuck = bot.grid_levels.where(status: 'pending')
puts "Stuck pending levels: #{stuck.count}"  # Should be 0

# No active orders exceeding grid bounds
bot.orders.where(status: 'open').each do |order|
  raise "Order price #{order.price} outside grid range" \
    if order.price < bot.lower_price || order.price > bot.upper_price
end
puts "All open orders within grid range"
```

#### 7. Balance Snapshots Created

```ruby
snapshots = BalanceSnapshot.where(bot: bot, granularity: 'fine').order(:created_at)
puts "Balance snapshots: #{snapshots.count}"
puts "First snapshot: #{snapshots.first&.created_at}"
puts "Latest total_value: #{snapshots.last&.total_value_quote}"
# At least one snapshot every 5 minutes for the run duration
```

#### 8. Fee Handling Correct — No Base Asset Leakage

```ruby
# Verify net_quantity <= filled_quantity for all buy orders
leaking = bot.orders.where(side: 'buy', status: 'filled').select do |o|
  o.net_quantity && o.filled_quantity && o.net_quantity > o.filled_quantity
end
puts "Orders with base asset leakage: #{leaking.count}"  # Should be 0
raise "Base asset leakage detected!" if leaking.any?
```

---

## TC07-02: Reconciliation Verification During 100-Trade Run

**Priority:** P0
**Description:** Verify reconciliation runs and repairs gaps without operator intervention.

**Steps:**
```ruby
# Check Sidekiq reconciliation job history (Web UI or console)
# Or check logs for reconciliation activity:
# grep "Reconciliation" log/sidekiq.log | tail -20

# After run, verify reconciliation ran regularly
# (Should have run every 15 seconds, so ~4 runs/minute)
```

**Expected Result:**
- Reconciliation ran continuously throughout the 100-trade run
- Any gaps detected were repaired (log entries visible)
- No persistent gap lasting > 30 seconds (two reconciliation cycles)

---

## TC07-03: WebSocket Reconnection During 100-Trade Run (Optional)

**Priority:** P1
**Description:** Optionally kill and restart the WebSocket listener mid-run to verify autonomous reconnection.

**Steps:**
```bash
# After ~50 trades completed:
pkill -f ws_listener

# Wait 30 seconds
sleep 30

# Restart
bundle exec bin/ws_listener &
```

```ruby
# Rails console — verify bot still running and trades continue
sleep 60
bot.reload
puts "Bot status: #{bot.status}"  # Should be "running"
puts "Total trades: #{bot.trades.count}"  # Should have increased
```

**Expected Result:**
- Bot remains in `running` status (or pauses briefly and auto-resumes)
- Trades continue accumulating after listener restarts
- Any fills missed during the downtime are caught by reconciliation

---

## Pass/Fail Criteria Summary

| Criterion | Pass Condition |
|-----------|---------------|
| Trade count | `bot.trades.count >= 100` |
| Bot status | `bot.status == "running"` |
| Manual interventions | 0 after `Grid::Initializer.new(bot).call` |
| All trade records valid | All required fields present, sell_price > buy_price |
| No base asset leakage | `net_quantity <= filled_quantity` for all buy orders |
| Redis consistent with DB | Trade count and profit match within ±1 trade |
| Balance snapshots present | At least 1 snapshot per 5-minute period |
| Grid integrity | No levels stuck in `pending`, all open orders within range |

---

## Failure Investigation Commands

If the bot stops or trades stall, use these commands to diagnose:

```ruby
# Check recent errors
puts bot.reload.status
puts bot.stop_reason

# Check Sidekiq failed jobs
puts Sidekiq::DeadSet.new.size
Sidekiq::DeadSet.new.first(5).each { |j| puts "#{j.klass}: #{j.error_message}" }

# Check for gaps in grid
bot.grid_levels.order(:level_index).each do |l|
  active_order = l.orders.where(status: ['open', 'partially_filled']).last
  puts "Level #{l.level_index}: #{l.status}/#{l.expected_side} | order=#{active_order&.status || 'NONE'}"
end

# Check Redis state
redis = Redis.new
puts redis.get("grid:#{bot.id}:status")
puts redis.hgetall("grid:#{bot.id}:stats").inspect

# Trigger manual reconciliation
GridReconciliationWorker.perform_async(bot.id)
sleep 5
puts "After reconciliation: #{bot.reload.orders.where(status: 'open').count} open orders"
```
