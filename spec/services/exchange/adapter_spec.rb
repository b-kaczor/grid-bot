# frozen_string_literal: true

require_relative "../../../app/services/exchange/adapter"

RSpec.describe Exchange::Adapter do
  subject(:adapter) { described_class.new }

  describe "abstract interface" do
    it "raises NotImplementedError for get_tickers" do
      expect { adapter.get_tickers(symbol: "ETHUSDT") }.to raise_error(Exchange::Adapter::NotImplementedError)
    end

    it "raises NotImplementedError for get_instruments_info" do
      expect { adapter.get_instruments_info(symbol: "ETHUSDT") }.to raise_error(Exchange::Adapter::NotImplementedError)
    end

    it "raises NotImplementedError for get_wallet_balance" do
      expect { adapter.get_wallet_balance }.to raise_error(Exchange::Adapter::NotImplementedError)
    end

    it "raises NotImplementedError for place_order" do
      expect { adapter.place_order(symbol: "ETHUSDT", side: "Buy", order_type: "Limit", qty: "0.01") }
        .to raise_error(Exchange::Adapter::NotImplementedError)
    end

    it "raises NotImplementedError for batch_place_orders" do
      expect { adapter.batch_place_orders(symbol: "ETHUSDT", orders: []) }
        .to raise_error(Exchange::Adapter::NotImplementedError)
    end

    it "raises NotImplementedError for cancel_order" do
      expect { adapter.cancel_order(symbol: "ETHUSDT") }.to raise_error(Exchange::Adapter::NotImplementedError)
    end

    it "raises NotImplementedError for cancel_all_orders" do
      expect { adapter.cancel_all_orders(symbol: "ETHUSDT") }.to raise_error(Exchange::Adapter::NotImplementedError)
    end

    it "raises NotImplementedError for get_open_orders" do
      expect { adapter.get_open_orders(symbol: "ETHUSDT") }.to raise_error(Exchange::Adapter::NotImplementedError)
    end

    it "raises NotImplementedError for set_dcp" do
      expect { adapter.set_dcp(time_window: 10) }.to raise_error(Exchange::Adapter::NotImplementedError)
    end
  end
end
