# frozen_string_literal: true

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
