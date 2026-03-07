# frozen_string_literal: true

module Features
  module NavigationHelpers
    def visit_dashboard
      visit '/bots'
    end

    def visit_bot_detail(bot)
      visit "/bots/#{bot.id}"
    end

    def visit_create_bot
      visit '/bots/new'
    end
  end
end

RSpec.configure do |config|
  config.include Features::NavigationHelpers, type: :feature
end
