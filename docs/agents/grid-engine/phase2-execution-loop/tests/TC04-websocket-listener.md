# TC04 — Bybit::WebsocketListener Test Cases

**Component:** `app/services/bybit/websocket_listener.rb`, `bin/ws_listener`
**Acceptance Criteria:** AC-002, AC-009, AC-010, AC-013

---

## Preconditions (all test cases)

- Bybit testnet credentials configured in `ExchangeAccount`
- Redis running and accessible
- Sidekiq running (for OrderFillWorker enqueues)
- Network access to `wss://stream-testnet.bybit.com/v5/private`

---

## Unit Test Cases (RSpec coverage)

### TC04-01: Successful connection and authentication

**Priority:** P0
**Description:** Listener connects to the private WebSocket, sends auth frame, and receives success response. (AC-002)

**Steps (RSpec unit test):**
```ruby
# Stub async-websocket connection
# Verify auth frame sent with correct HMAC
expect(ws).to receive(:write).with(
  hash_including(op: "auth",
                 args: [api_key, anything, anything])
)

# Auth response
allow(ws).to receive(:read).and_return(
  Oj.dump({ op: "auth", success: true }),
  Oj.dump({ op: "subscribe", success: true }),
  nil  # End loop
)

listener.run
# Should not raise
```

**Expected Result:**
- Auth frame format: `{ op: "auth", args: [api_key, expires, signature] }`
- `expires` is approximately 5 seconds in the future (in milliseconds)
- `signature = HMAC_SHA256(secret, "GET/realtime#{expires}")`
- Auth success response processed without error

---

### TC04-02: Subscription to required channels

**Priority:** P0
**Description:** After auth, listener subscribes to `order.spot`, `execution.spot`, `wallet`.

**Steps (RSpec unit test):**
```ruby
expect(ws).to receive(:write).with(
  hash_including(op: "subscribe", args: ["order.spot", "execution.spot", "wallet"])
)
```

**Expected Result:**
- Subscribe frame sent immediately after successful auth
- All three topics included in a single subscribe request

---

### TC04-03: Order fill event processed — OrderFillWorker enqueued

**Priority:** P0
**Description:** When `order.spot` message arrives with `orderStatus == "Filled"`, worker is enqueued and fill published to Redis stream. (AC-002)

**Steps (RSpec unit test):**
```ruby
fill_message = Oj.dump({
  topic: "order.spot",
  data: [{
    orderId: "123456",
    orderLinkId: "g1-L5-B-0",
    symbol: "ETHUSDT",
    side: "Buy",
    orderStatus: "Filled",
    cumExecQty: "0.1",
    avgPrice: "2500.00",
    cumExecFee: "0.25",
    feeCurrency: "USDT",
    updatedTime: Time.current.to_i.to_s
  }]
})

allow(ws).to receive(:read).and_return(fill_message, nil)

expect(OrderFillWorker).to receive(:perform_async).with(anything)
expect(redis).to receive(:xadd).with("grid:fills", anything)

listener.run
```

**Expected Result:**
- `OrderFillWorker.perform_async` called once with the order data JSON
- Redis stream `grid:fills` receives an entry with order details
- Message processing completes without blocking

---

### TC04-04: Non-fill order events ignored

**Priority:** P1
**Description:** `order.spot` messages with `orderStatus != "Filled"` are ignored.

**Steps (RSpec unit test):**
```ruby
non_fill_message = Oj.dump({
  topic: "order.spot",
  data: [{ orderId: "123", orderStatus: "New", ... }]
})

allow(ws).to receive(:read).and_return(non_fill_message, nil)

expect(OrderFillWorker).not_to receive(:perform_async)
listener.run
```

**Expected Result:**
- Worker not enqueued for `New`, `PartiallyFilled`, `Cancelled` statuses
- No Redis stream entry for non-fill events

---

### TC04-05: Heartbeat sent every 20 seconds

