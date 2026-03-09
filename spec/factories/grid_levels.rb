# frozen_string_literal: true

# == Schema Information
#
# Table name: grid_levels
#
#  id                    :bigint           not null, primary key
#  cycle_count           :integer          default(0), not null
#  expected_side         :string           not null
#  level_index           :integer          not null
#  lock_version          :integer          default(0), not null
#  price                 :decimal(20, 8)   not null
#  status                :string           default("pending"), not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  bot_id                :bigint           not null
#  current_order_id      :string
#  current_order_link_id :string
#
# Indexes
#
#  index_grid_levels_on_bot_id                  (bot_id)
#  index_grid_levels_on_bot_id_and_level_index  (bot_id,level_index) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (bot_id => bots.id)
#
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
