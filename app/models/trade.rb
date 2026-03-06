class Trade < ApplicationRecord
  belongs_to :bot
  belongs_to :grid_level
  belongs_to :buy_order, class_name: "Order"
  belongs_to :sell_order, class_name: "Order"

  validates :buy_price, presence: true, numericality: { greater_than: 0 }
  validates :sell_price, presence: true, numericality: { greater_than: 0 }
  validates :quantity, presence: true, numericality: { greater_than: 0 }
  validates :gross_profit, presence: true
  validates :total_fees, presence: true
  validates :net_profit, presence: true
  validates :completed_at, presence: true

  scope :profitable, -> { where("net_profit > 0") }
  scope :recent, -> { order(completed_at: :desc) }
end
