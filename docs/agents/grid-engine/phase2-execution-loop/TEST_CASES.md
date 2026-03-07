# Phase 2: The Execution Loop — Test Cases

## Overview

These test cases cover all Phase 2 components. Since Phase 2 is backend-only (no UI, Rails console only), test cases are organized as:

- **Unit tests** — RSpec specs with mocked exchange calls
- **Console integration tests** — commands to run in Rails console against Bybit testnet

**Branch:** `phase2-execution-loop`

---

## Common Preconditions

- Rails app running with Phase 2 migrations applied (`bundle exec rails db:migrate`)
- PostgreSQL, Redis, and Sidekiq (`critical` + `default` queues) running
- `ExchangeAccount` record configured with Bybit testnet API credentials
- Environment variables set: `BYBIT_TESTNET_API_KEY`, `BYBIT_TESTNET_API_SECRET`, `REDIS_URL`
- Bybit testnet account: "Fee deduction using other coin" **disabled** in account settings

---

## Grid::Initializer (AC-001)

### TC-01: Happy path — pending bot → running, all orders placed, grid_levels + orders in DB

**Priority:** P0
**Preconditions:**
- Bot record in `pending` status with valid configuration (`pair: "ETHUSDT"`, grid_count, investment_amount, etc.)
- Sufficient USDT balance for buy-side orders
- Sufficient ETH balance for sell-side orders (or USDT for market buy)

**Steps:**
```ruby
bot = Bot.find(<bot_id>)
result = Grid::Initializer.new(bot).call
bot.reload
```

**Expected Result:**
- `bot.status == "running"`
- `bot.quantity_per_level` is a positive decimal (set during init)
- `bot.grid_levels.count == bot.grid_count` (minus any neutral-zone skips)
- Every non-skipped `grid_level` has `status: "active"` and a non-nil `current_order_id`
- Every active `grid_level` has a corresponding `Order` record with `status: "open"`
- Every `order.order_link_id` matches pattern `g{bot_id}-L{level_index}-{B|S}-{cycle_count}` and is ≤ 36 chars
- `bot.tick_size`, `bot.min_order_qty`, `bot.min_order_amt`, `bot.base_precision` are all non-nil
- Redis `grid:{bot_id}:status` == `"running"`
- Redis `grid:{bot_id}:levels` hash has one entry per non-skipped level

**RSpec stub hint:**
```ruby
expect(client).to receive(:get_instruments_info).and_return(instrument_response)
expect(client).to receive(:get_tickers).and_return(ticker_response)
expect(client).to receive(:batch_place_orders).and_return(batch_success_response)
```

---

### TC-02: Partial batch failure (< 50%) — bot reaches running, gaps logged

**Priority:** P1
**Preconditions:**
- Bot in `pending` status with 10-level grid

**Steps (RSpec unit test):**
```ruby
# Batch response: 8 of 10 orders succeed, 2 fail (code != "0")
batch_response = { list: [
  { orderId: "1", orderLinkId: "g1-L0-B-0", code: "0" },
  { orderId: "",  orderLinkId: "g1-L1-B-0", code: "170213", msg: "Min qty" },
  # ... 8 more, 1 more failure
]}
allow(client).to receive(:batch_place_orders).and_return(...)
Grid::Initializer.new(bot).call
```

**Expected Result:**
- `bot.status == "running"` (failure rate < 50%)
- Successful orders have `Order` records and `grid_level.status == "active"`
- Failed order levels have no `Order` record; `grid_level` remains `pending`
- Failures logged as warnings
- Reconciliation will detect and fill gaps on next cycle

---

### TC-03: Partial batch failure (> 50%) — bot transitions to error

**Priority:** P1
**Preconditions:**
- Bot in `pending` status; > 50% of batch orders fail

**Steps (RSpec unit test):**
```ruby
# All orders fail
allow(client).to receive(:batch_place_orders).and_return(all_failed_batch_response)
expect { Grid::Initializer.new(bot).call }.to raise_error(Grid::Initializer::Error)
bot.reload
```

**Expected Result:**
- `bot.status == "error"`
- Error logged with failure count details
- No transition to `running`

---

### TC-04: Insufficient base balance — market buy placed, then grid initialized

**Priority:** P0
**Preconditions:**
- Testnet account has 0 ETH, sufficient USDT
- Bot has sell-side levels requiring ETH base

**Steps (RSpec unit test):**
```ruby
allow(client).to receive(:get_wallet_balance).and_return(zero_eth_response)
expect(client).to receive(:place_order).with(hash_including(
  side: "Buy",
  order_type: "Market"
)).and_return(market_buy_success)
# Initialization continues after market buy
Grid::Initializer.new(bot).call
bot.reload
```

