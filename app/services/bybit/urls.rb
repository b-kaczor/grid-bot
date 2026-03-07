# frozen_string_literal: true

module Bybit
  module Urls
    ENVIRONMENTS = {
      'testnet' => {
        rest: 'https://api-testnet.bybit.com',
        ws_private: 'wss://stream-testnet.bybit.com/v5/private',
        ws_public: 'wss://stream-testnet.bybit.com/v5/public/spot',
      },
      'mainnet' => {
        rest: 'https://api.bybit.com',
        ws_private: 'wss://stream.bybit.com/v5/private',
        ws_public: 'wss://stream.bybit.com/v5/public/spot',
      },
      'demo' => {
        rest: 'https://api-demo.bybit.com',
        ws_private: 'wss://stream-demo.bybit.com/v5/private',
        ws_public: 'wss://stream-demo.bybit.com/v5/public/spot',
      },
    }.freeze

    def self.for(environment)
      ENVIRONMENTS.fetch(environment) do
        raise ArgumentError, "Unknown Bybit environment: #{environment}. Valid: #{ENVIRONMENTS.keys.join(', ')}"
      end
    end
  end
end
