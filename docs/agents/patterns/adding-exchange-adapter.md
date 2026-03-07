# Adding an Exchange Adapter

## When to Use

When integrating a new exchange (e.g., Binance, OKX) so that grid logic can use it without modification.

## Steps

1. **Create the client file** at `app/services/{exchange}/rest_client.rb`.

2. **Inherit from `Exchange::Adapter`** (`app/services/exchange/adapter.rb`):
   ```ruby
   module Binance
     class RestClient < Exchange::Adapter
     end
   end
   ```

3. **Implement all required methods** — every method in `Exchange::Adapter` that raises `NotImplementedError` must be overridden:
   - `get_tickers(symbol:)`
   - `get_instruments_info(symbol:)`
   - `get_wallet_balance(coin: nil)`
   - `place_order(symbol:, side:, order_type:, qty:, price: nil, order_link_id: nil, time_in_force: "GTC")`
   - `batch_place_orders(symbol:, orders:)`
   - `cancel_order(symbol:, order_id: nil, order_link_id: nil)`
   - `cancel_all_orders(symbol:)`
   - `get_open_orders(symbol:, cursor: nil, limit: 50)`
   - `set_dcp(time_window:)`

4. **Return `Exchange::Response` from every method** (`app/services/exchange/response.rb`):
   ```ruby
   Exchange::Response.new(success: true, data: parsed_data)
   Exchange::Response.new(success: false, error_code: code, error_message: msg)
   ```
   Never return raw HTTP responses or exchange-specific structs — the rest of the application depends on this contract.

5. **Add an auth module** at `app/services/{exchange}/auth.rb` for request signing. Keep signing logic separate from the HTTP client.

6. **Add a rate limiter** at `app/services/{exchange}/rate_limiter.rb` using Redis-backed token buckets. Model it after `Bybit::RateLimiter`. Match bucket names and limits to the exchange's documented rate limits.

7. **Add custom error classes** at `app/services/{exchange}/error.rb`:
   ```ruby
   module Binance
     class Error < StandardError; end
     class AuthenticationError < Error; end
     class RateLimitError < Error; end
     class OrderError < Error; end
     class NetworkError < Error; end
   end
   ```

8. **Only retry GET requests** in Faraday retry middleware — POST retries risk duplicate orders:
   ```ruby
   f.request :retry, max: 2, interval: 0.5, methods: [:get],
             exceptions: [Faraday::TimeoutError, Faraday::ConnectionFailed]
   ```

9. **Store credentials encrypted** in `exchange_accounts` via Lockbox. The `ExchangeAccount` model already handles encryption — the new client reads credentials from it the same way `Bybit::RestClient` does.

10. **Write RSpec tests** stubbing HTTP with WebMock. Test each method maps to the correct endpoint, handles error responses, and wraps results in `Exchange::Response`.

## Key Files

- `app/services/exchange/adapter.rb` — Abstract interface to implement
- `app/services/exchange/response.rb` — Return type for all methods
- `app/services/bybit/rest_client.rb` — Reference implementation
- `app/services/bybit/auth.rb` — Reference auth/signing implementation
- `app/services/bybit/rate_limiter.rb` — Reference rate limiter implementation
- `app/models/exchange_account.rb` — Credential storage (Lockbox-encrypted)

## Example

See: `grid-engine/phase1-foundation/` for the Bybit reference implementation.