**Steps (Rails console):**
```ruby
# Before: check ETH balance is 0
# Run initializer — should place market buy then place grid orders
Grid::Initializer.new(bot).call
puts bot.reload.status  # "running"
puts bot.orders.count   # All grid orders present
```

**Expected Result:**
- Market buy placed for the ETH deficit
- Market buy is NOT recorded as a `grid_level` or `Order` record (infrastructure buy)
- Initialization completes normally; `bot.status == "running"`

---

### TC-05: Instrument info fetch failure — bot stays pending, error raised

**Priority:** P0
**Preconditions:**
- Exchange API returns error on instrument info fetch

**Steps (RSpec unit test):**
```ruby
allow(client).to receive(:get_instruments_info).and_return(
  Exchange::Response.new(success: false, error_message: "Symbol not found")
)
expect { Grid::Initializer.new(bot).call }.to raise_error(Grid::Initializer::Error)
bot.reload
```

**Expected Result:**
- `Grid::Initializer::Error` raised
- `bot.status` remains `"pending"` (no state change before exchange interaction)
- No `grid_level` or `Order` records created

---

## WebSocket Listener (AC-002, AC-009, AC-010, AC-013)

### TC-06: Connects and authenticates to testnet private stream

**Priority:** P0
**Preconditions:**
- Valid testnet API key and secret
- Network access to `wss://stream-testnet.bybit.com/v5/private`

**Steps (RSpec unit test):**
```ruby
expect(ws).to receive(:write).with(hash_including(
  op: "auth",
  args: [api_key, anything, anything]  # [key, expires_ms, hmac_signature]
))
allow(ws).to receive(:read).and_return(
  Oj.dump({ op: "auth", success: true }),
  Oj.dump({ op: "subscribe", success: true }),
  nil
)
listener.run  # Should not raise
```

**Steps (integration — bash):**
```bash
WS_LOG_LEVEL=debug bundle exec bin/ws_listener
# Observe: "Auth success" and "Subscribed to order.spot, execution.spot, wallet" in logs
```

**Expected Result:**
- Auth frame: `{ op: "auth", args: [api_key, expires, signature] }`
- `expires` = current time in ms + 5000
- `signature = HMAC_SHA256(api_secret, "GET/realtime#{expires}")`
- Subscribe frame sent after auth: `{ op: "subscribe", args: ["order.spot", "execution.spot", "wallet"] }`
- Listener does not raise or exit

---

### TC-07: Fill event → OrderFillWorker enqueued + Redis stream published

**Priority:** P0
**Preconditions:**
- Listener connected and authenticated

**Steps (RSpec unit test):**
```ruby
fill_message = Oj.dump({
  topic: "order.spot",
  data: [{
    orderId: "123456", orderLinkId: "g1-L5-B-0",
    symbol: "ETHUSDT", side: "Buy", orderStatus: "Filled",
    cumExecQty: "0.1", avgPrice: "2500.00",
    cumExecFee: "0.25", feeCurrency: "USDT",
    updatedTime: Time.current.to_i.to_s
  }]
})
allow(ws).to receive(:read).and_return(fill_message, nil)

expect(OrderFillWorker).to receive(:perform_async).with(anything).once
expect(redis).to receive(:xadd).with("grid:fills", anything).once

listener.run
```

**Expected Result:**
- `OrderFillWorker.perform_async` called once with the order data JSON
- Redis stream `grid:fills` receives one entry containing `order_id`, `symbol`, `side`, `qty`, `price`
- Stream capped at 10,000 entries (`MAXLEN ~ 10000`)

---

### TC-08: Non-fill order.spot event → ignored (not enqueued)

**Priority:** P1
**Preconditions:**
- Listener connected and authenticated

**Steps (RSpec unit test):**
```ruby
non_fill_statuses = %w[New PartiallyFilled Cancelled Rejected]
non_fill_statuses.each do |status|
  msg = Oj.dump({ topic: "order.spot", data: [{ orderStatus: status, orderId: "999" }] })
  allow(ws).to receive(:read).and_return(msg, nil)

  expect(OrderFillWorker).not_to receive(:perform_async)
  listener.run
end
```

**Expected Result:**
- No `OrderFillWorker` enqueue for `New`, `PartiallyFilled`, `Cancelled`, or `Rejected` statuses
- No Redis stream entry written for non-fill events

---

### TC-09: Connection drop → exponential backoff reconnect

**Priority:** P1
**Preconditions:**
- Listener running; connection drops mid-session

