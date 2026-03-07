# frozen_string_literal: true

require_relative '../../../app/services/exchange/response'

RSpec.describe Exchange::Response do
  it 'returns true for success? when success is true' do
    response = described_class.new(success: true, data: { price: '2500' })
    expect(response.success?).to be true
  end

  it 'returns false for success? when success is false' do
    response = described_class.new(success: false, error_code: '10001', error_message: 'Invalid param')
    expect(response.success?).to be false
  end

  it 'supports keyword initialization' do
    response = described_class.new(success: true, data: { list: [] }, error_code: nil, error_message: nil)
    expect(response.data).to eq({ list: [] })
    expect(response.error_code).to be_nil
  end
end
