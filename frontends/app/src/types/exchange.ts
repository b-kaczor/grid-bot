export interface TradingPair {
  symbol: string;
  base_coin: string;
  quote_coin: string;
  last_price: string;
  tick_size: string;
  min_order_qty: string;
  min_order_amt: string;
}

export interface CoinBalance {
  coin: string;
  available: string;
  locked: string;
  total: string;
}
