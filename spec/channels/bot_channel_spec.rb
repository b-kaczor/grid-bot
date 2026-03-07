# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BotChannel, type: :channel do
  let(:exchange_account) { create(:exchange_account) }
  let(:bot) { create(:bot, exchange_account:) }

  describe '#subscribed' do
    it 'streams from the bot channel' do
      subscribe(bot_id: bot.id)
      expect(subscription).to be_confirmed
      expect(subscription).to have_stream_from("bot_#{bot.id}")
    end

    it 'rejects subscription for non-existent bot' do
      subscribe(bot_id: -1)
      expect(subscription).to be_rejected
    end
  end

  describe '#unsubscribed' do
    it 'stops all streams' do
      subscribe(bot_id: bot.id)
      unsubscribe
      expect(subscription).not_to have_streams
    end
  end
end
