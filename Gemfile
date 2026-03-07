# frozen_string_literal: true

source 'https://rubygems.org'

ruby '3.4.7'

gem 'bootsnap', require: false
gem 'pg', '~> 1.1'
gem 'puma', '>= 5.0'
gem 'rails', '~> 7.1.6'
gem 'tzinfo-data', platforms: %i[windows jruby]

# Background jobs
gem 'redis', '~> 5.0'
gem 'sidekiq', '~> 7.0'

# HTTP client
gem 'faraday', '~> 2.0'
gem 'faraday-retry', '~> 2.0'

# WebSocket (Phase 2, added now to avoid gem conflicts)
gem 'async-websocket', '~> 0.26'

# Encryption
gem 'lockbox', '~> 1.0'

# Environment variables
gem 'dotenv-rails', '~> 3.0'

# Fast JSON
gem 'oj', '~> 3.0'

# CORS
gem 'rack-cors'

group :development, :test do
  gem 'debug', platforms: %i[mri windows]
  gem 'factory_bot_rails', '~> 6.0'
  gem 'rspec-rails', '~> 7.0'
  gem 'rubocop', require: false
  gem 'rubocop-capybara', require: false
  gem 'rubocop-performance', require: false
  gem 'rubocop-rails', require: false
  gem 'rubocop-rspec', require: false
end

group :test do
  gem 'capybara', '~> 3.40'
  gem 'cuprite', '~> 0.15'
  gem 'database_cleaner-active_record', '~> 2.2'
  gem 'shoulda-matchers', '~> 6.0'
  gem 'webmock', '~> 3.0'
end
