# Phase 1: Foundation — ARCHITECTURE

## Project Structure

```
grid_bot/
  app/
    controllers/          # Thin API controllers (Phase 3)
    models/
      exchange_account.rb
      bot.rb
      grid_level.rb
      order.rb
      trade.rb
      balance_snapshot.rb
    services/
      exchange/
        adapter.rb        # Abstract interface
      bybit/
        auth.rb           # HMAC-SHA256 signing
        rest_client.rb    # Faraday-based REST client, implements Exchange::Adapter
        rate_limiter.rb   # Redis-backed token bucket
        response.rb       # Unified response wrapper
      grid/
        calculator.rb     # Arithmetic & geometric grid math
    jobs/
      snapshot_retention_job.rb  # Sidekiq-cron: daily cleanup
  config/
    initializers/
      lockbox.rb          # Lockbox master key config
      sidekiq.rb          # Sidekiq + Redis config
      oj.rb               # Fast JSON serialization
  db/
    migrate/
      001_create_exchange_accounts.rb
      002_create_bots.rb
      003_create_grid_levels.rb
      004_create_orders.rb
      005_create_trades.rb
      006_create_balance_snapshots.rb
  frontends/
    app/                  # Vite + React scaffold (empty shell this phase)
  spec/
    services/
      bybit/
        auth_spec.rb
        rest_client_spec.rb
        rate_limiter_spec.rb
      grid/
        calculator_spec.rb
    models/
      bot_spec.rb
      grid_level_spec.rb
      order_spec.rb
      trade_spec.rb
```

---

## Exchange::Adapter Interface

The abstract interface that all exchange clients must implement. This is the seam between grid logic and exchange-specific code.

**File:** `app/services/exchange/adapter.rb`

```ruby
module Exchange
  class Adapter
    class NotImplementedError < StandardError; end

    # Market data (no auth required)
    def get_tickers(symbol:)
      raise NotImplementedError
    end

    def get_instruments_info(symbol:)
      raise NotImplementedError
    end

    # Account (auth required)
    def get_wallet_balance(coin: nil)
      raise NotImplementedError
    end

    # Orders (auth required)
    def place_order(symbol:, side:, order_type:, qty:, price: nil, order_link_id: nil, time_in_force: "GTC")
      raise NotImplementedError
    end

    def batch_place_orders(symbol:, orders:)
      raise NotImplementedError
    end

    def cancel_order(symbol:, order_id: nil, order_link_id: nil)
      raise NotImplementedError
    end

    def cancel_all_orders(symbol:)
      raise NotImplementedError
    end

    def get_open_orders(symbol:, cursor: nil, limit: 50)
      raise NotImplementedError
    end

    # Safety
    def set_dcp(time_window:)
      raise NotImplementedError
    end
  end
end
```

**Return contract:** Every method returns an `Exchange::Response` struct:

```ruby
module Exchange
  Response = Struct.new(:success, :data, :error_code, :error_message, keyword_init: true) do
    def success? = success
  end
end
```

This keeps the rest of the application decoupled from Bybit-specific response shapes.

---

## Bybit::Auth — HMAC-SHA256 Signing

**File:** `app/services/bybit/auth.rb`

```ruby
module Bybit
  class Auth
    RECV_WINDOW = "5000"

    def initialize(api_key:, api_secret:)
      @api_key = api_key
      @api_secret = api_secret
    end

    # Returns a hash of headers to merge into the request
    def sign_request(timestamp:, params_string: "")
      payload = "#{timestamp}#{@api_key}#{RECV_WINDOW}#{params_string}"
      signature = OpenSSL::HMAC.hexdigest("SHA256", @api_secret, payload)

      {
        "X-BAPI-API-KEY" => @api_key,
        "X-BAPI-TIMESTAMP" => timestamp.to_s,
        "X-BAPI-SIGN" => signature,
        "X-BAPI-RECV-WINDOW" => RECV_WINDOW
      }
    end
  end
end
```

---

## Bybit::RestClient

**File:** `app/services/bybit/rest_client.rb`

Inherits from `Exchange::Adapter`. Uses Faraday with `faraday-retry` middleware.

### Key design decisions

1. **Constructor** takes an `ExchangeAccount` record (or explicit key/secret for console use). Decrypts credentials via Lockbox on initialization.
2. **GET requests** pass params as query string. **POST requests** pass params as JSON body. Both include auth headers via `Bybit::Auth`.
3. **Rate limiting** is checked before every request via `Bybit::RateLimiter`. After every response, the limiter updates its state from response headers.
4. **Error handling**: Non-200 responses or Bybit `retCode != 0` are wrapped into `Exchange::Response` with `success?: false`.

