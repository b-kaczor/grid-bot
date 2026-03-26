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
class GridLevel < ApplicationRecord
  belongs_to :bot
  has_many :orders, dependent: :destroy
  has_many :trades, dependent: :destroy

  SIDES = %w[buy sell].freeze
  STATUSES = %w[pending active filled skipped error].freeze

  validates :level_index, presence: true,
                          numericality: { greater_than_or_equal_to: 0, only_integer: true },
                          uniqueness: { scope: :bot_id }
  validates :price, presence: true, numericality: { greater_than: 0 }
  validates :expected_side, presence: true, inclusion: { in: SIDES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :cycle_count, numericality: { greater_than_or_equal_to: 0 }
end
