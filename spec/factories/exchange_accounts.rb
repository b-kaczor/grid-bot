# frozen_string_literal: true

# == Schema Information
#
# Table name: exchange_accounts
#
#  id                    :bigint           not null, primary key
#  api_key_ciphertext    :text             not null
#  api_secret_ciphertext :text             not null
#  environment           :string           default("testnet"), not null
#  exchange              :string           default("bybit"), not null
#  name                  :string           not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#
# Indexes
#
#  index_exchange_accounts_on_exchange_and_environment_and_name  (exchange,environment,name) UNIQUE
#
FactoryBot.define do
  factory :exchange_account do
    sequence(:name) { |n| "Account #{n}" }
    exchange { 'bybit' }
    api_key { "test_api_key_#{SecureRandom.hex(8)}" }
    api_secret { "test_api_secret_#{SecureRandom.hex(8)}" }
    environment { 'testnet' }
  end
end