**Priority:** P1
**Description:** A `ping` frame is sent every 20 seconds to maintain the connection.

**Steps (RSpec unit test):**
```ruby
# Use fake time or mock async timer
expect(ws).to receive(:write).with({ op: "ping" }).at_least(:once)
# After 20 seconds of fake time, ping should have been sent
```

**Steps (Integration — manual):**
```bash
# Run listener with debug logging
WS_LOG_LEVEL=debug bundle exec bin/ws_listener
# Observe logs for "Sending ping" every 20 seconds
```

**Expected Result:**
- `{"op":"ping"}` frame sent every 20 seconds
- Bybit responds with `{"op":"pong"}` (verify in logs)
- Connection stays alive beyond the 30-second timeout window

---

### TC04-06: Reconnection with exponential backoff

**Priority:** P1
**Description:** On connection drop, listener reconnects with exponential backoff (1s, 2s, 4s, 8s, max 30s). (AC-009)

**Steps (RSpec unit test):**
```ruby
call_count = 0
allow(listener).to receive(:connect_and_listen).and_raise(StandardError, "Connection refused")

expect(listener).to receive(:sleep).with(1).ordered
expect(listener).to receive(:sleep).with(2).ordered
expect(listener).to receive(:sleep).with(4).ordered
expect(listener).to receive(:sleep).with(8).ordered
expect(listener).to receive(:sleep).with(16).ordered
expect(listener).to receive(:sleep).with(30).ordered   # Capped at 30
expect(listener).to receive(:sleep).with(30).ordered   # Stays at 30

# After 7 reconnect attempts
```

**Expected Result:**
- Backoff sequence: 1, 2, 4, 8, 16, 30, 30, 30...
- Never exceeds 30 second delay
- On successful reconnect, backoff resets to 1

---

### TC04-07: Reconnection triggers reconciliation

**Priority:** P1
**Description:** After reconnecting, `GridReconciliationWorker` is enqueued for all running bots. (AC-009)

**Steps (RSpec unit test):**
```ruby
bot1 = create(:bot, status: "running")
bot2 = create(:bot, status: "running")

# Simulate successful reconnect after one failure
allow(listener).to receive(:connect_and_listen)
  .and_raise(StandardError).once
  .and_return(nil)

expect(GridReconciliationWorker).to receive(:perform_async).with(bot1.id)
expect(GridReconciliationWorker).to receive(:perform_async).with(bot2.id)

listener.connect_with_reconnect
```

**Expected Result:**
- `GridReconciliationWorker.perform_async(bot_id)` called for each running bot
- Reconciliation triggered immediately (not after next cron interval)

---

### TC04-08: Read timeout — connection treated as dead

**Priority:** P1
**Description:** If no message arrives within 30 seconds (including pong), connection is treated as dead and reconnected.

**Steps (RSpec unit test):**
```ruby
# Simulate read timeout
allow(ws).to receive(:read).and_raise(Async::TimeoutError)

# Should trigger reconnection, not crash
expect(listener).to receive(:connect_with_reconnect)
# No unhandled exception
```

**Expected Result:**
- `Async::TimeoutError` caught
- Reconnection logic triggered
- WS_READ_TIMEOUT constant = 30 seconds

---

### TC04-09: Maintenance detection — close code 1001 pauses all bots

**Priority:** P1
**Description:** WebSocket close code 1001 (Going Away) triggers bot pause and special maintenance reconnect loop. (AC-010)

**Steps (RSpec unit test):**
```ruby
bot = create(:bot, status: "running")

allow(ws).to receive(:read).and_raise(
  Async::WebSocket::ClosedError.new(code: 1001, reason: "Going Away")
)

GridReconciliationWorker.new.perform(bot.id)

bot.reload
expect(bot.status).to eq("paused")
expect(bot.stop_reason).to eq("maintenance")

# Redis also updated
expect(redis.get("grid:#{bot.id}:status")).to eq("paused")
```

