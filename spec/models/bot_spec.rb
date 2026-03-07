# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Bot, type: :model do
  describe 'associations' do
    it { is_expected.to belong_to(:exchange_account) }
    it { is_expected.to have_many(:grid_levels).dependent(:destroy) }
    it { is_expected.to have_many(:orders).dependent(:destroy) }
    it { is_expected.to have_many(:trades).dependent(:destroy) }
    it { is_expected.to have_many(:balance_snapshots).dependent(:destroy) }
  end

  describe 'validations' do
    it { is_expected.to validate_presence_of(:pair) }
    it { is_expected.to validate_presence_of(:base_coin) }
    it { is_expected.to validate_presence_of(:quote_coin) }
    it { is_expected.to validate_presence_of(:lower_price) }
    it { is_expected.to validate_numericality_of(:lower_price).is_greater_than(0) }
    it { is_expected.to validate_presence_of(:upper_price) }
    it { is_expected.to validate_numericality_of(:upper_price).is_greater_than(0) }
    it { is_expected.to validate_presence_of(:grid_count) }
    it { is_expected.to validate_numericality_of(:grid_count).is_greater_than_or_equal_to(2).only_integer }
    it { is_expected.to validate_presence_of(:investment_amount) }
    it { is_expected.to validate_numericality_of(:investment_amount).is_greater_than(0) }
    it { is_expected.to validate_presence_of(:spacing_type) }
    it { is_expected.to validate_inclusion_of(:spacing_type).in_array(Bot::SPACING_TYPES) }
    it { is_expected.to validate_presence_of(:status) }
    it { is_expected.to validate_inclusion_of(:status).in_array(Bot::STATUSES) }
    it { is_expected.to validate_inclusion_of(:stop_reason).in_array(Bot::STOP_REASONS) }

    it 'validates upper_price is greater than lower_price' do
      bot = build(:bot, lower_price: 3000, upper_price: 2000)
      expect(bot).not_to be_valid
      expect(bot.errors[:upper_price]).to include('must be greater than lower price')
    end

    it 'allows upper_price greater than lower_price' do
      bot = build(:bot, lower_price: 2000, upper_price: 3000)
      expect(bot).to be_valid
    end
  end

  describe 'scopes' do
    let!(:running_bot) { create(:bot, status: 'running') }
    let!(:paused_bot) { create(:bot, status: 'paused') }
    let!(:stopped_bot) { create(:bot, status: 'stopped') }
    let!(:initializing_bot) { create(:bot, status: 'initializing') }

    it '.running returns only running bots' do
      expect(described_class.running).to contain_exactly(running_bot)
    end

    it '.active returns running, paused, and initializing bots' do
      expect(described_class.active).to contain_exactly(running_bot, paused_bot, initializing_bot)
    end
  end

  describe 'constants' do
    it 'defines STATUSES' do
      expect(Bot::STATUSES).to eq(%w[pending initializing running paused stopped error])
    end

    it 'defines SPACING_TYPES' do
      expect(Bot::SPACING_TYPES).to eq(%w[arithmetic geometric])
    end
  end
end
