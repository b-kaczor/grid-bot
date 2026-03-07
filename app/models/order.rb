# frozen_string_literal: true

class Order < ApplicationRecord
  belongs_to :bot
  belongs_to :grid_level
  belongs_to :paired_order, class_name: 'Order', optional: true

  SIDES = %w[buy sell].freeze
  STATUSES = %w[pending open partially_filled filled cancelled rejected].freeze

  validates :order_link_id, presence: true, uniqueness: true
  validates :side, presence: true, inclusion: { in: SIDES }
  validates :price, presence: true, numericality: { greater_than: 0 }
  validates :quantity, presence: true, numericality: { greater_than: 0 }
  validates :status, presence: true, inclusion: { in: STATUSES }

  scope :active, -> { where(status: %w[open partially_filled]) }
  scope :filled, -> { where(status: 'filled') }
  scope :buys, -> { where(side: 'buy') }
  scope :sells, -> { where(side: 'sell') }

  def effective_quantity
    net_quantity || filled_quantity
  end
end
