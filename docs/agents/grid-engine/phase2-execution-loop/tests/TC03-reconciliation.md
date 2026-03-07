# TC03 — GridReconciliationWorker Test Cases

**Component:** `app/workers/grid_reconciliation_worker.rb`
**Acceptance Criteria:** AC-008

---

## Preconditions (all test cases)

- Sidekiq running with `default` queue
- Bot in `running` status with initialized grid on testnet
- Exchange account credentials configured
- Redis hot state seeded

---

## Unit Test Cases (RSpec coverage)

### TC03-01: Gap detection — missing order detected and re-placed

**Priority:** P0
**Description:** A grid level with no active order on the exchange is detected and repaired within one cycle. (AC-008)

**Steps (RSpec unit test):**
```ruby
# Arrange: grid_level has current_order_id but it's not in exchange open orders
allow(client).to receive(:get_open_orders).and_return(
  Exchange::Response.new(success: true, data: { list: [], nextPageCursor: nil })
)
allow(client).to receive(:get_order_history).and_return(
  Exchange::Response.new(success: true, data: { list: [
    { orderId: missing_order.exchange_order_id, orderStatus: "Cancelled" }
  ]})
)
expect(client).to receive(:place_order).once.and_return(success_response)

# Act
GridReconciliationWorker.new.perform(bot.id)

# Assert
grid_level.reload
expect(grid_level.status).to eq("active")
expect(grid_level.current_order_id).not_to eq(missing_order.exchange_order_id)
```

**Expected Result:**
- Gap detected: level has no open order on exchange
- Order history queried to determine fate (cancelled)
- New order placed for the gap level
- Grid level updated with new order ID

---

### TC03-02: Missing order was filled — fill processed

**Priority:** P0
**Description:** If a missing order was actually filled (missed by WebSocket), reconciliation triggers `OrderFillWorker`.

**Steps (RSpec unit test):**
```ruby
# Order history shows the order was filled
allow(client).to receive(:get_order_history).and_return(
  Exchange::Response.new(success: true, data: { list: [
    {
      orderId: missing_order.exchange_order_id,
      orderStatus: "Filled",
      side: "Buy",
      cumExecQty: "0.1",
      avgPrice: "2500.00",
      cumExecFee: "0.25",
      feeCurrency: "USDT"
    }
  ]})
)

expect(OrderFillWorker).to receive(:perform_async).with(anything)

GridReconciliationWorker.new.perform(bot.id)
```

**Expected Result:**
- `OrderFillWorker` enqueued with fill data from order history
- Fill processed same as a real-time WebSocket fill

---

### TC03-03: Orphan adoption — order on exchange not in DB

**Priority:** P0
**Description:** An order on the exchange matching our `ORDER_LINK_ID_PATTERN` but not in DB is adopted (DB records created).

**Steps (RSpec unit test):**
```ruby
# Exchange has an order not present in our DB
orphan_data = {
  orderId: "exchange_orphan_123",
  orderLinkId: "g#{bot.id}-L3-S-1",  # Our pattern, our bot
  side: "Sell",
  price: "2520.00",
  qty: "0.1",
  orderStatus: "New"
}

allow(client).to receive(:get_open_orders).and_return(
  Exchange::Response.new(success: true, data: { list: [orphan_data], nextPageCursor: nil })
)

GridReconciliationWorker.new.perform(bot.id)

# DB record should now exist
adopted_order = Order.find_by(exchange_order_id: "exchange_orphan_123")
expect(adopted_order).to be_present
expect(adopted_order.status).to eq("open")
expect(adopted_order.grid_level.level_index).to eq(3)
```

**Expected Result:**
- Orphan order matching our bot's pattern is adopted
- `Order` record created with correct fields
- `grid_level` updated with `current_order_id` and `status=active`
- Adoption logged

---

### TC03-04: Orphan cancellation — foreign order on exchange

**Priority:** P1
**Description:** An order on the exchange NOT matching our pattern is cancelled.

**Steps (RSpec unit test):**
```ruby
foreign_orphan = { orderId: "foreign_999", orderLinkId: "manual-trade", side: "Buy", ... }
allow(client).to receive(:get_open_orders).and_return(...)
expect(client).to receive(:cancel_order).with(hash_including(order_id: "foreign_999"))

GridReconciliationWorker.new.perform(bot.id)
```

**Expected Result:**
- Foreign order cancelled on exchange
- No DB record created for the foreign order
- Cancellation logged as a warning

---

### TC03-05: Scheduled mode — all running bots reconciled

**Priority:** P0
**Description:** When called with no arguments, reconciliation runs for all running bots.

**Steps (RSpec unit test):**
```ruby
bot1 = create(:bot, status: "running")
bot2 = create(:bot, status: "running")
paused_bot = create(:bot, status: "paused")

expect_any_instance_of(GridReconciliationWorker).to receive(:reconcile).with(bot1)
expect_any_instance_of(GridReconciliationWorker).to receive(:reconcile).with(bot2)
expect_any_instance_of(GridReconciliationWorker).not_to receive(:reconcile).with(paused_bot)

GridReconciliationWorker.new.perform  # No args
```

**Expected Result:**
- Exactly 2 bots reconciled (running bots only)
- Paused bot not touched

---

### TC03-06: On-demand mode — single bot reconciled