**Steps (RSpec unit test):**
```ruby
allow(listener).to receive(:connect_and_listen).and_raise(StandardError, "Connection refused")

expect(listener).to receive(:sleep).with(1).ordered
expect(listener).to receive(:sleep).with(2).ordered
expect(listener).to receive(:sleep).with(4).ordered
expect(listener).to receive(:sleep).with(8).ordered
expect(listener).to receive(:sleep).with(16).ordered
expect(listener).to receive(:sleep).with(30).ordered  # Capped at 30
```

**Expected Result:**
- Backoff sequence: 1s, 2s, 4s, 8s, 16s, 30s (never exceeds 30s)
- Each reconnect attempt logs the backoff duration
- On successful reconnect, backoff resets to 1s

---

### TC-10: Reconnect → GridReconciliationWorker triggered for all running bots

**Priority:** P1
**Preconditions:**
- Two bots in `running` status; one in `paused`

**Steps (RSpec unit test):**
```ruby
bot1 = create(:bot, status: "running")
bot2 = create(:bot, status: "running")
paused = create(:bot, status: "paused")

allow(listener).to receive(:connect_and_listen)
  .and_raise(StandardError).once
  .and_return(nil)

expect(GridReconciliationWorker).to receive(:perform_async).with(bot1.id)
expect(GridReconciliationWorker).to receive(:perform_async).with(bot2.id)
expect(GridReconciliationWorker).not_to receive(:perform_async).with(paused.id)

listener.connect_with_reconnect
```

**Expected Result:**
- `GridReconciliationWorker.perform_async(bot_id)` called for each running bot on reconnect
- Paused bot not included
- Triggered immediately on reconnect, not waiting for cron interval

---

### TC-11: WS close code 1001 → all running bots set to paused

**Priority:** P1
**Preconditions:**
- Two bots in `running` status

**Steps (RSpec unit test):**
```ruby
bot1 = create(:bot, status: "running")
bot2 = create(:bot, status: "running")

allow(ws).to receive(:read).and_raise(
  Async::WebSocket::ClosedError.new(code: 1001, reason: "Going Away")
)

listener.run

[bot1, bot2].each(&:reload)
expect(bot1.status).to eq("paused")
expect(bot1.stop_reason).to eq("maintenance")
expect(bot2.status).to eq("paused")
expect(bot2.stop_reason).to eq("maintenance")
expect(redis.get("grid:#{bot1.id}:status")).to eq("paused")
expect(redis.get("grid:#{bot2.id}:status")).to eq("paused")
```

**Expected Result:**
- All running bots: `status=paused, stop_reason="maintenance"`
- Redis `grid:{bot_id}:status` updated to `"paused"` for each bot
- Listener enters maintenance retry loop (every 30s)

---

### TC-12: Connectivity restored → maintenance-paused bots resume + reconciliation triggered

**Priority:** P1
**Preconditions:**
- Bots paused with `stop_reason: "maintenance"`

**Steps (RSpec unit test):**
```ruby
bot = create(:bot, status: "paused", stop_reason: "maintenance")

listener.resume_after_maintenance

bot.reload
expect(bot.status).to eq("running")
expect(bot.stop_reason).to be_nil
expect(redis.get("grid:#{bot.id}:status")).to eq("running")
expect(GridReconciliationWorker).to have_received(:perform_async).with(bot.id)
```

**Expected Result:**
- Bots with `stop_reason: "maintenance"` set back to `running` with `stop_reason: nil`
- Redis status updated to `"running"` for each resumed bot
- Reconciliation enqueued for each resumed bot

---

### TC-13: SIGTERM → graceful shutdown (no orphaned async tasks)

**Priority:** P1
**Preconditions:**
- `bin/ws_listener` running and connected to testnet

**Steps (bash):**
```bash
bundle exec bin/ws_listener &
WS_PID=$!
sleep 3
kill -TERM $WS_PID
wait $WS_PID
echo "Exit code: $?"
```

**Expected Result:**
- Process exits with code 0
- Log shows "Shutting down gracefully" (or equivalent)
- WebSocket close frame sent to Bybit before exit
- All async tasks (heartbeat, read loop) cancelled cleanly
- No `Sidekiq::DeadSet` jobs from in-flight enqueues
- Process exits within 5 seconds of SIGTERM

---

## OrderFillWorker (AC-003, AC-004, AC-005, AC-006, AC-014)

### TC-14: Buy fill → sell counter-order placed at N+1, Order record created, paired_order_id set

**Priority:** P0
**Preconditions:**
- Bot running with initialized grid; buy order open at level N
- Level N+1 exists with a price above level N

