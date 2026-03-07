# frozen_string_literal: true

module Features
  module ExchangeStubs
    def stub_exchange_client
      client = instance_double(Bybit::RestClient)
      allow(Bybit::RestClient).to receive(:new).and_return(client)

      allow(client).to receive_messages(
        get_instruments_info: instruments_response,
        get_tickers: tickers_response,
        get_wallet_balance: wallet_balance_response,
        set_dcp: ok_response,
        cancel_all_orders: ok_response,
        cancel_order: ok_response
      )

      stub_batch_place(client)
      stub_single_place(client)

      client
    end

    private

    def instruments_response
      Exchange::Response.new(success: true, data: { list: instrument_list })
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

    def tickers_response
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

    def wallet_balance_response
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

    def ok_response
      Exchange::Response.new(success: true, data: {})
    end

    def stub_batch_place(client)
      counter = { value: 0 }
      allow(client).to receive(:batch_place_orders) do |args|
        result_list = args[:orders].map do |order|
          counter[:value] += 1
          { orderId: "ex-#{counter[:value]}", orderLinkId: order[:order_link_id], code: '0' }
        end
        Exchange::Response.new(success: true, data: { list: result_list })
      end
    end

    def stub_single_place(client)
      counter = { value: 100 }
      allow(client).to receive(:place_order) do |**_args|
        counter[:value] += 1
        Exchange::Response.new(success: true, data: { orderId: "ex-#{counter[:value]}" })
      end
    end
  end
end

RSpec.configure do |config|
  config.include Features::ExchangeStubs, type: :feature
end
