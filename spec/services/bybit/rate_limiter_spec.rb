# frozen_string_literal: true

require_relative "../../../app/services/bybit/rate_limiter"

RSpec.describe Bybit::RateLimiter do
  let(:redis) { MockRedis.new }
  subject(:limiter) { described_class.new(redis:) }

  # Minimal mock Redis that supports the operations used by RateLimiter
  before do
    stub_const("MockRedis", Class.new {
      def initialize
        @store = {}
        @ttls = {}
      end

      def eval(script, keys:, argv:)
        key = keys[0]
        limit = argv[0].to_i
        window = argv[1].to_i
        current = (@store[key] || 0).to_i
        return 0 if current >= limit

        @store[key] = current + 1
        @ttls[key] ||= window
        1
      end

      def get(key)
        @store[key]&.to_s
      end

      def set(key, value)
        @store[key] = value.to_i
      end

      def expire(key, ttl)
        @ttls[key] = ttl
      end

      def ttl_for(key)
        @ttls[key]
      end

      def raw_get(key)
        @store[key]
      end
    })
  end

  describe "#check!" do
    it "allows requests under the limit" do
      expect { limiter.check!(:order_write) }.not_to raise_error
    end

    it "allows up to the limit for order_write (20)" do
      20.times { limiter.check!(:order_write) }
      # 20th call should succeed (we've made 20 calls)
    end

    it "raises RateLimitError when order_write limit exceeded" do
      20.times { limiter.check!(:order_write) }
      expect { limiter.check!(:order_write) }
        .to raise_error(Bybit::RateLimitError, /order_write/)
    end

    it "raises RateLimitError when order_batch limit (10) exceeded" do
      10.times { limiter.check!(:order_batch) }
      expect { limiter.check!(:order_batch) }
        .to raise_error(Bybit::RateLimitError, /order_batch/)
    end

    it "raises RateLimitError when ip_global limit (600) exceeded" do
      600.times { limiter.check!(:ip_global) }
      expect { limiter.check!(:ip_global) }
        .to raise_error(Bybit::RateLimitError, /ip_global/)
    end

    it "raises ArgumentError for unknown bucket" do
      expect { limiter.check!(:unknown) }
        .to raise_error(ArgumentError, /Unknown bucket/)
    end

    it "tracks buckets independently" do
      20.times { limiter.check!(:order_write) }
      expect { limiter.check!(:order_batch) }.not_to raise_error
    end
  end

  describe "#update_from_headers" do
    it "updates Redis counter from remaining header" do
      headers = { "X-Bapi-Limit-Status" => "15" }
      limiter.update_from_headers(:order_write, headers)

      # order_write limit is 20, remaining is 15, so used = 5
      expect(redis.raw_get("bybit:rate:order_write:count")).to eq(5)
    end

    it "sets TTL from reset timestamp header" do
      future_ms = ((Time.now.to_f + 3) * 1000).to_i.to_s
      headers = {
        "X-Bapi-Limit-Status" => "10",
        "X-Bapi-Limit-Reset-Timestamp" => future_ms
      }
      limiter.update_from_headers(:order_write, headers)

      ttl = redis.ttl_for("bybit:rate:order_write:count")
      expect(ttl).to be >= 1
      expect(ttl).to be <= 4
    end

    it "uses default window when no reset timestamp" do
      headers = { "X-Bapi-Limit-Status" => "10" }
      limiter.update_from_headers(:order_write, headers)

      expect(redis.ttl_for("bybit:rate:order_write:count")).to eq(1)
    end

    it "does nothing when headers is nil" do
      expect { limiter.update_from_headers(:order_write, nil) }.not_to raise_error
    end

    it "does nothing when remaining header is missing" do
      headers = { "X-Bapi-Limit-Reset-Timestamp" => "12345" }
      expect { limiter.update_from_headers(:order_write, headers) }.not_to raise_error
    end

    it "clamps used count to minimum of 0" do
      # remaining > limit means used would be negative
      headers = { "X-Bapi-Limit-Status" => "25" }
      limiter.update_from_headers(:order_write, headers)

      expect(redis.raw_get("bybit:rate:order_write:count")).to eq(0)
    end
  end

  describe "BUCKETS configuration" do
    it "defines order_write with limit 20 and 1s window" do
      config = described_class::BUCKETS[:order_write]
      expect(config).to eq({ limit: 20, window: 1 })
    end

    it "defines order_batch with limit 10 and 1s window" do
      config = described_class::BUCKETS[:order_batch]
      expect(config).to eq({ limit: 10, window: 1 })
    end

    it "defines ip_global with limit 600 and 5s window" do
      config = described_class::BUCKETS[:ip_global]
      expect(config).to eq({ limit: 600, window: 5 })
    end
  end
end
