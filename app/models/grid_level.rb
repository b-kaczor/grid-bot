class GridLevel < ApplicationRecord
  belongs_to :bot
  has_many :orders, dependent: :destroy
  has_many :trades, dependent: :destroy

  SIDES = %w[buy sell].freeze
  STATUSES = %w[pending active filled skipped].freeze

  validates :level_index, presence: true,
                          numericality: { greater_than_or_equal_to: 0, only_integer: true },
                          uniqueness: { scope: :bot_id }
  validates :price, presence: true, numericality: { greater_than: 0 }
  validates :expected_side, presence: true, inclusion: { in: SIDES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :cycle_count, numericality: { greater_than_or_equal_to: 0 }
end
