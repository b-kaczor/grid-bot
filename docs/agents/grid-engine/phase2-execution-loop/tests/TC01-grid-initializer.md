# TC01 — Grid::Initializer Test Cases

**Component:** `app/services/grid/initializer.rb`
**Acceptance Criteria:** AC-001

---

## Preconditions (all test cases)

- Rails console running: `bundle exec rails c`
- Testnet credentials configured in `ExchangeAccount` record
- Redis running and accessible
- Sidekiq running with `critical` and `default` queues
- A bot record in `pending` status exists with valid configuration:
  - `pair: "ETHUSDT"`, `base_coin: "ETH"`, `quote_coin: "USDT"`
  - `lower_price`, `upper_price`, `grid_count`, `investment_amount`, `spacing_type` set
  - `status: "pending"`

---

## Unit Test Cases (RSpec coverage)

### TC01-01: Successful initialization — happy path

**Priority:** P0
**Description:** Verify that `Grid::Initializer#call` completes the full initialization flow on testnet.

**Preconditions:**
- Bot in `pending` status
- Sufficient USDT balance in testnet account for buy-side orders
- Sufficient ETH balance for sell-side orders (or enough USDT to market-buy ETH)

**Steps (Rails console):**
```ruby
bot = Bot.find(<bot_id>)
puts "Before: status=#{bot.status}, grid_levels=#{bot.grid_levels.count}, orders=#{bot.orders.count}"

result = Grid::Initializer.new(bot).call

bot.reload
puts "After: status=#{bot.status}"
puts "Grid levels: #{bot.grid_levels.count}"
puts "Orders: #{bot.orders.count}"
puts "Orders open: #{bot.orders.where(status: 'open').count}"
puts "quantity_per_level: #{bot.quantity_per_level}"
puts "Redis status: #{Redis.new.get("grid:#{bot.id}:status")}"
```

**Expected Result:**
- `bot.status == "running"`
- `bot.grid_levels.count == bot.grid_count` (or `grid_count - 1` if neutral zone skipped one)
- `bot.orders.where(status: 'open').count` equals number of buy + sell levels (not skipped)
- `bot.quantity_per_level` is a positive decimal
- Every `grid_level` has `status: "active"` or `status: "skipped"` (none left in `pending`)
- Every active `grid_level` has a non-nil `current_order_id` matching an `orders` record
- Redis key `grid:{bot_id}:status` == `"running"`
- Redis hash `grid:{bot_id}:levels` has one entry per non-skipped level

---

### TC01-02: Status transition — pending → initializing → running

**Priority:** P0
**Description:** Verify bot status transitions in the correct order.

**Steps (RSpec unit test):**
```ruby
# Stub exchange calls, verify state machine transitions
expect(bot.status).to eq("pending")
# After first step:
expect(bot.status).to eq("initializing")
# After successful completion:
expect(bot.status).to eq("running")
```

**Expected Result:**
- Bot transitions `pending → initializing` before any exchange calls
- Bot transitions `initializing → running` only after all orders are placed
- Bot never skips `initializing` state

---

### TC01-03: Order link ID format

**Priority:** P0
**Description:** Verify all placed orders have correctly formatted `order_link_id` values.

**Steps (Rails console):**
```ruby
bot = Bot.find(<bot_id>)
# After initialization:
bot.orders.each do |order|
  level = order.grid_level
  expected_pattern = /\Ag#{bot.id}-L#{level.level_index}-(B|S)-\d+\z/
  puts "#{order.order_link_id}: #{order.order_link_id.match?(expected_pattern) ? 'OK' : 'FAIL'}"
  puts "Length: #{order.order_link_id.length} (must be <= 36)"
end
```

**Expected Result:**
- Every `order_link_id` matches pattern `g{bot_id}-L{level_index}-{B|S}-{cycle_count}`
- No `order_link_id` exceeds 36 characters
- Buy orders have `B` in the ID, sell orders have `S`
- All `order_link_id` values are unique

---

### TC01-04: Batch placement — correct batching for > 20 orders

**Priority:** P0
**Description:** Verify that a grid with > 20 levels is batched correctly (max 20 per batch API call).

**Preconditions:**
- Bot with `grid_count: 50` (requires 3 batches: 20 + 20 + 10)

**Steps (RSpec unit test with stub):**
```ruby
# Stub Bybit::RestClient#batch_place_orders
# Expect it to be called exactly ceil(active_levels / 20) times
# Each call receives at most 20 orders
expect(client).to receive(:batch_place_orders).exactly(3).times.and_return(...)
```

**Steps (Rails console):**
```ruby
bot = Bot.find(<50_level_bot_id>)
Grid::Initializer.new(bot).call
bot.reload
puts "Total levels: #{bot.grid_levels.count}"
puts "Active orders: #{bot.orders.where(status: 'open').count}"
# Should equal total non-skipped levels
```

**Expected Result:**
- All non-skipped levels have placed orders
- No orders are missing due to batching boundary errors

---

### TC01-05: Instrument info stored on bot

