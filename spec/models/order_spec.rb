# frozen_string_literal: true

# == Schema Information
#
# Table name: orders
#
#  id                :bigint           not null, primary key
#  avg_fill_price    :decimal(20, 8)
#  fee               :decimal(20, 10)  default(0.0)
#  fee_coin          :string
#  filled_at         :datetime
#  filled_quantity   :decimal(20, 8)   default(0.0)
#  net_quantity      :decimal(20, 8)
#  placed_at         :datetime
#  price             :decimal(20, 8)   not null
#  quantity          :decimal(20, 8)   not null
#  side              :string           not null
#  status            :string           default("pending"), not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  bot_id            :bigint           not null
#  exchange_order_id :string
#  grid_level_id     :bigint           not null
#  order_link_id     :string           not null
#  paired_order_id   :bigint
#
# Indexes
#
#  index_orders_on_bot_id                    (bot_id)
#  index_orders_on_bot_id_and_status         (bot_id,status)
#  index_orders_on_exchange_order_id         (exchange_order_id)
#  index_orders_on_grid_level_id             (grid_level_id)
#  index_orders_on_grid_level_id_and_status  (grid_level_id,status)
#  index_orders_on_order_link_id             (order_link_id) UNIQUE
#  index_orders_on_paired_order_id           (paired_order_id)
#
# Foreign Keys
#
#  fk_rails_...  (bot_id => bots.id)
#  fk_rails_...  (grid_level_id => grid_levels.id)
#  fk_rails_...  (paired_order_id => orders.id)
#
require 'rails_helper'

RSpec.describe Order, type: :model do
  describe 'associations' do
    it { is_expected.to belong_to(:bot) }
    it { is_expected.to belong_to(:grid_level) }
    it { is_expected.to belong_to(:paired_order).class_name('Order').optional }
  end

  describe 'paired_order association' do
    let(:bot) { create(:bot) }
    let(:grid_level) { create(:grid_level, bot:) }
    let(:buy_order) { create(:order, bot:, grid_level:, side: 'buy', status: 'filled') }

    it 'links a counter-order back to its trigger order' do
      sell_order = create(:order, bot:, grid_level:, side: 'sell', status: 'open', paired_order: buy_order)

      expect(sell_order.paired_order).to eq(buy_order)
    end

    it 'allows nil paired_order for initial orders' do
      order = create(:order, bot:, grid_level:, paired_order: nil)

      expect(order.paired_order).to be_nil
    end
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
