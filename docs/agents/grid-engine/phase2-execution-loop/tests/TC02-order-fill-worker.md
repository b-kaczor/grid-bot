# TC02 — OrderFillWorker Test Cases

**Component:** `app/workers/order_fill_worker.rb`
**Acceptance Criteria:** AC-003, AC-004, AC-005, AC-006, AC-014

---

## Preconditions (all test cases)

- Sidekiq running with `critical` queue
- Bot in `running` status with initialized grid
- Redis hot state seeded (`grid:{bot_id}:status == "running"`)
- Test exchange account on Bybit testnet

---

## Unit Test Cases (RSpec coverage)

### TC02-01: Buy fill triggers sell counter-order at level N+1

**Priority:** P0
**Description:** When a buy order at level N fills, a sell order is placed at level N+1. (AC-003)

**Steps (RSpec unit test):**
```ruby
# Arrange
buy_order = create(:order, side: "buy", status: "open", grid_level: level_N)
order_data = {
  orderId: buy_order.exchange_order_id,
  orderLinkId: buy_order.order_link_id,
  orderStatus: "Filled",
  side: "Buy",
  cumExecQty: "0.1",
  avgPrice: "2500.00",
  cumExecFee: "0.0001",
  feeCurrency: "USDT",
  updatedTime: Time.current.to_i.to_s
}

# Expect sell order placement at level N+1 price
expect(client).to receive(:place_order).with(hash_including(
  side: "Sell",
  price: level_N_plus_1.price,
  order_type: "Limit"
)).and_return(success_response)

# Act
OrderFillWorker.new.perform(order_data.to_json)

# Assert
buy_order.reload
expect(buy_order.status).to eq("filled")
expect(buy_order.filled_quantity).to eq(BigDecimal("0.1"))
expect(buy_order.avg_fill_price).to eq(BigDecimal("2500.00"))
expect(buy_order.filled_at).to be_present

sell_order = Order.where(grid_level: level_N_plus_1, side: "sell", status: "open").last
expect(sell_order).to be_present
expect(sell_order.paired_order_id).to eq(buy_order.id)

level_N.reload
expect(level_N.status).to eq("filled")
level_N_plus_1.reload
expect(level_N_plus_1.status).to eq("active")
expect(level_N_plus_1.expected_side).to eq("sell")
```

**Expected Result:**
- Buy order updated: `status=filled`, `filled_quantity`, `avg_fill_price`, `fee`, `fee_coin`, `filled_at` all set
- Sell order created at level N+1 with `status: open`, `paired_order_id` = buy order ID
- Level N grid_level: `status=filled`
- Level N+1 grid_level: `status=active`, `expected_side=sell`

---

### TC02-02: Sell fill triggers buy counter-order at level N-1 + trade recorded

**Priority:** P0
**Description:** When a sell order at level N fills, a buy order is placed at level N-1, `cycle_count` is incremented, and a Trade record is created. (AC-004)

**Steps (RSpec unit test):**
```ruby
# Arrange: sell_order with paired_order_id pointing to a buy_order
buy_order = create(:order, side: "buy", status: "filled",
                   avg_fill_price: "2500.00", net_quantity: "0.1",
                   fee: "0.25", fee_coin: "USDT",
                   grid_level: level_N)
sell_order = create(:order, side: "sell", status: "open",
                    grid_level: level_N_plus_1,
                    paired_order_id: buy_order.id)

order_data = {
  orderId: sell_order.exchange_order_id,
  orderStatus: "Filled",
  side: "Sell",
  cumExecQty: "0.1",
  avgPrice: "2520.00",
  cumExecFee: "0.252",
  feeCurrency: "USDT",
  updatedTime: Time.current.to_i.to_s
}

OrderFillWorker.new.perform(order_data.to_json)

# Assertions
sell_order.reload
expect(sell_order.status).to eq("filled")

# Buy counter-order placed at level N
new_buy = Order.where(grid_level: level_N, side: "buy", status: "open").last
expect(new_buy).to be_present
expect(new_buy.quantity).to eq(bot.quantity_per_level)
expect(new_buy.paired_order_id).to eq(sell_order.id)

level_N_plus_1.reload
expect(level_N_plus_1.cycle_count).to eq(1)  # Incremented

trade = Trade.where(bot: bot, sell_order: sell_order).last
expect(trade).to be_present
expect(trade.buy_price).to eq(BigDecimal("2500.00"))
expect(trade.sell_price).to eq(BigDecimal("2520.00"))
expect(trade.quantity).to eq(BigDecimal("0.1"))
expect(trade.gross_profit).to eq(BigDecimal("2.00"))  # (2520 - 2500) * 0.1
expect(trade.total_fees).to eq(BigDecimal("0.502"))   # 0.25 + 0.252
expect(trade.net_profit).to eq(BigDecimal("1.498"))   # 2.00 - 0.502
expect(trade.completed_at).to be_present
```

