# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BalanceSnapshot, type: :model do
  describe 'associations' do
    it { is_expected.to belong_to(:bot) }
  end

  describe 'validations' do
    it { is_expected.to validate_presence_of(:granularity) }
    it { is_expected.to validate_inclusion_of(:granularity).in_array(BalanceSnapshot::GRANULARITIES) }
    it { is_expected.to validate_presence_of(:snapshot_at) }
  end

  describe 'scopes' do
    let(:bot) { create(:bot) }

    let!(:fine_snap) { create(:balance_snapshot, bot:, granularity: 'fine', snapshot_at: 1.hour.ago) }
    let!(:hourly_snap) { create(:balance_snapshot, bot:, granularity: 'hourly', snapshot_at: 2.hours.ago) }
    let!(:daily_snap) { create(:balance_snapshot, bot:, granularity: 'daily', snapshot_at: 1.day.ago) }

    it '.fine returns only fine granularity' do
      expect(described_class.fine).to contain_exactly(fine_snap)
    end

    it '.hourly returns only hourly granularity' do
      expect(described_class.hourly).to contain_exactly(hourly_snap)
    end

    it '.daily returns only daily granularity' do
      expect(described_class.daily).to contain_exactly(daily_snap)
    end

    it '.for_period filters by snapshot_at range' do
      expect(described_class.for_period(3.hours.ago, Time.current))
        .to contain_exactly(fine_snap, hourly_snap)
    end
  end

  describe 'constants' do
    it 'defines GRANULARITIES' do
      expect(BalanceSnapshot::GRANULARITIES).to eq(%w[fine hourly daily])
    end
  end
end
