# frozen_string_literal: true

# == Schema Information
#
# Table name: trades
#
#  id            :bigint           not null, primary key
#  buy_price     :decimal(20, 8)   not null
#  completed_at  :datetime         not null
#  gross_profit  :decimal(20, 10)  not null
#  net_profit    :decimal(20, 10)  not null
#  quantity      :decimal(20, 8)   not null
#  sell_price    :decimal(20, 8)   not null
#  total_fees    :decimal(20, 10)  not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  bot_id        :bigint           not null
#  buy_order_id  :bigint           not null
#  grid_level_id :bigint           not null
#  sell_order_id :bigint           not null
#
# Indexes
#
#  index_trades_on_bot_id                   (bot_id)
#  index_trades_on_bot_id_and_completed_at  (bot_id,completed_at)
#  index_trades_on_buy_order_id             (buy_order_id)
#  index_trades_on_grid_level_id            (grid_level_id)
#  index_trades_on_sell_order_id            (sell_order_id)
#
# Foreign Keys
#
#  fk_rails_...  (bot_id => bots.id)
#  fk_rails_...  (buy_order_id => orders.id)
#  fk_rails_...  (grid_level_id => grid_levels.id)
#  fk_rails_...  (sell_order_id => orders.id)
#
require 'rails_helper'

RSpec.describe Trade, type: :model do
  describe 'associations' do
    it { is_expected.to belong_to(:bot) }
    it { is_expected.to belong_to(:grid_level) }
    it { is_expected.to belong_to(:buy_order).class_name('Order') }
    it { is_expected.to belong_to(:sell_order).class_name('Order') }
  end

  describe 'validations' do
    it { is_expected.to validate_presence_of(:buy_price) }
    it { is_expected.to validate_numericality_of(:buy_price).is_greater_than(0) }
    it { is_expected.to validate_presence_of(:sell_price) }
    it { is_expected.to validate_numericality_of(:sell_price).is_greater_than(0) }
    it { is_expected.to validate_presence_of(:quantity) }
    it { is_expected.to validate_numericality_of(:quantity).is_greater_than(0) }
    it { is_expected.to validate_presence_of(:gross_profit) }
    it { is_expected.to validate_presence_of(:total_fees) }
    it { is_expected.to validate_presence_of(:net_profit) }
    it { is_expected.to validate_presence_of(:completed_at) }
  end

  describe 'scopes' do
    let(:bot) { create(:bot) }
    let(:grid_level) { create(:grid_level, bot:) }

    let!(:profitable_trade) do
      create(:trade, bot:, grid_level:, net_profit: 10.0, completed_at: 1.hour.ago)
    end
    let!(:losing_trade) do
      create(:trade, bot:, grid_level:, net_profit: -5.0, completed_at: 2.hours.ago)
    end

    it '.profitable returns trades with positive net_profit' do
      expect(described_class.profitable).to contain_exactly(profitable_trade)
    end

    it '.recent orders by completed_at descending' do
      expect(described_class.recent).to eq([profitable_trade, losing_trade])
    end
  end
end