**Expected Result:**
- Sell order marked `filled`
- Buy counter-order created at level N-1 using `bot.quantity_per_level`
- `level_N_plus_1.cycle_count` incremented by 1
- `Trade` record created with correct `buy_price`, `sell_price`, `quantity`, `gross_profit`, `total_fees`, `net_profit`

---

### TC02-03: net_quantity calculation — fee in base coin

**Priority:** P0
**Description:** When a buy order's fee is deducted in base coin (ETH), `net_quantity = filled_quantity - fee`. (AC-005)

**Steps (RSpec unit test):**
```ruby
order_data = {
  orderId: buy_order.exchange_order_id,
  orderStatus: "Filled",
  side: "Buy",
  cumExecQty: "0.10000000",
  avgPrice: "2500.00",
  cumExecFee: "0.00010000",  # Fee in ETH (base coin)
  feeCurrency: "ETH",
  updatedTime: Time.current.to_i.to_s
}

OrderFillWorker.new.perform(order_data.to_json)

buy_order.reload
expect(buy_order.fee_coin).to eq("ETH")
expect(buy_order.net_quantity).to eq(BigDecimal("0.09990000"))  # 0.1 - 0.0001
```

**Expected Result:**
- `net_quantity = 0.09990000` (fee subtracted from quantity)
- Sell counter-order uses `net_quantity` as quantity, NOT `filled_quantity`
- This prevents base asset leakage (selling more than we hold)

---

### TC02-04: net_quantity calculation — fee in quote coin

**Priority:** P0
**Description:** When a buy order's fee is in quote coin (USDT), `net_quantity = filled_quantity`.

**Steps (RSpec unit test):**
```ruby
order_data = {
  cumExecQty: "0.10000000",
  cumExecFee: "0.25",
  feeCurrency: "USDT",
  ...
}

OrderFillWorker.new.perform(order_data.to_json)

buy_order.reload
expect(buy_order.net_quantity).to eq(BigDecimal("0.10000000"))  # No subtraction
```

**Expected Result:**
- `net_quantity == filled_quantity` when fee is in quote coin

---

### TC02-05: Idempotency — duplicate fill message skipped

**Priority:** P0
**Description:** Processing the same fill message twice results in exactly one DB update and one counter-order. (AC-014)

**Steps (RSpec unit test):**
```ruby
order_data_json = { orderId: buy_order.exchange_order_id, orderStatus: "Filled", ... }.to_json

# Simulate duplicate WS message
OrderFillWorker.new.perform(order_data_json)
OrderFillWorker.new.perform(order_data_json)  # Second call — should be no-op

# Only one sell order should exist
expect(Order.where(grid_level: level_N_plus_1, side: "sell").count).to eq(1)
expect(client).to have_received(:place_order).exactly(1).time
```

**Steps (Rails console — integration):**
```ruby
# After real fill, re-submit the same order data manually
order_data_json = bot.orders.filled.last.attributes.to_json
OrderFillWorker.new.perform(order_data_json)
# Should log "duplicate fill detected" and return without placing counter-order
puts Order.where(side: 'sell', status: 'open').count  # Count should not increase
```

**Expected Result:**
- Second call detects `order.status == "filled"` and returns immediately
- Exactly one counter-order exists
- No duplicate `Trade` records

---

### TC02-06: Optimistic locking — concurrent workers on same level

**Priority:** P0
**Description:** Two concurrent `OrderFillWorker` instances processing the same grid level result in exactly one counter-order. (AC-006)

**Steps (RSpec unit test):**
```ruby
# Simulate race: two workers read same grid_level with lock_version=0
# Worker A updates: lock_version becomes 1
# Worker B attempts update: StaleObjectError raised
# Worker B retries: sees order already filled, returns

allow_any_instance_of(GridLevel).to receive(:update!).and_wrap_original do |original, *args|
  original.call(*args)
  # Simulate concurrent update by bumping lock_version for next call
end

# Run two workers concurrently using threads
threads = 2.times.map do
  Thread.new { OrderFillWorker.new.perform(order_data_json) }
end
threads.each(&:join)

expect(Order.where(grid_level: level_N_plus_1, side: "sell").count).to eq(1)
```

**Expected Result:**
- Exactly one sell counter-order placed
- No `ActiveRecord::StaleObjectError` propagates to Sidekiq (handled internally)
- Both workers exit cleanly

---

### TC02-07: Rapid-fill race — order not yet in DB

**Priority:** P1
**Description:** If a fill event arrives for an order whose DB record was not yet committed (rapid-fill race), the worker re-enqueues with 5s delay.

**Steps (RSpec unit test):**
```ruby
# Order is NOT in DB yet
allow(Order).to receive(:find_by).and_return(nil)

# OrderLinkId matches our pattern
order_data = { orderLinkId: "g1-L5-S-2", orderStatus: "Filled", ... }

expect(OrderFillWorker).to receive(:perform_in).with(5, order_data.to_json, 1)
OrderFillWorker.new.perform(order_data.to_json, 0)
```

