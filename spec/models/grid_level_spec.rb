# frozen_string_literal: true

# == Schema Information
#
# Table name: grid_levels
#
#  id                    :bigint           not null, primary key
#  cycle_count           :integer          default(0), not null
#  expected_side         :string           not null
#  level_index           :integer          not null
#  lock_version          :integer          default(0), not null
#  price                 :decimal(20, 8)   not null
#  status                :string           default("pending"), not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  bot_id                :bigint           not null
#  current_order_id      :string
#  current_order_link_id :string
#
# Indexes
#
#  index_grid_levels_on_bot_id                  (bot_id)
#  index_grid_levels_on_bot_id_and_level_index  (bot_id,level_index) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (bot_id => bots.id)
#
require 'rails_helper'

RSpec.describe GridLevel, type: :model do
  describe 'associations' do
    it { is_expected.to belong_to(:bot) }
    it { is_expected.to have_many(:orders).dependent(:destroy) }
    it { is_expected.to have_many(:trades).dependent(:destroy) }
  end

  describe 'validations' do
    subject { build(:grid_level) }

    it { is_expected.to validate_presence_of(:level_index) }
    it { is_expected.to validate_numericality_of(:level_index).is_greater_than_or_equal_to(0).only_integer }
    it { is_expected.to validate_uniqueness_of(:level_index).scoped_to(:bot_id) }
    it { is_expected.to validate_presence_of(:price) }
    it { is_expected.to validate_numericality_of(:price).is_greater_than(0) }
    it { is_expected.to validate_presence_of(:expected_side) }
    it { is_expected.to validate_inclusion_of(:expected_side).in_array(GridLevel::SIDES) }
    it { is_expected.to validate_presence_of(:status) }
    it { is_expected.to validate_inclusion_of(:status).in_array(GridLevel::STATUSES) }
    it { is_expected.to validate_numericality_of(:cycle_count).is_greater_than_or_equal_to(0) }
  end

  describe 'constants' do
    it 'defines SIDES' do
      expect(GridLevel::SIDES).to eq(%w[buy sell])
    end

    it 'defines STATUSES' do
      expect(GridLevel::STATUSES).to eq(%w[pending active filled skipped])
    end
  end
end
