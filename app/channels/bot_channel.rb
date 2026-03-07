# frozen_string_literal: true

class BotChannel < ApplicationCable::Channel
  def subscribed
    bot = Bot.find_by(id: params[:bot_id])

    if bot
      stream_from "bot_#{bot.id}"
    else
      reject
    end
  end

  def unsubscribed
    stop_all_streams
  end
end
