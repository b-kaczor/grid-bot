FactoryBot.define do
  factory :balance_snapshot do
    bot
    base_balance { 1.0 }
    quote_balance { 1000.0 }
    total_value_quote { 3500.0 }
    current_price { 2500.0 }
    realized_profit { 50.0 }
    unrealized_pnl { 10.0 }
    granularity { "fine" }
    snapshot_at { Time.current }
  end
end