**Steps (RSpec unit test):**
```ruby
buy_order = create(:order, side: "buy", status: "open", grid_level: level_N)
order_data = {
  orderId: buy_order.exchange_order_id, orderStatus: "Filled", side: "Buy",
  cumExecQty: "0.1", avgPrice: "2500.00", cumExecFee: "0.25",
  feeCurrency: "USDT", updatedTime: Time.current.to_i.to_s
}
expect(client).to receive(:place_order).with(hash_including(
  side: "Sell", price: level_N_plus_1.price, order_type: "Limit"
)).and_return(sell_success_response)

OrderFillWorker.new.perform(order_data.to_json)
```

**Expected Result:**
- `buy_order.reload.status == "filled"` with `filled_quantity`, `avg_fill_price`, `fee`, `fee_coin`, `filled_at` all set
- New `Order` record exists: `side: "sell"`, `status: "open"`, `grid_level: level_N_plus_1`
- `sell_order.paired_order_id == buy_order.id`
- `level_N.reload.status == "filled"`
- `level_N_plus_1.reload.status == "active"`, `expected_side == "sell"`
- Redis `grid:{bot_id}:levels` updated for both levels

---

### TC-15: Sell fill → buy counter-order placed at N-1, Trade record created with correct net_profit

**Priority:** P0
**Preconditions:**
- Sell order at level N+1 with `paired_order_id` linking to a filled buy order at level N

**Steps (RSpec unit test):**
```ruby
buy_order  = create(:order, side: "buy",  status: "filled",
                    avg_fill_price: "2500.00", net_quantity: "0.1",
                    fee: "0.25", fee_coin: "USDT", grid_level: level_N)
sell_order = create(:order, side: "sell", status: "open",
                    grid_level: level_N_plus_1, paired_order_id: buy_order.id)

order_data = {
  orderId: sell_order.exchange_order_id, orderStatus: "Filled", side: "Sell",
  cumExecQty: "0.1", avgPrice: "2520.00", cumExecFee: "0.252",
  feeCurrency: "USDT", updatedTime: Time.current.to_i.to_s
}

OrderFillWorker.new.perform(order_data.to_json)
```

**Expected Result:**
- `sell_order.reload.status == "filled"`
- Buy counter-order created at level N: `quantity == bot.quantity_per_level`, `paired_order_id == sell_order.id`
- `level_N_plus_1.reload.cycle_count == 1` (incremented)
- `Trade` record created with:
  - `buy_price: 2500.00`, `sell_price: 2520.00`, `quantity: 0.1`
  - `gross_profit: 2.00` ( (2520-2500) × 0.1 )
  - `total_fees: 0.502` ( 0.25 + 0.252 )
  - `net_profit: 1.498` ( 2.00 - 0.502 )
  - `completed_at` present

---

### TC-16: fee_coin == base_coin on buy → net_quantity = filled_qty - fee (not full qty)

**Priority:** P0
**Preconditions:**
- Buy order fills with fee in ETH (base coin)

**Steps (RSpec unit test):**
```ruby
order_data = {
  orderId: buy_order.exchange_order_id, orderStatus: "Filled", side: "Buy",
  cumExecQty: "0.10000000", avgPrice: "2500.00",
  cumExecFee: "0.00010000", feeCurrency: "ETH",  # Fee in base coin
  updatedTime: Time.current.to_i.to_s
}

OrderFillWorker.new.perform(order_data.to_json)

buy_order.reload
```

**Expected Result:**
- `buy_order.fee_coin == "ETH"`
- `buy_order.net_quantity == BigDecimal("0.09990000")` (0.1 - 0.0001)
- Sell counter-order quantity == `buy_order.net_quantity` (0.09990000), NOT `filled_quantity` (0.1)
- This prevents selling more ETH than was received after fee deduction

---

### TC-17: fee_coin == quote_coin on buy → net_quantity = filled_qty

**Priority:** P0
**Preconditions:**
- Buy order fills with fee in USDT (quote coin)

**Steps (RSpec unit test):**
```ruby
order_data = {
  cumExecQty: "0.10000000", cumExecFee: "0.25", feeCurrency: "USDT",
  ...
}
OrderFillWorker.new.perform(order_data.to_json)
buy_order.reload
```

**Expected Result:**
- `buy_order.net_quantity == BigDecimal("0.10000000")` (no subtraction)
- Fee is in quote coin; full filled quantity is available as base

---

### TC-18: Duplicate WS message → idempotency check, no duplicate processing

