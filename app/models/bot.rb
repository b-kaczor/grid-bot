# frozen_string_literal: true

class Bot < ApplicationRecord
  belongs_to :exchange_account
  has_many :grid_levels, dependent: :destroy
  has_many :orders, dependent: :destroy
  has_many :trades, dependent: :destroy
  has_many :balance_snapshots, dependent: :destroy

  STATUSES = %w[pending initializing running paused stopping stopped error].freeze
  STOP_REASONS = %w[user stop_loss take_profit error maintenance].freeze
  SPACING_TYPES = %w[arithmetic geometric].freeze

  validates :pair, presence: true
  validates :base_coin, presence: true
  validates :quote_coin, presence: true
  validates :lower_price, presence: true, numericality: { greater_than: 0 }
  validates :upper_price, presence: true, numericality: { greater_than: 0 }
  validates :grid_count, presence: true, numericality: { greater_than_or_equal_to: 2, only_integer: true }
  validates :investment_amount, presence: true, numericality: { greater_than: 0 }
  validates :spacing_type, presence: true, inclusion: { in: SPACING_TYPES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :stop_reason, inclusion: { in: STOP_REASONS }, allow_nil: true
  validate :upper_price_greater_than_lower
  validate :stop_loss_below_lower_price
  validate :take_profit_above_upper_price

  scope :running, -> { where(status: 'running') }
  scope :active, -> { where(status: %w[running paused initializing]) }
  scope :kept, -> { where(discarded_at: nil) }

  def discard!
    update!(discarded_at: Time.current)
  end

  private

  def upper_price_greater_than_lower
    return unless upper_price && lower_price

    errors.add(:upper_price, 'must be greater than lower price') unless upper_price > lower_price
  end

  def stop_loss_below_lower_price
    return unless stop_loss_price && lower_price
    return if stop_loss_price < lower_price

    errors.add(:stop_loss_price, 'must be below lower price')
  end

  def take_profit_above_upper_price
    return unless take_profit_price && upper_price
    return if take_profit_price > upper_price

    errors.add(:take_profit_price, 'must be above upper price')
  end
end
