# frozen_string_literal: true

class SnapshotRetentionJob
  include Sidekiq::Worker

  sidekiq_options queue: :default, retry: 3

  FINE_RETENTION    = 7  # days
  HOURLY_RETENTION  = 30 # days

  def perform
    Bot.find_each do |bot|
      ActiveRecord::Base.transaction do
        downsample_fine_to_hourly(bot)
        downsample_hourly_to_daily(bot)
        purge_stale_fine(bot)
        purge_stale_hourly(bot)
      end
    end
  end

  private

  # For snapshots 7-30 days old: create hourly aggregates from fine, then delete fine
  def downsample_fine_to_hourly(bot)
    cutoff = FINE_RETENTION.days.ago
    oldest = HOURLY_RETENTION.days.ago

    fine_snapshots = bot.balance_snapshots
      .fine
      .where(snapshot_at: oldest..cutoff)
      .order(:snapshot_at)

    fine_snapshots.group_by { |s| s.snapshot_at.beginning_of_hour }.each do |hour, snapshots|
      next if bot.balance_snapshots.hourly.exists?(snapshot_at: hour..hour.end_of_hour)

      # Pick the snapshot closest to the top of the hour
      representative = snapshots.min_by { |s| (s.snapshot_at - hour).abs }
      create_aggregate(representative, granularity: 'hourly', snapshot_at: hour)
    end
  end

  # For snapshots older than 30 days: create daily aggregates from hourly, then delete hourly
  def downsample_hourly_to_daily(bot)
    cutoff = HOURLY_RETENTION.days.ago

    hourly_snapshots = bot.balance_snapshots
      .hourly
      .where(snapshot_at: ...cutoff)
      .order(:snapshot_at)

    hourly_snapshots.group_by { |s| s.snapshot_at.to_date }.each do |date, snapshots|
      day_start = date.beginning_of_day
      day_end = date.end_of_day

      next if bot.balance_snapshots.daily.exists?(snapshot_at: day_start..day_end)

      # Pick the last snapshot of the day
      representative = snapshots.max_by(&:snapshot_at)
      create_aggregate(representative, granularity: 'daily', snapshot_at: representative.snapshot_at)
    end
  end

  def purge_stale_fine(bot)
    bot.balance_snapshots.fine.where(snapshot_at: ...FINE_RETENTION.days.ago).delete_all
  end

  def purge_stale_hourly(bot)
    bot.balance_snapshots.hourly.where(snapshot_at: ...HOURLY_RETENTION.days.ago).delete_all
  end

  def create_aggregate(source, granularity:, snapshot_at:)
    BalanceSnapshot.create!(
      bot_id: source.bot_id,
      base_balance: source.base_balance,
      quote_balance: source.quote_balance,
      total_value_quote: source.total_value_quote,
      current_price: source.current_price,
      realized_profit: source.realized_profit,
      unrealized_pnl: source.unrealized_pnl,
      granularity:,
      snapshot_at:
    )
  end
end