**Priority:** P0
**Preconditions:**
- Same fill message delivered twice (simulating WS deduplication failure)

**Steps (RSpec unit test):**
```ruby
order_data_json = build_order_data(buy_order).to_json

OrderFillWorker.new.perform(order_data_json)  # First: processes fill
OrderFillWorker.new.perform(order_data_json)  # Second: idempotency check
```

**Expected Result:**
- After second call: `order.status == "filled"` (already set by first)
- Second call detects `order.status == "filled"` and returns immediately with a log message
- `Order.where(grid_level: level_N_plus_1, side: "sell").count == 1` (exactly one counter-order)
- No duplicate `Trade` records
- `client.place_order` called exactly once total

---

### TC-19: Two concurrent workers on same level → exactly one counter-order (StaleObjectError retry)

**Priority:** P0
**Preconditions:**
- Same fill data enqueued twice simultaneously (e.g., WS reconnect race)

**Steps (RSpec unit test):**
```ruby
# Simulate optimistic locking race: Worker A commits, Worker B gets StaleObjectError
results = []
threads = 2.times.map do
  Thread.new do
    results << OrderFillWorker.new.perform(order_data_json)
  rescue => e
    results << e
  end
end
threads.each(&:join)

# Only one sell order should exist
expect(Order.where(grid_level: level_N_plus_1, side: "sell").count).to eq(1)
expect(client).to have_received(:place_order).exactly(1).time
```

**Expected Result:**
- Exactly one sell counter-order placed
- `ActiveRecord::StaleObjectError` caught internally (not propagated to Sidekiq)
- Losing worker detects that the order is already `filled` on retry and exits cleanly
- No Sidekiq dead-set jobs created

---

### TC-20: Order not found, matches our pattern → re-enqueued with 5s delay

**Priority:** P1
**Preconditions:**
- Fill arrives for an order not yet in DB (rapid-fill race: counter-order placed on exchange before DB commit)

**Steps (RSpec unit test):**
```ruby
allow(Order).to receive(:find_by).and_return(nil)
order_data = { orderLinkId: "g1-L5-S-2", orderStatus: "Filled", ... }

expect(OrderFillWorker).to receive(:perform_in).with(5, order_data.to_json, 1)
OrderFillWorker.new.perform(order_data.to_json, 0)  # retry_count=0
```

**Expected Result:**
- Worker re-enqueues itself with 5s delay and `retry_count=1`
- After 3 re-enqueues (retry_count reaches 3) without finding the order: error logged for manual investigation, no further re-enqueue
- No counter-order placed during re-enqueue phase

---

### TC-21: Buy fills at top level → warning logged, no sell placed

**Priority:** P1
**Preconditions:**
- Buy fills at `level_index == bot.grid_count - 1` (highest level, no level above)

**Steps (RSpec unit test):**
```ruby
top_level = bot.grid_levels.order(:level_index).last
buy_order = create(:order, side: "buy", grid_level: top_level)

OrderFillWorker.new.perform(build_order_data(buy_order).to_json)

expect(client).not_to have_received(:place_order)
top_level.reload
```

**Expected Result:**
- No sell order placed (no level N+1 exists)
- Warning logged: "Cannot place sell counter-order above top level"
- `top_level.status == "filled"` (fill recorded in DB)
- No exception raised; worker exits cleanly

---

### TC-22: Sell fills at bottom level → warning logged, no buy placed

**Priority:** P1
**Preconditions:**
- Sell fills at `level_index == 0` (lowest level, no level below)

**Steps (RSpec unit test):**
```ruby
bottom_level = bot.grid_levels.order(:level_index).first
sell_order = create(:order, side: "sell", grid_level: bottom_level)

OrderFillWorker.new.perform(build_order_data(sell_order).to_json)

expect(client).not_to have_received(:place_order)
bottom_level.reload
```

**Expected Result:**
- No buy order placed (no level N-1 exists)
- Warning logged: "Cannot place buy counter-order below level 0"
- `bottom_level.status == "filled"`
- No exception raised

---

## GridReconciliationWorker (AC-008)

### TC-23: Missing order (filled on exchange) → OrderFillWorker enqueued within 15s

**Priority:** P0
**Preconditions:**
- Bot running on testnet; WebSocket listener stopped temporarily (simulating missed fill)
- An order fills on exchange while listener is down

**Steps (Rails console — integration):**
```bash
pkill -f ws_listener  # Stop listener
# Fill occurs on testnet (price moves, order fills)
```
```ruby
initial_filled = bot.orders.where(status: 'filled').count
sleep 20  # Wait for at least one reconciliation cycle (15s interval)
bot.reload
puts "New filled orders: #{bot.orders.where(status: 'filled').count - initial_filled}"
puts "New open orders: #{bot.orders.where(status: 'open').count}"
```

