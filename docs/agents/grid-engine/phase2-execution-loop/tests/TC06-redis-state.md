# TC06 — Grid::RedisState Test Cases

**Component:** `app/services/grid/redis_state.rb`
**Acceptance Criteria:** AC-011

---

## Preconditions (all test cases)

- Redis running and accessible
- Bot record with grid levels persisted in DB

---

## Unit Test Cases (RSpec coverage)

### TC06-01: Seed — all keys populated after initialization

**Priority:** P1
**Description:** `Grid::RedisState#seed` populates all hot state keys for a bot. (AC-011)

**Steps (RSpec unit test):**
```ruby
redis = Redis.new
redis_state = Grid::RedisState.new(redis: redis)
bot = create(:bot, :with_grid_levels)  # 10 levels

redis_state.seed(bot)

# Status key
expect(redis.get("grid:#{bot.id}:status")).to eq("running")

# Stats hash
stats = redis.hgetall("grid:#{bot.id}:stats")
expect(stats["realized_profit"]).to eq("0")
expect(stats["trade_count"]).to eq("0")  # Note: seed uses "0" string
expect(stats["uptime_start"]).to be_present  # Unix timestamp string

# Levels hash
levels = redis.hgetall("grid:#{bot.id}:levels")
expect(levels.keys.map(&:to_i)).to match_array(bot.grid_levels.map(&:level_index))
# Verify each level JSON is parseable
levels.each do |level_index, json|
  parsed = Oj.load(json)
  expect(parsed).to include("side", "status", "price", "order_id", "cycle_count")
end
```

**Expected Result:**
- `grid:{bot_id}:status` = bot's current status string
- `grid:{bot_id}:stats` hash has `realized_profit`, `trade_count`, `uptime_start` keys
- `grid:{bot_id}:levels` hash has one entry per grid level
- Each level entry is valid JSON with required fields

---

### TC06-02: update_on_fill — level and stats updated

**Priority:** P1
**Description:** After a fill, the affected grid level and stats are updated in Redis. (AC-011)

**Steps (RSpec unit test):**
```ruby
# Seed first
redis_state.seed(bot)
grid_level = bot.grid_levels.first

# Simulate fill: level is now "filled", a trade was created
grid_level.update!(status: "filled")
trade = create(:trade, bot: bot, net_profit: BigDecimal("1.50"))

redis_state.update_on_fill(bot, grid_level, trade)

# Level updated
level_data = Oj.load(redis.hget("grid:#{bot.id}:levels", grid_level.level_index.to_s))
expect(level_data["status"]).to eq("filled")

# Stats updated
stats = redis.hgetall("grid:#{bot.id}:stats")
expect(stats["trade_count"].to_i).to eq(1)
expect(BigDecimal(stats["realized_profit"])).to eq(bot.trades.sum(:net_profit))
```

**Expected Result:**
- Level entry in Redis reflects new status
- `trade_count` incremented by 1
- `realized_profit` updated to sum of all trades' net_profit

---

### TC06-03: update_on_fill without trade — only level updated

**Priority:** P1
**Description:** When a buy fills (no trade yet), only the level is updated, stats unchanged.

**Steps (RSpec unit test):**
```ruby
redis_state.seed(bot)
initial_stats = redis.hgetall("grid:#{bot.id}:stats")

# Buy fill: trade is nil
redis_state.update_on_fill(bot, grid_level, nil)

# Level updated
level_data = Oj.load(redis.hget("grid:#{bot.id}:levels", grid_level.level_index.to_s))
expect(level_data["status"]).to eq("filled")

# Stats unchanged
expect(redis.hgetall("grid:#{bot.id}:stats")).to eq(initial_stats)
```

**Expected Result:**
- Level entry updated
- Stats keys unchanged (trade_count and realized_profit not modified)

---

### TC06-04: update_status — status key updated

**Priority:** P1
**Description:** `update_status` changes the status key for a bot.

**Steps (RSpec unit test):**
```ruby
redis_state.seed(bot)
redis_state.update_status(bot.id, "paused")

expect(redis.get("grid:#{bot.id}:status")).to eq("paused")
```

**Expected Result:**
- `grid:{bot_id}:status` = `"paused"`

---

### TC06-05: update_price — price key updated

**Priority:** P1
**Description:** `update_price` updates the current price string.

**Steps (RSpec unit test):**
```ruby
redis_state.update_price(bot.id, BigDecimal("2543.50"))

expect(redis.get("grid:#{bot.id}:current_price")).to eq("2543.5")
# or eq("2543.50") — verify exact string format
```

**Expected Result:**
- `grid:{bot_id}:current_price` set to the price as a string

---

### TC06-06: cleanup — all keys deleted on bot stop

