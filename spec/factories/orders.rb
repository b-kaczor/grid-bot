# frozen_string_literal: true

# == Schema Information
#
# Table name: orders
#
#  id                :bigint           not null, primary key
#  avg_fill_price    :decimal(20, 8)
#  fee               :decimal(20, 10)  default(0.0)
#  fee_coin          :string
#  filled_at         :datetime
#  filled_quantity   :decimal(20, 8)   default(0.0)
#  net_quantity      :decimal(20, 8)
#  placed_at         :datetime
#  price             :decimal(20, 8)   not null
#  quantity          :decimal(20, 8)   not null
#  side              :string           not null
#  status            :string           default("pending"), not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  bot_id            :bigint           not null
#  exchange_order_id :string
#  grid_level_id     :bigint           not null
#  order_link_id     :string           not null
#  paired_order_id   :bigint
#
# Indexes
#
#  index_orders_on_bot_id                    (bot_id)
#  index_orders_on_bot_id_and_status         (bot_id,status)
#  index_orders_on_exchange_order_id         (exchange_order_id)
#  index_orders_on_grid_level_id             (grid_level_id)
#  index_orders_on_grid_level_id_and_status  (grid_level_id,status)
#  index_orders_on_order_link_id             (order_link_id) UNIQUE
#  index_orders_on_paired_order_id           (paired_order_id)
#
# Foreign Keys
#
#  fk_rails_...  (bot_id => bots.id)
#  fk_rails_...  (grid_level_id => grid_levels.id)
#  fk_rails_...  (paired_order_id => orders.id)
#
FactoryBot.define do
  factory :order do
    bot
    grid_level
    sequence(:order_link_id) { |n| "g1L0B#{n}" }
    side { 'buy' }
    price { 2500.0 }
    quantity { 0.1 }
    status { 'pending' }
  end
end