**Expected Result:**
- All running bots set to `status=paused, stop_reason=maintenance`
- Redis status keys updated
- Special maintenance retry loop starts (retry every 30s)

---

### TC04-10: Maintenance recovery — bots resumed after reconnect

**Priority:** P1
**Description:** After maintenance, all bots paused with `stop_reason=maintenance` are resumed. (AC-010)

**Steps (RSpec unit test):**
```ruby
bot = create(:bot, status: "paused", stop_reason: "maintenance")

# Simulate successful reconnect after maintenance
listener.resume_after_maintenance

bot.reload
expect(bot.status).to eq("running")
expect(bot.stop_reason).to be_nil
expect(redis.get("grid:#{bot.id}:status")).to eq("running")

# Reconciliation triggered for resumed bots
expect(GridReconciliationWorker).to have_received(:perform_async).with(bot.id)
```

**Expected Result:**
- Bots set back to `running` with `stop_reason=nil`
- Redis status updated to `running`
- Reconciliation triggered for each resumed bot

---

### TC04-11: HTTP 503 during initial connection

**Priority:** P1
**Description:** HTTP 503 response on initial connection triggers maintenance handling (same as close code 1001).

**Steps (RSpec unit test):**
```ruby
allow(Async::WebSocket::Client).to receive(:connect)
  .and_raise(Errno::ECONNREFUSED)  # Or HTTP 503 response

# Bot should be paused
# Retry every 30s in maintenance loop
```

**Expected Result:**
- Same behavior as TC04-09 (bots paused, maintenance retry loop)

---

### TC04-12: Graceful shutdown on SIGTERM

**Priority:** P1
**Description:** SIGTERM signal causes clean shutdown — async tasks cancelled, WebSocket closed cleanly. (AC-013)

**Steps (Rails console / bash):**
```bash
# Start listener in background
bundle exec bin/ws_listener &
WS_PID=$!

# Wait for it to connect
sleep 3

# Send SIGTERM
kill -TERM $WS_PID

# Should exit cleanly within a few seconds
wait $WS_PID
echo "Exit code: $?"
```

**Expected Result:**
- Process exits with code 0 (clean exit)
- WebSocket close frame sent to Bybit (not dropped)
- No `Sidekiq::DeadSet` jobs created from in-flight enqueues
- Log shows "Shutting down gracefully" message
- No orphaned async tasks

---

### TC04-13: Graceful shutdown on SIGINT

**Priority:** P2
**Description:** SIGINT (Ctrl+C) behaves identically to SIGTERM.

**Steps:**
Same as TC04-12 but using `kill -INT $WS_PID`.

**Expected Result:**
- Same clean shutdown as SIGTERM

---

## Integration Test (testnet)

### TC04-14: End-to-end: listener receives real fill from testnet

**Priority:** P0
**Description:** Verify the WebSocket listener detects a real order fill on testnet and enqueues the worker.

**Preconditions:**
- Bot initialized and running on testnet
- WebSocket listener running

**Steps:**
```bash
# Terminal 1: Watch listener logs
bundle exec bin/ws_listener 2>&1 | tee ws_listener.log

# Terminal 2: Watch Sidekiq logs
bundle exec sidekiq 2>&1 | grep OrderFillWorker

# Terminal 3: Place a market sell on testnet to trigger a fill
# (Can use Bybit testnet UI or API)
```

```ruby
# Terminal 4: Rails console — verify after fill
bot = Bot.find(<bot_id>)
sleep 5
puts "Filled orders: #{bot.orders.where(status: 'filled').count}"
puts "Redis fills stream length: #{Redis.new.xlen('grid:fills')}"
puts "Recent Sidekiq jobs: #{Sidekiq::Queue.new('critical').size}"
```

**Expected Result:**
- Listener log shows "Received order.spot: Filled" message
- `grid:fills` Redis stream has a new entry
- `OrderFillWorker` appears in Sidekiq `critical` queue or is processed
- Bot's order status changes to `filled` within seconds
