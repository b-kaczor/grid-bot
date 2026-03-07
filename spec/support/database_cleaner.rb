# frozen_string_literal: true

require 'database_cleaner/active_record'

RSpec.configure do |config|
  config.before(:suite) do
    next unless RSpec.configuration.files_to_run.any? { |f| f.include?('spec/features') }

    DatabaseCleaner.clean_with(:truncation)
  end

  config.before(:each, type: :feature) do
    self.use_transactional_tests = false
    DatabaseCleaner.strategy = :truncation
    DatabaseCleaner.start
  end

  config.after(:each, type: :feature) do
    # Reset browser sessions first to ensure Puma finishes all requests
    # before truncating tables (prevents deadlocks)
    Capybara.reset_sessions!
    DatabaseCleaner.clean
  end
end
