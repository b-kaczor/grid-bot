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
FactoryBot.define do
  factory :bot do
    exchange_account
    pair { 'ETHUSDT' }
    base_coin { 'ETH' }
    quote_coin { 'USDT' }
    lower_price { 2000.0 }
    upper_price { 3000.0 }
    grid_count { 10 }
    spacing_type { 'arithmetic' }
    investment_amount { 1000.0 }
    status { 'pending' }
  end
end
