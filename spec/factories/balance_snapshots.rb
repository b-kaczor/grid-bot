# frozen_string_literal: true

# == Schema Information
#
# Table name: balance_snapshots
#
#  id                :bigint           not null, primary key
#  base_balance      :decimal(20, 8)
#  current_price     :decimal(20, 8)
#  granularity       :string           default("fine"), not null
#  quote_balance     :decimal(20, 8)
#  realized_profit   :decimal(20, 8)
#  snapshot_at       :datetime         not null
#  total_value_quote :decimal(20, 8)
#  unrealized_pnl    :decimal(20, 8)
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  bot_id            :bigint           not null
#
# Indexes
#
#  idx_on_bot_id_granularity_snapshot_at_9f7187b3be   (bot_id,granularity,snapshot_at)
#  index_balance_snapshots_on_bot_id                  (bot_id)
#  index_balance_snapshots_on_bot_id_and_snapshot_at  (bot_id,snapshot_at)
#
# Foreign Keys
#
#  fk_rails_...  (bot_id => bots.id)
#
FactoryBot.define do
  factory :balance_snapshot do
    bot
    base_balance { 1.0 }
    quote_balance { 1000.0 }
    total_value_quote { 3500.0 }
    current_price { 2500.0 }
    realized_profit { 50.0 }
    unrealized_pnl { 10.0 }
    granularity { 'fine' }
    snapshot_at { Time.current }
  end
end
