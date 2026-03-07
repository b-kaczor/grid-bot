# frozen_string_literal: true

FactoryBot.define do
  factory :grid_level do
    bot
    sequence(:level_index)
    price { 2500.0 }
    expected_side { 'buy' }
    status { 'pending' }
    cycle_count { 0 }
  end
end
