FactoryBot.define do
  factory :bot do
    exchange_account
    pair { "ETHUSDT" }
    base_coin { "ETH" }
    quote_coin { "USDT" }
    lower_price { 2000.0 }
    upper_price { 3000.0 }
    grid_count { 10 }
    spacing_type { "arithmetic" }
    investment_amount { 1000.0 }
    status { "pending" }
  end
end
