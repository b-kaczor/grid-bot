class BalanceSnapshot < ApplicationRecord
  belongs_to :bot

  GRANULARITIES = %w[fine hourly daily].freeze

  validates :granularity, presence: true, inclusion: { in: GRANULARITIES }
  validates :snapshot_at, presence: true

  scope :fine, -> { where(granularity: "fine") }
  scope :hourly, -> { where(granularity: "hourly") }
  scope :daily, -> { where(granularity: "daily") }
  scope :for_period, ->(from, to) { where(snapshot_at: from..to) }
end
