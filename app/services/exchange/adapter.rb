# frozen_string_literal: true

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
