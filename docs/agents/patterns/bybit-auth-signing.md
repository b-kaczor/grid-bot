# Bybit API Authentication (HMAC-SHA256)

## When to Use

When making authenticated Bybit REST API v5 calls that require a signed request (any order, account, or private market endpoint).

## Steps

1. **Get a millisecond timestamp** as a string:
   ```ruby
   timestamp = (Time.now.to_f * 1000).to_i.to_s
   ```

2. **Build the params string**:
   - For GET requests: URL-encode query parameters alphabetically
   - For POST requests: JSON-encode the request body as a string

3. **Construct the signing payload**:
   ```
   payload = "#{timestamp}#{api_key}#{recv_window}#{params_string}"
   ```
   `recv_window` is `"5000"` (milliseconds). This is the window within which the server accepts the request.

4. **Sign with HMAC-SHA256**:
   ```ruby
   signature = OpenSSL::HMAC.hexdigest("SHA256", api_secret, payload)
   ```

5. **Add headers to every authenticated request**:
   ```ruby
   {
     "X-BAPI-API-KEY"     => api_key,
     "X-BAPI-TIMESTAMP"   => timestamp,
     "X-BAPI-SIGN"        => signature,
     "X-BAPI-RECV-WINDOW" => "5000"
   }
   ```

6. **Public endpoints** (market data: tickers, instruments-info) do NOT need auth headers — skip steps 1-5 for those.

## Rate Limit Headers

After every response, read these headers to sync the rate limiter:
- `X-Bapi-Limit-Status` — remaining requests in current window
- `X-Bapi-Limit-Reset-Timestamp` — when the window resets (ms epoch)

Bybit limits (spot, as of Phase 1):
- Order create/cancel: 20 req/s
- Batch/query: 10 req/s
- IP global: 600 req per 5s

## Key Files

- `app/services/bybit/auth.rb` — `Bybit::Auth#sign_request` implementation
- `app/services/bybit/rest_client.rb` — Shows how auth is applied per request
- `app/services/bybit/rate_limiter.rb` — Token bucket keyed on bucket name in Redis

## Gotchas

- **POST requests** pass params as a JSON body string; the same JSON string must be used for both the signature payload and the request body. Do not sign one form and send another.
- **GET requests** pass params as query string; the query string must be in the same order/encoding used for signing.
- Bybit validates the timestamp is within `recv_window` ms of server time. If clock drift exceeds ~2s on the host, requests will fail with auth errors — sync system clock with NTP.
- API key and secret are stored encrypted via Lockbox in `exchange_accounts`. Never log or write them in plaintext.

## Example

See: `grid-engine/phase1-foundation/ARCHITECTURE.md` — "Bybit::Auth — HMAC-SHA256 Signing" section.
