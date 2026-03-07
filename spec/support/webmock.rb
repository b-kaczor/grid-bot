# frozen_string_literal: true

require 'webmock/rspec'

# Default: block all net connections
WebMock.disable_net_connect!

RSpec.configure do |config|
  # Feature specs need localhost for Capybara server + Chrome CDP
  config.before(:each, type: :feature) do
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  config.after(:each, type: :feature) do
    WebMock.disable_net_connect!
  end
end
