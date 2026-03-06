require "rails_helper"

RSpec.describe Trade, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:bot) }
    it { is_expected.to belong_to(:grid_level) }
    it { is_expected.to belong_to(:buy_order).class_name("Order") }
    it { is_expected.to belong_to(:sell_order).class_name("Order") }
  end

  describe "validations" do
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

  describe "scopes" do
    let(:bot) { create(:bot) }
    let(:grid_level) { create(:grid_level, bot:) }

    let!(:profitable_trade) do
      create(:trade, bot:, grid_level:, net_profit: 10.0, completed_at: 1.hour.ago)
    end
    let!(:losing_trade) do
      create(:trade, bot:, grid_level:, net_profit: -5.0, completed_at: 2.hours.ago)
    end

    it ".profitable returns trades with positive net_profit" do
      expect(Trade.profitable).to contain_exactly(profitable_trade)
    end

    it ".recent orders by completed_at descending" do
      expect(Trade.recent).to eq([profitable_trade, losing_trade])
    end
  end
end
