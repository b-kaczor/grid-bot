# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Bybit error hierarchy' do
  it 'defines Bybit::Error as base error' do
    expect(Bybit::Error.superclass).to eq(StandardError)
  end

  it 'defines AuthenticationError inheriting from Error' do
    expect(Bybit::AuthenticationError.superclass).to eq(Bybit::Error)
  end

  it 'defines RateLimitError inheriting from Error' do
    expect(Bybit::RateLimitError.superclass).to eq(Bybit::Error)
  end

  it 'defines OrderError inheriting from Error' do
    expect(Bybit::OrderError.superclass).to eq(Bybit::Error)
  end

  it 'defines NetworkError inheriting from Error' do
    expect(Bybit::NetworkError.superclass).to eq(Bybit::Error)
  end

  it 'allows rescuing all Bybit errors with Bybit::Error' do
    expect do
      raise Bybit::RateLimitError, 'too many requests'
    end.to raise_error(Bybit::Error, 'too many requests')
  end
end