**Priority:** P0
**Description:** Verify that instrument info fields are persisted to the bot record.

**Steps (Rails console):**
```ruby
bot = Bot.find(<bot_id>)
Grid::Initializer.new(bot).call
bot.reload
puts "tick_size: #{bot.tick_size}"
puts "min_order_qty: #{bot.min_order_qty}"
puts "min_order_amt: #{bot.min_order_amt}"
puts "base_precision: #{bot.base_precision}"
puts "quote_precision: #{bot.quote_precision}"
```

**Expected Result:**
- All instrument fields are non-nil after initialization
- Values match what Bybit returns for the symbol (can cross-check via Bybit API directly)

---

### TC01-06: Insufficient base balance — market buy triggered

**Priority:** P0
**Description:** When ETH balance is insufficient for sell-side orders, a market buy is placed.

**Preconditions:**
- Testnet account has 0 ETH, sufficient USDT
- Bot has sell-side levels requiring ETH base

**Steps (RSpec unit test with stub):**
```ruby
# Stub get_wallet_balance to return 0 ETH
# Expect place_order called with side: "Buy", order_type: "Market"
expect(client).to receive(:place_order).with(hash_including(side: "Buy", order_type: "Market"))
```

**Expected Result:**
- Market buy order is placed for the deficit amount
- Initialization continues after the market buy
- The market buy is NOT recorded as a grid order (no `Order` record, no `GridLevel` for it)

---

### TC01-07: Instrument info fetch failure — bot stays pending

**Priority:** P0
**Description:** If instrument info fetch fails, bot stays in `pending` status.

**Steps (RSpec unit test):**
```ruby
allow(client).to receive(:get_instruments_info).and_return(Exchange::Response.new(success: false, ...))
expect { Grid::Initializer.new(bot).call }.to raise_error(Grid::Initializer::Error)
bot.reload
expect(bot.status).to eq("pending")
```

**Expected Result:**
- `Grid::Initializer::Error` raised
- `bot.status` remains `"pending"` (no state change if failure before exchange interaction)

---

### TC01-08: Partial batch failure — initialization continues

**Priority:** P1
**Description:** If one order in a batch fails, the remaining orders are processed and initialization continues.

**Steps (RSpec unit test):**
```ruby
# Batch response with one order having code != "0"
batch_response = { list: [
  { orderId: "111", orderLinkId: "g1-L0-B-0", code: "0" },
  { orderId: "",    orderLinkId: "g1-L1-B-0", code: "170213", msg: "Min qty error" },
  { orderId: "333", orderLinkId: "g1-L2-B-0", code: "0" }
]}
```

**Expected Result:**
- Successful orders create `Order` records and update `grid_level` to `active`
- Failed order level has no `Order` record and `grid_level` stays `pending`
- Bot transitions to `running` (< 50% failure threshold)
- Failure is logged as a warning

---

### TC01-09: Critical failure threshold — bot transitions to error

**Priority:** P1
**Description:** If > 50% of orders fail, bot transitions to `error` status.

**Steps (RSpec unit test):**
```ruby
# All orders in batch fail (code != "0")
# Expect bot.status == "error"
```

**Expected Result:**
- `bot.status == "error"`
- Error logged with details about failure count

---

### TC01-10: Neutral zone levels skipped

**Priority:** P1
**Description:** Grid levels within the neutral zone (at current price) are marked `skipped` and no order is placed.

**Steps (Rails console):**
```ruby
bot = Bot.find(<bot_id>)
Grid::Initializer.new(bot).call
bot.reload
skipped = bot.grid_levels.where(status: 'skipped')
puts "Skipped levels: #{skipped.count}"
skipped.each { |l| puts "Level #{l.level_index}: price=#{l.price}" }
# Verify skipped levels are near current price
ticker = Bybit::RestClient.new(exchange_account: bot.exchange_account).get_tickers(symbol: bot.pair)
puts "Current price: #{ticker.data[:list].first[:lastPrice]}"
```

**Expected Result:**
- Levels within the neutral zone have `status: "skipped"`
- No `Order` records exist for skipped levels
- Skipped levels have no `current_order_id`

---

### TC01-11: Duplicate initialization rejected — already running bot

**Priority:** P1
**Description:** Calling `Grid::Initializer#call` on a bot that is already `running` raises an error.

**Steps (Rails console):**
```ruby
bot = Bot.find(<running_bot_id>)
Grid::Initializer.new(bot).call  # Should raise
```

**Expected Result:**
- `Grid::Initializer::Error` raised with message indicating invalid status
- Bot remains in `running` status unchanged

---

## Edge Cases

- **Empty grid (all levels skipped):** If the neutral zone spans the entire grid range, all levels are skipped. Bot should transition to `error` (cannot run with 0 active orders).
- **Rate limit during batches:** Initializer sleeps until rate limit resets and continues — does not raise and does not skip orders.
- **Market buy failure:** Bot transitions to `error`, initialization halts. Operator must manually fund account and re-initialize with a fresh bot record.