**Expected Result:**
- Worker re-enqueues itself with 5 second delay and `retry_count = 1`
- After 3 re-enqueues without finding the order, error is logged for manual investigation
- No counter-order placed in the meantime

---

### TC02-08: Foreign order skipped

**Priority:** P1
**Description:** Fill events for orders not matching our `ORDER_LINK_ID_PATTERN` are silently skipped.

**Steps (RSpec unit test):**
```ruby
order_data = {
  orderId: "999999",
  orderLinkId: "manual-order-123",  # Not our pattern
  orderStatus: "Filled",
  ...
}

expect { OrderFillWorker.new.perform(order_data.to_json) }.not_to raise_error
expect(client).not_to have_received(:place_order)
```

**Expected Result:**
- Worker logs a warning and returns
- No DB changes, no counter-order

---

### TC02-09: Buy at top level — no sell level above

**Priority:** P1
**Description:** When a buy fills at the highest grid level, no sell can be placed above it.

**Steps (RSpec unit test):**
```ruby
# Buy fills at the highest level (level_index = bot.grid_count - 1)
top_level = bot.grid_levels.order(:level_index).last
buy_order = create(:order, side: "buy", grid_level: top_level)

OrderFillWorker.new.perform(build_order_data(buy_order).to_json)

# No counter-order placed, warning logged
expect(client).not_to have_received(:place_order)
top_level.reload
expect(top_level.status).to eq("filled")
```

**Expected Result:**
- Warning logged: cannot place sell above top level
- Level stays `filled` — reconciliation or price recovery needed

---

### TC02-10: Sell at bottom level — no buy level below

**Priority:** P1
**Description:** When a sell fills at the lowest grid level (index 0), no buy can be placed below.

**Steps (RSpec unit test):**
```ruby
bottom_level = bot.grid_levels.order(:level_index).first
sell_order = create(:order, side: "sell", grid_level: bottom_level)

OrderFillWorker.new.perform(build_order_data(sell_order).to_json)

expect(client).not_to have_received(:place_order)
bottom_level.reload
expect(bottom_level.status).to eq("filled")
```

**Expected Result:**
- Warning logged: cannot place buy below level 0
- No counter-order placed, no crash

---

### TC02-11: Counter-order placement API failure — logged, reconciliation handles

**Priority:** P1
**Description:** If placing the counter-order fails (rate limit, API error), the fill is recorded in DB but the missing counter-order is left for reconciliation.

**Steps (RSpec unit test):**
```ruby
allow(client).to receive(:place_order).and_return(
  Exchange::Response.new(success: false, error_message: "Rate limit exceeded")
)

OrderFillWorker.new.perform(order_data_json)

# Fill is recorded
buy_order.reload
expect(buy_order.status).to eq("filled")

# But no sell order created
expect(Order.where(grid_level: level_N_plus_1, side: "sell").count).to eq(0)
# Level N+1 has no active order — gap for reconciliation
```

**Expected Result:**
- Fill recorded in DB
- Error logged at error level
- No exception propagated to Sidekiq
- Reconciliation will detect gap and place order within 15s

---

## Integration Test (Rails console — testnet)

### TC02-12: Full buy→sell cycle on testnet

**Priority:** P0
**Description:** Verify a complete buy→sell cycle executes autonomously on testnet.

**Preconditions:**
- Bot running with initialized grid on ETHUSDT testnet
- WebSocket listener running (`bundle exec bin/ws_listener`)
- Sidekiq running

**Steps:**
```ruby
# 1. Identify the lowest buy order (most likely to fill)
bot = Bot.find(<bot_id>)
buy_order = bot.orders.where(side: 'buy', status: 'open').joins(:grid_level)
                     .order('grid_levels.level_index DESC').first
puts "Watching buy order at level #{buy_order.grid_level.level_index}, price #{buy_order.price}"

# 2. Wait for price to drop to fill the order (or manually place a market sell on testnet to fill it)
# 3. Check results after fill:
sleep 10
buy_order.reload
puts "Buy status: #{buy_order.status}"  # Should be "filled"

sell_level = bot.grid_levels.find_by(level_index: buy_order.grid_level.level_index + 1)
sell_order = sell_level.orders.where(side: 'sell', status: 'open').last
puts "Sell order: #{sell_order&.exchange_order_id}"  # Should exist
puts "Sell price: #{sell_order&.price}"  # Should be sell_level.price
puts "Sell qty: #{sell_order&.quantity}"  # Should equal buy_order.net_quantity
```

**Expected Result:**
- Buy order: `status=filled`, all fill fields populated
- Sell counter-order created at level N+1
- `sell_order.paired_order_id == buy_order.id`
- Grid level N: `status=filled`
- Grid level N+1: `status=active, expected_side=sell`
- Redis `grid:{bot_id}:levels` updated for both levels
