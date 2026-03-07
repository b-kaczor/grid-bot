# frozen_string_literal: true

require 'capybara/rspec'
require 'capybara/cuprite'

Capybara.register_driver :cuprite do |app|
  Capybara::Cuprite::Driver.new(
    app,
    window_size: [1280, 800],
    headless: true,
    process_timeout: 15,
    timeout: 10,
    browser_options: {
      'no-sandbox' => nil,
      'disable-gpu' => nil,
    }
  )
end

Capybara.default_driver    = :rack_test
Capybara.javascript_driver = :cuprite
Capybara.default_max_wait_time = 5
Capybara.server = :puma, { Silent: true }

RSpec.configure do |config|
  # All feature specs need the JS driver (Cuprite) for the React SPA
  config.before(:each, type: :feature) do
    Capybara.current_driver = :cuprite
  end
end
