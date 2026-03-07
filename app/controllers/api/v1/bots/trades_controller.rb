# frozen_string_literal: true

module Api
  module V1
    module Bots
      class TradesController < BaseController
        def index
          bot = Bot.kept.find_by!(id: params[:bot_id])
          scope = bot.trades.includes(:grid_level).order(completed_at: :desc)
          result = paginate(scope)

          render json: {
            trades: result[:records].map { |t| trade_response(t) },
            pagination: result.except(:records),
          }
        end

        private

        def trade_response(trade)
          {
            id: trade.id,
            level_index: trade.grid_level.level_index,
            buy_price: trade.buy_price.to_s,
            sell_price: trade.sell_price.to_s,
            quantity: trade.quantity.to_s,
            gross_profit: trade.gross_profit.to_s,
            total_fees: trade.total_fees.to_s,
            net_profit: trade.net_profit.to_s,
            completed_at: trade.completed_at.iso8601,
          }
        end
      end
    end
  end
end
