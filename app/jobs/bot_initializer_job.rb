# frozen_string_literal: true

class BotInitializerJob
  include Sidekiq::Worker

  sidekiq_options queue: :critical, retry: 0

  def perform(bot_id)
    bot = Bot.find_by!(id: bot_id)
    Grid::Initializer.new(bot).call
  end
end
