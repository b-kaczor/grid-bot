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
class ExchangeAccount < ApplicationRecord
  has_many :bots, dependent: :restrict_with_error

  has_encrypted :api_key, :api_secret

  validates :name, presence: true
  validates :exchange, presence: true, inclusion: { in: %w[bybit] }
  validates :environment, presence: true, inclusion: { in: %w[testnet mainnet demo] }
  validates :api_key, presence: true
  validates :api_secret, presence: true
  validates :name, uniqueness: { scope: %i[exchange environment] }
end