### Faraday connection setup

```ruby
@connection = Faraday.new(url: base_url) do |f|
  f.request :json
  f.response :json, parser_options: { symbolize_names: true }
  f.request :retry, max: 2, interval: 0.5,
            methods: [:get],  # Only retry GET — POST retries risk duplicate orders
            exceptions: [Faraday::TimeoutError, Faraday::ConnectionFailed]
  f.adapter Faraday.default_adapter
end
```

### Method mapping

| Adapter Method | HTTP | Bybit Endpoint | Auth | Notes |
|---|---|---|---|---|
| `get_tickers` | GET | `/v5/market/tickers?category=spot` | No | |
| `get_instruments_info` | GET | `/v5/market/instruments-info?category=spot` | No | |
| `get_wallet_balance` | GET | `/v5/account/wallet-balance?accountType=UNIFIED` | Yes | |
| `place_order` | POST | `/v5/order/create` | Yes | Always `category: "spot"` |
| `batch_place_orders` | POST | `/v5/order/create-batch` | Yes | Max 20 orders per call |
| `cancel_order` | POST | `/v5/order/cancel` | Yes | By `orderId` or `orderLinkId` |
| `cancel_all_orders` | POST | `/v5/order/cancel-all` | Yes | |
| `get_open_orders` | GET | `/v5/order/realtime?category=spot` | Yes | Paginated via `cursor`, limit 50 |
| `set_dcp` | POST | `/v5/order/disconnected-cancel-all` | Yes | `timeWindow` in seconds |

---

## Bybit::RateLimiter

**File:** `app/services/bybit/rate_limiter.rb`

Redis-backed token bucket with separate buckets per endpoint category.

### Buckets

| Bucket | Limit | Window | Endpoints |
|--------|-------|--------|-----------|
| `order_write` | 20 req/s | 1 second | place_order, cancel_order |
| `order_batch` | 10 req/s | 1 second | batch_place_orders, cancel_all_orders, get_open_orders |
| `ip_global` | 600 req | 5 seconds | All endpoints |

### Behavior

1. **Before request**: Check Redis counter for the relevant bucket. If at limit, raise `Bybit::RateLimitError`. (TODO Phase 2: switch from raising to re-enqueuing the Sidekiq job with a delay, so rate-limited work is retried automatically.)
2. **After response**: Update bucket state from response headers `X-Bapi-Limit-Status` (remaining requests) and `X-Bapi-Limit-Reset-Timestamp`.
3. **Redis keys**: `bybit:rate:{bucket}:count`, `bybit:rate:{bucket}:reset` with TTL matching the window.

### Interface

```ruby
module Bybit
  class RateLimiter
    def initialize(redis: Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0")))
      @redis = redis
    end

    # Raises Bybit::RateLimitError if limit exceeded
    def check!(bucket)
    end

    # Called after each response to sync with exchange headers
    def update_from_headers(bucket, headers)
    end
  end
end
```

---

## Grid::Calculator

**File:** `app/services/grid/calculator.rb`

Pure computation service with no side effects. Takes parameters, returns data structures.

### Constructor

```ruby
module Grid
  class Calculator
    def initialize(lower:, upper:, count:, spacing: :arithmetic,
                   tick_size: nil, base_precision: nil,
                   min_order_amt: nil, min_order_qty: nil)
    end
  end
end
```

### Public methods

| Method | Returns | Description |
|--------|---------|-------------|
| `levels` | `Array<BigDecimal>` | All price levels (count + 1 values), rounded to `tick_size` |
| `classify_levels(current_price:)` | `Hash{index => :buy\|:sell\|:skip}` | Assigns side per level; `:skip` for neutral zone |
| `quantity_per_level(investment:, current_price:)` | `BigDecimal` | Per-grid order quantity for buy-side levels, rounded to `base_precision`. Requires `classify_levels` to determine buy-side count. |
| `validate!` | `true` or raises | Checks min_order_amt and min_order_qty constraints per level |

### Arithmetic spacing

```
step = (upper - lower) / count
level[i] = lower + (i * step)    # i = 0..count
```

### Geometric spacing

```
ratio = (upper / lower) ** (1.0 / count)
level[i] = lower * (ratio ** i)  # i = 0..count
```

### Quantity calculation

`quantity_per_level` depends on `classify_levels` to determine how many buy-side levels exist. Only buy-side levels consume the quote-currency investment at initialization (sell-side levels require base asset, which is acquired via an initial market buy).

