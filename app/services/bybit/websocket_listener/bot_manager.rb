# frozen_string_literal: true

module Bybit
  class WebsocketListener
    module BotManager
      def pause_all_bots(reason)
        Bot.running.find_each do |bot|
          bot.update!(status: 'paused', stop_reason: reason)
          @redis_state.update_status(bot.id, 'paused')
        end
      end

      def resume_after_maintenance
        Bot.where(status: 'paused', stop_reason: 'maintenance').find_each do |bot|
          bot.update!(status: 'running', stop_reason: nil)
          @redis_state.update_status(bot.id, 'running')
        end
        trigger_reconciliation_for_all_bots
        Rails.logger.info('[WS] Reconnected after maintenance. Bots resumed.')
      end

      def trigger_reconciliation_for_all_bots
        Bot.running.find_each do |bot|
          GridReconciliationWorker.perform_async(bot.id)
        end
      end
    end
  end
end
