module Bybit
  class Error < StandardError; end
  class AuthenticationError < Error; end
  class RateLimitError < Error; end
  class OrderError < Error; end
  class NetworkError < Error; end
end
