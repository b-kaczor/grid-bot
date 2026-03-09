# frozen_string_literal: true

# == Schema Information
#
# Table name: trades
#
#  id            :bigint           not null, primary key
#  buy_price     :decimal(20, 8)   not null
#  completed_at  :datetime         not null
#  gross_profit  :decimal(20, 10)  not null
#  net_profit    :decimal(20, 10)  not null
#  quantity      :decimal(20, 8)   not null
#  sell_price    :decimal(20, 8)   not null
#  total_fees    :decimal(20, 10)  not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  bot_id        :bigint           not null
#  buy_order_id  :bigint           not null
#  grid_level_id :bigint           not null
#  sell_order_id :bigint           not null
#
# Indexes
#
#  index_trades_on_bot_id                   (bot_id)
#  index_trades_on_bot_id_and_completed_at  (bot_id,completed_at)
#  index_trades_on_buy_order_id             (buy_order_id)
#  index_trades_on_grid_level_id            (grid_level_id)
#  index_trades_on_sell_order_id            (sell_order_id)
#
# Foreign Keys
#
#  fk_rails_...  (bot_id => bots.id)
#  fk_rails_...  (buy_order_id => orders.id)
#  fk_rails_...  (grid_level_id => grid_levels.id)
#  fk_rails_...  (sell_order_id => orders.id)
#
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
