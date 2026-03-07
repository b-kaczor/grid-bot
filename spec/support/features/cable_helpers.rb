# frozen_string_literal: true

module Features
  module CableHelpers
    # Broadcast a message to the bot's ActionCable channel.
    # With the async adapter active, this reaches the browser's WebSocket connection.
    def broadcast_to_bot(bot_id, message)
      ActionCable.server.broadcast("bot_#{bot_id}", message)
    end
  end
end

RSpec.configure do |config|
  config.include Features::CableHelpers, type: :feature

  # Switch to async adapter so broadcasts reach real browser WebSocket connections.
  # The default 'test' adapter only buffers broadcasts for assertion --
  # it does NOT deliver to connected clients.
  config.before(:each, type: :feature) do
    ActionCable.server.config.cable = { 'adapter' => 'async' }
    ActionCable.server.restart
  end

  config.after(:each, type: :feature) do
    ActionCable.server.config.cable = { 'adapter' => 'test' }
    ActionCable.server.restart
  end
end