**Steps (RSpec unit test):**
```ruby
allow(client).to receive(:get_open_orders).and_return(empty_response)
allow(client).to receive(:get_order_history).and_return(
  Exchange::Response.new(success: true, data: { list: [{
    orderId: missing_order.exchange_order_id, orderStatus: "Filled",
    side: "Buy", cumExecQty: "0.1", avgPrice: "2500.00",
    cumExecFee: "0.25", feeCurrency: "USDT"
  }]})
)
expect(OrderFillWorker).to receive(:perform_async).with(anything)
GridReconciliationWorker.new.perform(bot.id)
```

**Expected Result:**
- Within 15 seconds: `OrderFillWorker` enqueued with fill data from order history
- Missed fill processed identically to a real-time WebSocket fill
- Sell counter-order placed; grid continues autonomously

---

### TC-24: Missing order (cancelled on exchange) → marked cancelled in DB

**Priority:** P1
**Preconditions:**
- Order active in DB but cancelled on exchange

**Steps (RSpec unit test):**
```ruby
allow(client).to receive(:get_open_orders).and_return(empty_response)
allow(client).to receive(:get_order_history).and_return(
  Exchange::Response.new(success: true, data: { list: [{
    orderId: missing_order.exchange_order_id, orderStatus: "Cancelled"
  }]})
)
GridReconciliationWorker.new.perform(bot.id)
missing_order.reload
```

**Expected Result:**
- `missing_order.status == "cancelled"`
- No `OrderFillWorker` enqueued (it was cancelled, not filled)
- Grid gap for that level is detected and repaired (new order placed)

---

### TC-25: Orphan order matching our pattern → ADOPTED (DB records created)

**Priority:** P0
**Preconditions:**
- Exchange has an open order with `orderLinkId` matching `g{bot_id}-L{N}-{B|S}-{cycle}` that is not in DB

**Steps (RSpec unit test):**
```ruby
orphan = {
  orderId: "exchange_orphan_999",
  orderLinkId: "g#{bot.id}-L3-S-1",
  side: "Sell", price: "2520.00", qty: "0.1", orderStatus: "New"
}
allow(client).to receive(:get_open_orders).and_return(
  Exchange::Response.new(success: true, data: { list: [orphan], nextPageCursor: nil })
)
GridReconciliationWorker.new.perform(bot.id)
```

**Expected Result:**
- `Order.find_by(exchange_order_id: "exchange_orphan_999")` exists with `status: "open"`
- `grid_level` at index 3 updated: `current_order_id = "exchange_orphan_999"`, `status: "active"`
- Adoption logged (not treated as an error)
- Order is NOT cancelled on exchange

---

### TC-26: Orphan order not matching our pattern → cancelled on exchange

