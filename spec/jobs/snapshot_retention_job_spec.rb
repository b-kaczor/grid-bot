# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SnapshotRetentionJob, type: :job do
  let(:bot) { create(:bot) }

  describe '#perform' do
    it 'runs without error when no snapshots exist' do
      expect { described_class.new.perform }.not_to raise_error
    end

    context 'with fine snapshots older than 7 days' do
      before do
        create(:balance_snapshot, bot:, granularity: 'fine', snapshot_at: 10.days.ago)
        create(:balance_snapshot, bot:, granularity: 'fine', snapshot_at: 8.days.ago)
        create(:balance_snapshot, bot:, granularity: 'fine', snapshot_at: 1.day.ago)
      end

      it 'deletes fine snapshots older than 7 days' do
        described_class.new.perform
        expect(bot.balance_snapshots.fine.where(snapshot_at: ...7.days.ago).count).to eq(0)
      end

      it 'keeps recent fine snapshots' do
        described_class.new.perform
        expect(bot.balance_snapshots.fine.where(snapshot_at: 7.days.ago..).count).to eq(1)
      end
    end

    context 'with fine snapshots in the 7-30 day window' do
      let!(:snapshot_8d) do
        create(:balance_snapshot, bot:, granularity: 'fine', snapshot_at: 8.days.ago.beginning_of_hour + 2.minutes)
      end
      let!(:snapshot_8d_2) do
        create(:balance_snapshot, bot:, granularity: 'fine', snapshot_at: 8.days.ago.beginning_of_hour + 30.minutes)
      end

      it 'creates hourly aggregates before deleting fine snapshots' do
        described_class.new.perform
        expect(bot.balance_snapshots.hourly.count).to be >= 1
      end

      it 'picks the snapshot closest to :00 for hourly aggregate' do
        described_class.new.perform
        hourly = bot.balance_snapshots.hourly.first
        expect(hourly).to be_present
        expect(hourly.base_balance).to eq(snapshot_8d.base_balance)
      end

      it 'deletes fine snapshots after downsampling' do
        described_class.new.perform
        expect(bot.balance_snapshots.fine.where(snapshot_at: ...7.days.ago).count).to eq(0)
      end
    end

    context 'with hourly snapshots older than 30 days' do
      let!(:hourly_old_1) do
        create(:balance_snapshot, bot:, granularity: 'hourly', snapshot_at: 35.days.ago.beginning_of_day + 6.hours)
      end
      let!(:hourly_old_2) do
        create(:balance_snapshot, bot:, granularity: 'hourly', snapshot_at: 35.days.ago.beginning_of_day + 18.hours)
      end

      it 'creates daily aggregates from hourly snapshots' do
        described_class.new.perform
        expect(bot.balance_snapshots.daily.count).to be >= 1
      end

      it 'picks the last snapshot of the day for daily aggregate' do
        described_class.new.perform
        daily = bot.balance_snapshots.daily.first
        expect(daily).to be_present
        expect(daily.snapshot_at).to eq(hourly_old_2.snapshot_at)
      end

      it 'deletes hourly snapshots older than 30 days' do
        described_class.new.perform
        expect(bot.balance_snapshots.hourly.where(snapshot_at: ...30.days.ago).count).to eq(0)
      end
    end

    context 'with existing aggregates (idempotency)' do
      let!(:fine_old) do
        create(:balance_snapshot, bot:, granularity: 'fine', snapshot_at: 10.days.ago.beginning_of_hour + 5.minutes)
      end
      let!(:existing_hourly) do
        create(:balance_snapshot, bot:, granularity: 'hourly', snapshot_at: 10.days.ago.beginning_of_hour)
      end

      it 'does not create duplicate hourly aggregates' do
        expect { described_class.new.perform }.not_to(change { bot.balance_snapshots.hourly.count })
      end
    end

    context 'with multiple bots' do
      let(:bot2) { create(:bot) }

      before do
        create(:balance_snapshot, bot:, granularity: 'fine', snapshot_at: 10.days.ago)
        create(:balance_snapshot, bot: bot2, granularity: 'fine', snapshot_at: 10.days.ago)
      end

      it 'processes all bots' do
        described_class.new.perform
        expect(BalanceSnapshot.fine.where(snapshot_at: ...7.days.ago).count).to eq(0)
      end
    end
  end
end
