# frozen_string_literal: true

FactoryBot.define do
  factory :trade do
    bot
    grid_level
    buy_order { association :order, side: 'buy' }
    sell_order { association :order, side: 'sell' }
    buy_price { 2400.0 }
    sell_price { 2500.0 }
    quantity { 0.1 }
    gross_profit { 10.0 }
    total_fees { 0.5 }
    net_profit { 9.5 }
    completed_at { Time.current }
  end
end
