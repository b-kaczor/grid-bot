# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Order, type: :model do
  describe 'associations' do
    it { is_expected.to belong_to(:bot) }
    it { is_expected.to belong_to(:grid_level) }
  end

  describe 'validations' do
    subject { build(:order) }

    it { is_expected.to validate_presence_of(:order_link_id) }
    it { is_expected.to validate_uniqueness_of(:order_link_id) }
    it { is_expected.to validate_presence_of(:side) }
    it { is_expected.to validate_inclusion_of(:side).in_array(Order::SIDES) }
    it { is_expected.to validate_presence_of(:price) }
    it { is_expected.to validate_numericality_of(:price).is_greater_than(0) }
    it { is_expected.to validate_presence_of(:quantity) }
    it { is_expected.to validate_numericality_of(:quantity).is_greater_than(0) }
    it { is_expected.to validate_presence_of(:status) }
    it { is_expected.to validate_inclusion_of(:status).in_array(Order::STATUSES) }
  end

  describe 'scopes' do
    let(:bot) { create(:bot) }
    let(:grid_level) { create(:grid_level, bot:) }

    let!(:open_order) { create(:order, bot:, grid_level:, status: 'open') }
    let!(:partial_order) { create(:order, bot:, grid_level:, status: 'partially_filled') }
    let!(:filled_order) { create(:order, bot:, grid_level:, status: 'filled', side: 'sell') }
    let!(:cancelled_order) { create(:order, bot:, grid_level:, status: 'cancelled') }

    it '.active returns open and partially_filled' do
      expect(described_class.active).to contain_exactly(open_order, partial_order)
    end

    it '.filled returns only filled orders' do
      expect(described_class.filled).to contain_exactly(filled_order)
    end

    it '.buys returns only buy orders' do
      expect(described_class.buys).to contain_exactly(open_order, partial_order, cancelled_order)
    end

    it '.sells returns only sell orders' do
      expect(described_class.sells).to contain_exactly(filled_order)
    end
  end

  describe '#effective_quantity' do
    it 'returns net_quantity when present' do
      order = build(:order, net_quantity: 0.09, filled_quantity: 0.1)
      expect(order.effective_quantity).to eq(0.09)
    end

    it 'returns filled_quantity when net_quantity is nil' do
      order = build(:order, net_quantity: nil, filled_quantity: 0.1)
      expect(order.effective_quantity).to eq(0.1)
    end
  end
end
