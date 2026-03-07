# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Bybit::Auth do
  let(:api_key) { 'test_api_key_123' }
  let(:api_secret) { 'test_api_secret_456' }
  let(:auth) { described_class.new(api_key:, api_secret:) }

  describe '#sign_request' do
    let(:timestamp) { 1_672_531_200_000 }

    it 'returns all 4 required headers' do
      headers = auth.sign_request(timestamp:)

      expect(headers).to include(
        'X-BAPI-API-KEY' => api_key,
        'X-BAPI-TIMESTAMP' => timestamp.to_s,
        'X-BAPI-RECV-WINDOW' => '5000'
      )
      expect(headers['X-BAPI-SIGN']).to be_a(String)
      expect(headers['X-BAPI-SIGN'].length).to eq(64)
    end

    it 'produces correct HMAC-SHA256 signature without params' do
      headers = auth.sign_request(timestamp:)

      expected_payload = "#{timestamp}#{api_key}5000"
      expected_signature = OpenSSL::HMAC.hexdigest('SHA256', api_secret, expected_payload)

      expect(headers['X-BAPI-SIGN']).to eq(expected_signature)
    end

    it 'includes params_string in the signature payload' do
      params = 'symbol=ETHUSDT&side=Buy'
      headers = auth.sign_request(timestamp:, params_string: params)

      expected_payload = "#{timestamp}#{api_key}5000#{params}"
      expected_signature = OpenSSL::HMAC.hexdigest('SHA256', api_secret, expected_payload)

      expect(headers['X-BAPI-SIGN']).to eq(expected_signature)
    end

    it 'produces different signatures for different params' do
      headers1 = auth.sign_request(timestamp:, params_string: 'a=1')
      headers2 = auth.sign_request(timestamp:, params_string: 'a=2')

      expect(headers1['X-BAPI-SIGN']).not_to eq(headers2['X-BAPI-SIGN'])
    end

    it 'produces different signatures for different timestamps' do
      headers1 = auth.sign_request(timestamp: 1000)
      headers2 = auth.sign_request(timestamp: 2000)

      expect(headers1['X-BAPI-SIGN']).not_to eq(headers2['X-BAPI-SIGN'])
    end

    it 'converts timestamp to string in headers' do
      headers = auth.sign_request(timestamp:)

      expect(headers['X-BAPI-TIMESTAMP']).to eq('1672531200000')
    end
  end

  describe 'RECV_WINDOW' do
    it 'is set to 5000' do
      expect(described_class::RECV_WINDOW).to eq('5000')
    end
  end
end
