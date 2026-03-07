# frozen_string_literal: true

require_relative 'error'

module Bybit
  class RateLimiter
    BUCKETS = {
      order_write: { limit: 20, window: 1 },
      order_batch: { limit: 10, window: 1 },
      ip_global: { limit: 600, window: 5 },
    }.freeze

    # Lua script for atomic check-and-increment.
    # Returns 1 if allowed, 0 if rate limited.
    CHECK_SCRIPT = <<~LUA
      local key = KEYS[1]
      local limit = tonumber(ARGV[1])
      local window = tonumber(ARGV[2])
      local current = tonumber(redis.call('GET', key) or '0')
      if current >= limit then
        return 0
      end
      local new_val = redis.call('INCR', key)
      if new_val == 1 then
        redis.call('EXPIRE', key, window)
      end
      return 1
    LUA

    def initialize(redis: nil)
      @redis = redis || Redis.new(url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0'))
    end

    def check!(bucket, force: false)
      config = BUCKETS.fetch(bucket) { raise ArgumentError, "Unknown bucket: #{bucket}" }
      return if force

      key = counter_key(bucket)

      allowed = @redis.eval(CHECK_SCRIPT, keys: [key], argv: [config[:limit], config[:window]])

      raise Bybit::RateLimitError, "Rate limit exceeded for #{bucket}" if allowed.zero?
    end

    def update_from_headers(bucket, headers)
      return unless headers

      remaining = headers['X-Bapi-Limit-Status']
      return unless remaining

      config = BUCKETS.fetch(bucket) { return }
      used = config[:limit] - remaining.to_i
      return unless used.to_f / config[:limit] > 0.8

      Rails.logger.warn("[RateLimiter] #{bucket} usage >80%: #{used}/#{config[:limit]}")

      # Only log — don't overwrite local counter with Bybit's header values.
      # On demo/testnet, these headers reflect shared rate limits across all
      # users, causing false positives that block our own requests.
    end

    private

    def counter_key(bucket)
      "bybit:rate:#{bucket}:count"
    end
  end
end
