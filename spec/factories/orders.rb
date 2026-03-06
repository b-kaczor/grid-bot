FactoryBot.define do
  factory :order do
    bot
    grid_level
    sequence(:order_link_id) { |n| "g1L0B#{n}" }
    side { "buy" }
    price { 2500.0 }
    quantity { 0.1 }
    status { "pending" }
  end
end
