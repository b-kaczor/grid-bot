# frozen_string_literal: true

# == Schema Information
#
# Table name: bots
#
#  id                  :bigint           not null, primary key
#  base_coin           :string           not null
#  base_precision      :integer
#  discarded_at        :datetime
#  grid_count          :integer          not null
#  investment_amount   :decimal(20, 8)   not null
#  lower_price         :decimal(20, 8)   not null
#  max_order_qty       :decimal(20, 8)
#  min_order_amt       :decimal(20, 8)
#  min_order_qty       :decimal(20, 8)
#  pair                :string           not null
#  quantity_per_level  :decimal(20, 8)
#  quote_coin          :string           not null
#  quote_precision     :integer
#  spacing_type        :string           default("arithmetic"), not null
#  status              :string           default("pending"), not null
#  stop_loss_price     :decimal(20, 8)
#  stop_reason         :string
#  take_profit_price   :decimal(20, 8)
#  tick_size           :decimal(20, 12)
#  trailing_up_enabled :boolean          default(FALSE), not null
#  upper_price         :decimal(20, 8)   not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  exchange_account_id :bigint           not null
#
# Indexes
#
#  index_bots_on_exchange_account_id  (exchange_account_id)
#
# Foreign Keys
#
#  fk_rails_...  (exchange_account_id => exchange_accounts.id)
#
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

    describe 'stop_loss_price' do
      it 'is invalid when stop_loss_price >= lower_price' do
        bot = build(:bot, lower_price: 2000, upper_price: 3000, stop_loss_price: 2000)
        expect(bot).not_to be_valid
        expect(bot.errors[:stop_loss_price]).to include('must be below lower price')
      end

      it 'is invalid when stop_loss_price > lower_price' do
        bot = build(:bot, lower_price: 2000, upper_price: 3000, stop_loss_price: 2500)
        expect(bot).not_to be_valid
        expect(bot.errors[:stop_loss_price]).to include('must be below lower price')
      end

      it 'is valid when stop_loss_price < lower_price' do
        bot = build(:bot, lower_price: 2000, upper_price: 3000, stop_loss_price: 1900)
        expect(bot).to be_valid
      end

      it 'skips validation when stop_loss_price is nil' do
        bot = build(:bot, lower_price: 2000, upper_price: 3000, stop_loss_price: nil)
        expect(bot).to be_valid
      end
    end

    describe 'take_profit_price' do
      it 'is invalid when take_profit_price <= upper_price' do
        bot = build(:bot, lower_price: 2000, upper_price: 3000, take_profit_price: 3000)
        expect(bot).not_to be_valid
        expect(bot.errors[:take_profit_price]).to include('must be above upper price')
      end

      it 'is invalid when take_profit_price < upper_price' do
        bot = build(:bot, lower_price: 2000, upper_price: 3000, take_profit_price: 2500)
        expect(bot).not_to be_valid
        expect(bot.errors[:take_profit_price]).to include('must be above upper price')
      end

      it 'is valid when take_profit_price > upper_price' do
        bot = build(:bot, lower_price: 2000, upper_price: 3000, take_profit_price: 3500)
        expect(bot).to be_valid
      end

      it 'skips validation when take_profit_price is nil' do
        bot = build(:bot, lower_price: 2000, upper_price: 3000, take_profit_price: nil)
        expect(bot).to be_valid
      end
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

    describe '.kept' do
      let!(:kept_bot) { create(:bot, status: 'running') }
      let!(:discarded_bot) { create(:bot, status: 'stopped', discarded_at: Time.current) }

      it 'returns only bots without discarded_at' do
        expect(described_class.kept).to include(kept_bot)
        expect(described_class.kept).not_to include(discarded_bot)
      end
    end
  end

  describe '#discard!' do
    let(:bot) { create(:bot, status: 'stopped') }

    it 'sets discarded_at to current time' do
      bot.discard!
      expect(bot.reload.discarded_at).to be_within(2.seconds).of(Time.current)
    end

    it 'persists the change' do
      bot.discard!
      expect(bot.reload.discarded_at).to be_present
    end
  end

  describe 'constants' do
    it 'defines STATUSES' do
      expect(Bot::STATUSES).to eq(%w[pending initializing running paused stopping stopped error])
    end

    it 'defines SPACING_TYPES' do
      expect(Bot::SPACING_TYPES).to eq(%w[arithmetic geometric])
    end
  end
end
