# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ExchangeAccount, type: :model do
  describe 'associations' do
    it { is_expected.to have_many(:bots).dependent(:restrict_with_error) }
  end

  describe 'validations' do
    subject { build(:exchange_account) }

    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_presence_of(:exchange) }
    it { is_expected.to validate_inclusion_of(:exchange).in_array(%w[bybit]) }
    it { is_expected.to validate_presence_of(:environment) }
    it { is_expected.to validate_inclusion_of(:environment).in_array(%w[testnet mainnet demo]) }
    it { is_expected.to validate_presence_of(:api_key) }
    it { is_expected.to validate_presence_of(:api_secret) }
    it { is_expected.to validate_uniqueness_of(:name).scoped_to(:exchange, :environment) }
  end

  describe 'encryption' do
    it 'encrypts api_key' do
      account = create(:exchange_account, api_key: 'my_key')
      raw = described_class.connection.select_value(
        "SELECT api_key_ciphertext FROM exchange_accounts WHERE id = #{account.id}"
      )
      expect(raw).not_to eq('my_key')
      expect(raw).to be_present
      expect(account.api_key).to eq('my_key')
    end

    it 'encrypts api_secret' do
      account = create(:exchange_account, api_secret: 'my_secret')
      raw = described_class.connection.select_value(
        "SELECT api_secret_ciphertext FROM exchange_accounts WHERE id = #{account.id}"
      )
      expect(raw).not_to eq('my_secret')
      expect(raw).to be_present
      expect(account.api_secret).to eq('my_secret')
    end
  end
end