**Priority:** P1
**Preconditions:**
- Exchange has an open order with an unrecognized `orderLinkId` (not our bot's pattern)

**Steps (RSpec unit test):**
```ruby
foreign = { orderId: "foreign_888", orderLinkId: "manual-trade-abc", side: "Buy", ... }
allow(client).to receive(:get_open_orders).and_return(
  Exchange::Response.new(success: true, data: { list: [foreign], nextPageCursor: nil })
)
expect(client).to receive(:cancel_order).with(hash_including(order_id: "foreign_888"))
GridReconciliationWorker.new.perform(bot.id)
```

**Expected Result:**
- Foreign order cancelled on exchange
- No `Order` DB record created for the foreign order
- Warning logged

---

### TC-27: Grid gap → new order placed, grid_level updated

**Priority:** P0
**Preconditions:**
- A `grid_level` exists with `status: "filled"` and no active order on exchange

**Steps (RSpec unit test):**
```ruby
gap_level = create(:grid_level, bot: bot, expected_side: "buy", status: "filled",
                   current_order_id: nil)
allow(client).to receive(:get_open_orders).and_return(empty_response)
expect(client).to receive(:place_order).with(hash_including(side: "Buy"))
  .and_return(success_response)

GridReconciliationWorker.new.perform(bot.id)
gap_level.reload
```

**Expected Result:**
- New buy order placed at `gap_level.price`
- `gap_level.status == "active"`, `gap_level.current_order_id` set to new order ID
- New `Order` record created with `status: "open"`, `side: "buy"`

---

### TC-28: Self-scheduling: Redis mutex prevents duplicate reconciliation chains

**Priority:** P1
**Preconditions:**
- Reconciliation worker uses a Redis mutex to prevent overlapping runs for the same bot

**Steps (RSpec unit test):**
```ruby
# First worker acquires mutex
# Second worker (started before first completes) should skip, not run concurrently
allow(redis).to receive(:set).with("grid:reconcile:#{bot.id}:lock", anything, anything).and_return(nil)  # Lock already held

GridReconciliationWorker.new.perform(bot.id)
# Should log "reconciliation already running for bot X" and return
expect(client).not_to have_received(:get_open_orders)
```

**Expected Result:**
- If lock is already held: worker logs and returns without calling exchange API
- Lock is released after reconciliation completes (even if an error occurs)
- No duplicate reconciliation chains running in parallel for the same bot

---

### TC-29: On-demand mode (with bot_id) → does not schedule_next

**Priority:** P1
**Preconditions:**
- Worker called with explicit `bot_id` (triggered by WS reconnect, not cron)

**Steps (RSpec unit test):**
```ruby
# On-demand: should reconcile only the specified bot
# Should NOT enqueue itself for future scheduling (cron handles that)
expect(GridReconciliationWorker).not_to receive(:perform_in)
GridReconciliationWorker.new.perform(bot.id)
```

**Expected Result:**
- Only the specified bot reconciled
- No self-scheduling (no `perform_in` or `perform_async` with no args)
- Cron schedule (every 15s via Sidekiq-cron) remains the only source of scheduled runs

---

## BalanceSnapshotWorker (AC-012)

### TC-30: Snapshot created with correct total_value_quote

**Priority:** P1
**Preconditions:**
- Bot with known filled buy/sell history and a mocked current price

**Steps (RSpec unit test):**
```ruby
# 3 buys at 2500, 2400, 2300 (0.1 ETH each); 1 sell at 2520 (0.1 ETH)
# base_held = 0.2 ETH; quote_balance ≈ 532 USDT; current_price = 2450
# total_value = 532 + (0.2 * 2450) = 532 + 490 = 1022 USDT

allow(client).to receive(:get_tickers).and_return(price_response("2450.00"))
BalanceSnapshotWorker.new.perform
snapshot = BalanceSnapshot.where(bot: bot, granularity: "fine").last
```

**Expected Result:**
- `snapshot.granularity == "fine"`
- `snapshot.total_value_quote` ≈ 1022 USDT (within ±1 USDT rounding tolerance)
- `snapshot.realized_profit == bot.trades.sum(:net_profit)` exactly
- `snapshot.created_at` is recent

---

### TC-31: unrealized_pnl calculation correct with active unsold buys

**Priority:** P1
**Preconditions:**
- Bot has 2 filled buy orders (not yet sold), avg buy price = 2400; current price = 2500

**Steps (RSpec unit test):**
```ruby
# base_held = 0.2 ETH; avg_buy_price = 2400; current_price = 2500
# unrealized_pnl = (2500 - 2400) * 0.2 = 20 USDT
allow(client).to receive(:get_tickers).and_return(price_response("2500.00"))
BalanceSnapshotWorker.new.perform
snapshot = BalanceSnapshot.last
```

**Expected Result:**
- `snapshot.unrealized_pnl` ≈ 20.0 USDT
- Negative unrealized PnL is valid and stored correctly (when current price < avg buy price)

---

### TC-32: One bot failure → other bots still snapshotted

**Priority:** P1
**Preconditions:**
- Two bots in `running` status; price fetch fails for bot1, succeeds for bot2

**Steps (RSpec unit test):**
```ruby
allow(client).to receive(:get_tickers)
  .with(hash_including(symbol: bot1.pair)).and_return(Exchange::Response.new(success: false))
  .with(hash_including(symbol: bot2.pair)).and_return(price_response("2500.00"))

BalanceSnapshotWorker.new.perform

expect(BalanceSnapshot.where(bot: bot2, granularity: "fine").count).to eq(1)
expect(BalanceSnapshot.where(bot: bot1).count).to eq(0)
```

**Expected Result:**
- Bot1 failure logged as error; no snapshot for bot1
- Bot2 snapshot created successfully
- Sidekiq job completes (not marked as failed); no exception propagated

---

### TC-33: Redis hot state price updated after snapshot

**Priority:** P1
**Preconditions:**
- Bot running; Redis price key set to stale value

**Steps (RSpec unit test):**
```ruby
redis.set("grid:#{bot.id}:current_price", "2400.00")  # Stale
allow(client).to receive(:get_tickers).and_return(price_response("2500.00"))

BalanceSnapshotWorker.new.perform

expect(redis.get("grid:#{bot.id}:current_price")).to eq("2500.00")
```

**Expected Result:**
- `grid:{bot_id}:current_price` updated to the price fetched during snapshot creation

---

## Redis Hot State (AC-011)

### TC-34: After initialization — all 4 key types populated

**Priority:** P1
**Preconditions:**
- Bot initialized via `Grid::Initializer.new(bot).call`

**Steps (Rails console):**
```ruby
bot = Bot.find(<bot_id>)
redis = Redis.new

puts redis.get("grid:#{bot.id}:status")          # "running"
puts redis.get("grid:#{bot.id}:current_price")   # price string
puts redis.hgetall("grid:#{bot.id}:stats").inspect
puts redis.hgetall("grid:#{bot.id}:levels").count # == non-skipped level count
```

**Steps (RSpec unit test):**
```ruby
redis_state = Grid::RedisState.new(redis: redis)
redis_state.seed(bot)

expect(redis.get("grid:#{bot.id}:status")).to eq(bot.status)
expect(redis.ttl("grid:#{bot.id}:status")).to eq(-1)  # No expiry

stats = redis.hgetall("grid:#{bot.id}:stats")
expect(stats["realized_profit"]).to eq("0")
expect(stats["trade_count"]).to be_present
expect(stats["uptime_start"]).to be_present

levels = redis.hgetall("grid:#{bot.id}:levels")
expect(levels.count).to eq(bot.grid_levels.where.not(status: "skipped").count)
levels.each_value do |json|
  parsed = Oj.load(json)
  expect(parsed).to include("side", "status", "price", "order_id", "cycle_count")
end
```

**Expected Result:**
- All 4 key suffixes present: `status`, `current_price`, `levels`, `stats`
- Keys have no TTL (`ttl == -1`)
- `levels` hash entry count matches non-skipped grid levels
- Each level JSON has: `side`, `status`, `price`, `order_id`, `cycle_count`

---

### TC-35: After fill — levels hash updated, stats incremented

**Priority:** P1
**Preconditions:**
- Redis hot state seeded; a fill processed by `OrderFillWorker`

**Steps (RSpec unit test):**
```ruby
redis_state.seed(bot)
grid_level.update!(status: "filled")
trade = create(:trade, bot: bot, net_profit: BigDecimal("1.50"))

redis_state.update_on_fill(bot, grid_level, trade)

level_data = Oj.load(redis.hget("grid:#{bot.id}:levels", grid_level.level_index.to_s))
expect(level_data["status"]).to eq("filled")

stats = redis.hgetall("grid:#{bot.id}:stats")
expect(stats["trade_count"].to_i).to eq(1)
expect(BigDecimal(stats["realized_profit"])).to eq(bot.trades.sum(:net_profit))
```

**Expected Result:**
- Affected level entry in `grid:{bot_id}:levels` reflects new status
- `stats["trade_count"]` incremented by 1 when a `Trade` is passed (sell fill)
- `stats["realized_profit"]` updated to sum of all bot trades
- Buy fills (no trade): only the level entry updated; stats unchanged

---

### TC-36: cleanup → all keys deleted

**Priority:** P1
**Preconditions:**
- All 4 key types present in Redis for a bot

**Steps (RSpec unit test):**
```ruby
redis_state.seed(bot)
redis_state.update_price(bot.id, "2500")

# Confirm keys exist
%w[status current_price levels stats].each do |suffix|
  expect(redis.exists("grid:#{bot.id}:#{suffix}")).to eq(1)
end

redis_state.cleanup(bot.id)

# All keys deleted
%w[status current_price levels stats].each do |suffix|
  expect(redis.exists("grid:#{bot.id}:#{suffix}")).to eq(0)
end
```

**Expected Result:**
- All 4 keys deleted: `status`, `current_price`, `levels`, `stats`
- No `KEYS` scan used (explicit key deletion to avoid O(N) production scan)
- No other bot's keys affected

---

## Testnet Milestone

### TC-37: 100 autonomous trades on ETHUSDT testnet (AC-007)

**Priority:** P0

See `tests/TC07-testnet-milestone.md` for the full setup guide, monitoring commands, and pass/fail criteria.

**Summary pass criteria:**
- `bot.trades.count >= 100`
- `bot.status == "running"` throughout
- Zero manual interventions after `Grid::Initializer.new(bot).call`
- All trade records valid (`sell_price > buy_price`, all fields present)
- No base asset leakage (`net_quantity <= filled_quantity` for all buy orders)
- Redis `trade_count` and `realized_profit` consistent with DB (within ±1 trade)
