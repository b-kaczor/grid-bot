# frozen_string_literal: true

module Features
  # A fake Bybit client that returns canned responses.
  # Used in feature specs where RSpec allow/receive stubs don't work across threads.
  class FakeBybitClient
    class << self
      attr_accessor :force_failure
    end

    self.force_failure = false

    def get_instruments_info # rubocop:disable Naming/AccessorMethodName
      Exchange::Response.new(success: true, data: { list: instrument_list })
    end

    def get_tickers # rubocop:disable Naming/AccessorMethodName
      Exchange::Response.new(
        success: true,
        data: {
          list: [
            { symbol: 'ETHUSDT', lastPrice: '2500.00' },
            { symbol: 'BTCUSDT', lastPrice: '45000.00' }
          ],
        }
      )
    end

    def get_wallet_balance # rubocop:disable Naming/AccessorMethodName
      if self.class.force_failure
        return Exchange::Response.new(success: false, data: {}, error_message: 'Invalid API key')
      end

      Exchange::Response.new(
        success: true,
        data: {
          list: [
            {
              coin: [
                { coin: 'ETH', availableToWithdraw: '10', locked: '0', walletBalance: '10' },
                { coin: 'USDT', availableToWithdraw: '25000', locked: '0', walletBalance: '25000' }
              ],
            }
          ],
        }
      )
    end

    def set_dcp(**) = ok_response
    def cancel_all_orders(**) = ok_response
    def cancel_order(**) = ok_response

    def batch_place_orders(orders:, **_rest)
      result_list = orders.map do |order|
        @counter = (@counter || 0) + 1
        { orderId: "ex-#{@counter}", orderLinkId: order[:order_link_id], code: '0' }
      end
      Exchange::Response.new(success: true, data: { list: result_list })
    end

    def place_order(**)
      @counter = (@counter || 100) + 1
      Exchange::Response.new(success: true, data: { orderId: "ex-#{@counter}" })
    end

    private

    def ok_response
      Exchange::Response.new(success: true, data: {})
    end

    def instrument_list
      [
        {
          symbol: 'ETHUSDT',
          baseCoin: 'ETH',
          quoteCoin: 'USDT',
          lotSizeFilter: { basePrecision: '0.0001', minOrderQty: '0.001', minOrderAmt: '1' },
          priceFilter: { tickSize: '0.01' },
        },
        {
          symbol: 'BTCUSDT',
          baseCoin: 'BTC',
          quoteCoin: 'USDT',
          lotSizeFilter: { basePrecision: '0.00001', minOrderQty: '0.00001', minOrderAmt: '5' },
          priceFilter: { tickSize: '0.01' },
        }
      ]
    end
  end

  # Prepend module to intercept Bybit::RestClient.new across threads.
  # Only active during feature spec execution to avoid contaminating unit specs.
  module BybitOverride
    def new(**)
      if Features::BotHelpers.feature_spec_active?
        Features::FakeBybitClient.new
      else
        super
      end
    end
  end

  module ExchangeStubs
    def stub_exchange_client
      # No-op in feature specs. The global prepend handles this.
      Features::FakeBybitClient.new
    end
  end
end

RSpec.configure do |config|
  config.include Features::ExchangeStubs, type: :feature

  config.before(:suite) do
    next unless RSpec.configuration.files_to_run.any? { |f| f.include?('spec/features') }

    Bybit::RestClient.singleton_class.prepend(Features::BybitOverride)
  end

  config.after(:each, type: :feature) do
    Features::FakeBybitClient.force_failure = false
  end
end