**Priority:** P1
**Description:** `cleanup` removes all hot state keys for a bot, leaving no orphaned keys. (AC-011)

**Steps (RSpec unit test):**
```ruby
redis_state.seed(bot)
redis_state.update_price(bot.id, "2500")

# Verify keys exist before cleanup
expect(redis.exists("grid:#{bot.id}:status")).to eq(1)
expect(redis.exists("grid:#{bot.id}:levels")).to eq(1)
expect(redis.exists("grid:#{bot.id}:stats")).to eq(1)
expect(redis.exists("grid:#{bot.id}:current_price")).to eq(1)

redis_state.cleanup(bot.id)

# All keys gone
expect(redis.exists("grid:#{bot.id}:status")).to eq(0)
expect(redis.exists("grid:#{bot.id}:levels")).to eq(0)
expect(redis.exists("grid:#{bot.id}:stats")).to eq(0)
expect(redis.exists("grid:#{bot.id}:current_price")).to eq(0)
```

**Expected Result:**
- All 4 key suffixes deleted: `status`, `current_price`, `levels`, `stats`
- No `KEYS` scan used (uses explicit key deletion)
- No other bot's keys affected

---

### TC06-07: Keys have no TTL

**Priority:** P2
**Description:** Hot state keys should have no expiration (TTL = -1).

**Steps (RSpec unit test):**
```ruby
redis_state.seed(bot)

expect(redis.ttl("grid:#{bot.id}:status")).to eq(-1)
expect(redis.ttl("grid:#{bot.id}:levels")).to eq(-1)
expect(redis.ttl("grid:#{bot.id}:stats")).to eq(-1)
```

**Expected Result:**
- TTL = -1 (no expiration) for all hot state keys

---

### TC06-08: Level JSON format — all required fields present

**Priority:** P1
**Description:** Each entry in the `grid:{bot_id}:levels` hash has the correct JSON structure.

**Steps (RSpec unit test):**
```ruby
redis_state.seed(bot)

bot.grid_levels.each do |level|
  json = redis.hget("grid:#{bot.id}:levels", level.level_index.to_s)
  parsed = Oj.load(json, symbol_keys: true)

  expect(parsed[:side]).to be_in(%w[buy sell])
  expect(parsed[:status]).to be_in(%w[pending active filled skipped])
  expect(BigDecimal(parsed[:price])).to be > 0
  expect(parsed[:cycle_count]).to be_a(Integer).or be_a(String)
  # order_id can be nil for levels not yet placed
end
```

**Expected Result:**
- Every level has `side`, `status`, `price`, `order_id`, `cycle_count`
- Values match the corresponding `grid_levels` DB record

---

## Integration Test (Rails console)

### TC06-09: Verify Redis state after initialization

**Priority:** P1
**Description:** After `Grid::Initializer#call`, verify all Redis keys are correctly seeded.

**Steps (Rails console):**
```ruby
redis = Redis.new
bot = Bot.find(<bot_id>)

# Check status
puts redis.get("grid:#{bot.id}:status")  # "running"

# Check stats
puts redis.hgetall("grid:#{bot.id}:stats").inspect

# Check levels
levels = redis.hgetall("grid:#{bot.id}:levels")
puts "#{levels.count} levels in Redis (#{bot.grid_levels.count} in DB)"
levels.each do |idx, json|
  parsed = Oj.load(json, symbol_keys: true)
  puts "Level #{idx}: #{parsed[:side]} @ #{parsed[:price]} (#{parsed[:status]})"
end

# Check price
puts "Current price: #{redis.get("grid:#{bot.id}:current_price")}"
```

**Expected Result:**
- All 4 key types present
- Level count matches DB grid_level count
- Status = "running"
- Stats initialized with zeros

---

### TC06-10: Verify Redis state updated after fill

**Priority:** P1
**Description:** After an order fills, verify the Redis state reflects the updated level.

**Steps (Rails console):**
```ruby
bot = Bot.find(<bot_id>)
redis = Redis.new

# Before fill
level = bot.grid_levels.where(expected_side: 'buy').first
puts "Before: #{Oj.load(redis.hget("grid:#{bot.id}:levels", level.level_index.to_s)).inspect}"

# Wait for a fill to happen (or manually trigger via OrderFillWorker)
sleep 30

# After fill
puts "After: #{Oj.load(redis.hget("grid:#{bot.id}:levels", level.level_index.to_s)).inspect}"
stats = redis.hgetall("grid:#{bot.id}:stats")
puts "Trade count: #{stats['trade_count']}"
puts "Realized profit: #{stats['realized_profit']}"
```

**Expected Result:**
- Level status changes from `active` to `filled` after fill
- Stats `trade_count` incremented when sell fills (completing a cycle)
- `realized_profit` updated with correct sum
