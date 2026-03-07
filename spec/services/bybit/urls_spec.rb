# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Bybit::Urls do
  describe '.for' do
    it 'returns testnet URLs' do
      urls = described_class.for('testnet')
      expect(urls[:rest]).to eq('https://api-testnet.bybit.com')
      expect(urls[:ws_private]).to include('stream-testnet.bybit.com')
    end

    it 'returns mainnet URLs' do
      urls = described_class.for('mainnet')
      expect(urls[:rest]).to eq('https://api.bybit.com')
      expect(urls[:ws_private]).to include('stream.bybit.com')
    end

    it 'returns demo URLs' do
      urls = described_class.for('demo')
      expect(urls[:rest]).to eq('https://api-demo.bybit.com')
      expect(urls[:ws_private]).to include('stream-demo.bybit.com')
    end

    it 'raises ArgumentError for unknown environment' do
      expect { described_class.for('invalid') }.to raise_error(ArgumentError, /Unknown Bybit environment/)
    end
  end
end