**Priority:** P0
**Description:** When called with a `bot_id`, only that bot is reconciled.

**Steps (RSpec unit test):**
```ruby
GridReconciliationWorker.new.perform(bot.id)
# Only bot.id is reconciled, not other bots
```

**Steps (Rails console):**
```ruby
GridReconciliationWorker.new.perform(Bot.running.first.id)
puts "Reconciliation complete for bot #{Bot.running.first.id}"
```

**Expected Result:**
- Only the specified bot is reconciled

---

### TC03-07: Gap repair — placed order matches correct side

**Priority:** P0
**Description:** A gap level has its replacement order placed with the correct `expected_side`.

**Steps (RSpec unit test):**
```ruby
# Level expects a buy order but has no active order
gap_level = create(:grid_level, bot: bot, expected_side: "buy", status: "filled",
                   current_order_id: nil)

allow(client).to receive(:get_open_orders).and_return(
  Exchange::Response.new(success: true, data: { list: [], nextPageCursor: nil })
)

expect(client).to receive(:place_order).with(hash_including(side: "Buy"))

GridReconciliationWorker.new.perform(bot.id)
```

**Expected Result:**
- Gap level gets a buy order (not sell)
- New `Order` record created
- Grid level `status=active`

---

### TC03-08: Pagination — fetches all open orders across pages

**Priority:** P1
**Description:** When exchange has > 50 open orders, all pages are fetched before comparing.

**Steps (RSpec unit test):**
```ruby
# Page 1: 50 orders with cursor
# Page 2: 10 orders with no cursor
allow(client).to receive(:get_open_orders)
  .with(hash_including(cursor: nil)).and_return(page1_response_with_cursor)
  .with(hash_including(cursor: "next_cursor")).and_return(page2_response_no_cursor)

GridReconciliationWorker.new.perform(bot.id)
# Should process all 60 orders, not just the first 50
```

**Expected Result:**
- Both pages fetched
- All 60 orders compared against DB state
- No false gap detections for orders on page 2

---

### TC03-09: Redis hot state refreshed after reconciliation

**Priority:** P1
**Description:** After reconciliation completes, Redis hot state is refreshed from DB truth. (AC-011 dependency)

**Steps (RSpec unit test):**
```ruby
# Manually corrupt Redis state
redis.hset("grid:#{bot.id}:levels", "3", '{"status":"filled"}')

GridReconciliationWorker.new.perform(bot.id)

# Redis should now reflect DB truth
level_3_data = Oj.load(redis.hget("grid:#{bot.id}:levels", "3"))
expect(level_3_data["status"]).to eq("active")  # Matches DB
```

**Expected Result:**
- Redis `grid:{bot_id}:levels` hash updated to match DB state
- Redis `grid:{bot_id}:stats` updated with current trade_count and realized_profit

---

### TC03-10: Partial fill handling — > 95% fill cancelled and processed

**Priority:** P1
**Description:** Orders in `PartiallyFilled` state for > 10 minutes with >= 95% fill are cancelled and processed as full fills.

**Steps (RSpec unit test):**
```ruby
# Order has been partially filled for > 10 minutes, 97% complete
stale_partial = create(:order, status: "partially_filled",
                        quantity: "0.1", filled_quantity: "0.097",
                        placed_at: 11.minutes.ago)

allow(client).to receive(:get_open_orders).and_return(
  Exchange::Response.new(success: true, data: { list: [
    { orderId: stale_partial.exchange_order_id, orderStatus: "PartiallyFilled",
      cumExecQty: "0.097", qty: "0.1", updatedTime: 11.minutes.ago.to_i.to_s }
  ], nextPageCursor: nil })
)

expect(client).to receive(:cancel_order).with(hash_including(order_id: stale_partial.exchange_order_id))
expect(OrderFillWorker).to receive(:perform_async)

GridReconciliationWorker.new.perform(bot.id)
```

**Expected Result:**
- Order cancelled on exchange
- OrderFillWorker enqueued with `cumExecQty` as the fill amount

---

## Integration Test (Rails console — testnet)

### TC03-11: Simulate missed fill — kill WebSocket listener and verify recovery

**Priority:** P0
**Description:** Verify that a fill missed by the WebSocket listener is detected and processed by reconciliation within 15 seconds. (AC-008)

**Preconditions:**
- Bot running on testnet with active grid
- WebSocket listener process running

**Steps:**
```bash
# Terminal 1: stop the WebSocket listener
pkill -f ws_listener

# Terminal 2: on testnet Bybit, place a market sell to fill one of the bot's buy orders
# (or wait for natural price movement)
```

```ruby
# Terminal 3: Rails console — watch for recovery
bot = Bot.find(<bot_id>)
initial_filled = bot.orders.where(status: 'filled').count

# Wait for next reconciliation cycle (up to 15 seconds)
sleep 20

bot.orders.reload
puts "Filled orders before: #{initial_filled}"
puts "Filled orders after: #{bot.orders.where(status: 'filled').count}"
puts "New sell orders: #{bot.orders.where(status: 'open', side: 'sell').count}"
```

```bash
# Restart WebSocket listener
bundle exec bin/ws_listener &
```

**Expected Result:**
- Within 15 seconds of the fill occurring, reconciliation detects the missed fill
- `OrderFillWorker` is enqueued and processes the fill
- Sell counter-order is placed
- Bot continues operating without manual intervention
