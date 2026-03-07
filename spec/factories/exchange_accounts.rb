# frozen_string_literal: true

FactoryBot.define do
  factory :exchange_account do
    sequence(:name) { |n| "Account #{n}" }
    exchange { 'bybit' }
    api_key { "test_api_key_#{SecureRandom.hex(8)}" }
    api_secret { "test_api_secret_#{SecureRandom.hex(8)}" }
    environment { 'testnet' }
  end
end