```
buy_count = classify_levels(current_price:).count { |_, side| side == :buy }
quantity_per_level = investment / buy_count / current_price
```

This is a simplified formula suitable for Phase 1. The exact formula (Phase 2) will account for the market buy cost of base asset needed for sell-side levels.

### Neutral zone

A level is skipped if `(level - current_price).abs / current_price < 0.001` (within 0.1%). This prevents the initializer from placing an order that would immediately fill as a taker order, which would corrupt the initial grid state.

### Price rounding

All prices are rounded to the nearest `tick_size` using:

```ruby
(price / tick_size).round * tick_size
```

After rounding, prices are clamped to stay within the grid range:

```ruby
rounded = (price / tick_size).round * tick_size
rounded = [rounded, lower].max
rounded = [rounded, upper].min
```

This prevents `tick_size` rounding from pushing boundary levels outside the configured grid range.

Quantities are rounded down (truncated) to `base_precision` decimal places to avoid exceeding available balance:

```ruby
quantity.truncate(base_precision)
```

**Note on `base_precision`:** Bybit returns `basePrecision` as a string like `"0.000001"`, not an integer. On ingestion, convert to an integer precision count (e.g., `"0.000001"` -> `6`) and store the integer in `bots.base_precision`. Same for `quote_precision`.

---

## Gem Dependencies (Phase 1)

| Gem | Purpose |
|-----|---------|
| `pg` | PostgreSQL adapter |
| `sidekiq` | Background job processing |
| `redis` | Redis client for rate limiter, Sidekiq, caching |
| `faraday` | HTTP client for Bybit REST API |
| `faraday-retry` | Automatic retry on transient failures |
| `async-websocket` | WebSocket client (not used in Phase 1 but added now to avoid gem conflicts later) |
| `lockbox` | Encryption at rest for API keys |
| `dotenv-rails` | Environment variable management |
| `oj` | Fast JSON parsing |
| `rspec-rails` | Testing framework |
| `factory_bot_rails` | Test factories |
| `shoulda-matchers` | Model validation testing |

---

## Configuration

### Environment Variables (.env)

```
BYBIT_BASE_URL=https://api-testnet.bybit.com
BYBIT_WS_PUBLIC=wss://stream-testnet.bybit.com/v5/public/spot
BYBIT_WS_PRIVATE=wss://stream-testnet.bybit.com/v5/private
BYBIT_API_KEY=<testnet key>
BYBIT_API_SECRET=<testnet secret>

REDIS_URL=redis://localhost:6379/0
DATABASE_URL=postgres://localhost/grid_bot_development

LOCKBOX_MASTER_KEY=<32-byte hex key>
```

### Lockbox Initializer

```ruby
# config/initializers/lockbox.rb
Lockbox.master_key = ENV["LOCKBOX_MASTER_KEY"]
```

### Sidekiq Initializer

```ruby
# config/initializers/sidekiq.rb
Sidekiq.configure_server do |config|
  config.redis = { url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0") }
end

Sidekiq.configure_client do |config|
  config.redis = { url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0") }
end
```

---

## Error Handling Strategy

### Exchange errors

All Bybit API errors are caught in `Bybit::RestClient` and returned as `Exchange::Response` with `success?: false`. The caller decides how to handle: retry, log, raise.

### Custom exception classes

```
Bybit::Error               # Base
Bybit::AuthenticationError  # Invalid API key / signature
Bybit::RateLimitError       # Rate limit exceeded
Bybit::OrderError           # Order placement/cancellation failed
Bybit::NetworkError         # Connection timeout / failure (after retries)
```

All inherit from `Bybit::Error` for easy rescue grouping.

---

## Testing Strategy (Phase 1)

| Layer | Approach |
|-------|----------|
| `Grid::Calculator` | Unit tests with known inputs/outputs. Test both spacings, edge cases (1 level, huge ranges), neutral zone |
| `Bybit::Auth` | Unit test signature generation against known test vectors from Bybit docs |
| `Bybit::RestClient` | Stub Faraday responses with WebMock. Test each method maps to correct endpoint, handles errors |
| `Bybit::RateLimiter` | Unit test with mock Redis. Test bucket enforcement, header-based updates |
| Models | Validation tests, association tests, scope tests |
| Integration | Manual console verification against Bybit testnet (AC-001 through AC-004) |

**Note:** Frontend scaffold (AC-010) is deferred to Phase 3. Phase 1 focuses on backend foundation only.
