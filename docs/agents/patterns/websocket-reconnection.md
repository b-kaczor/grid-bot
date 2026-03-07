# WebSocket Reconnection Pattern

## When to Use

- You have a long-lived WebSocket connection to an external service (e.g., exchange private stream)
- Dropped connections must be recovered automatically with no manual intervention
- Reconnect must trigger reconciliation/recovery so no events are missed during downtime

## Steps

1. **Wrap connection in a retry loop** with exponential backoff state:
   ```ruby
   backoff = 1
   loop do
     connect_and_run   # blocks until connection drops
     sleep backoff
     backoff = [backoff * 2, MAX_BACKOFF].min
   end
   ```

2. **Authenticate after every connect** — do not cache the auth handshake across reconnects. Bybit requires a fresh `auth` op each time.

3. **Re-subscribe after auth** — subscriptions are not persistent; send topic subscriptions again after receiving auth confirmation.

4. **Trigger reconciliation on reconnect** — events missed during the gap will not arrive retroactively. After reconnecting, enqueue `GridReconciliationWorker` for all running bots so gaps are detected immediately.

5. **Handle maintenance codes separately** — HTTP 503 or WebSocket close code 1001 means planned exchange maintenance. Set all bots to `paused` and poll every 30s instead of using exponential backoff.

6. **Heartbeat** — send `{"op":"ping"}` every 20 seconds via an async timer. Reset the timer on reconnect.

7. **Graceful shutdown** — trap `SIGTERM`/`SIGINT`. Cancel async tasks and close the WebSocket cleanly before exit. This prevents orphaned connections on the exchange side.

## Key Files

- `app/services/bybit/websocket_listener.rb` — reference implementation
- `bin/ws_listener` — entry point; runs the listener as a standalone OS process

## Example

- See: `phase2-execution-loop/` for the Bybit private stream implementation
