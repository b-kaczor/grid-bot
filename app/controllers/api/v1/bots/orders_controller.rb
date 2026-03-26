# frozen_string_literal: true

module Api
  module V1
    module Bots
      class OrdersController < BaseController
        def index
          bot = Bot.kept.find_by!(id: params[:bot_id])
          scope = bot.orders.includes(:grid_level).where(status: 'filled').order(filled_at: :desc)
          result = paginate(scope)

          render json: {
            orders: result[:records].map { |o| order_response(o) },
            pagination: result.except(:records),
          }
        end

        private

        def order_response(order)
          {
            id: order.id,
            level_index: order.grid_level.level_index,
            side: order.side,
            price: order.price.to_s,
            quantity: order.quantity.to_s,
            avg_fill_price: order.avg_fill_price&.to_s,
            filled_quantity: order.filled_quantity&.to_s,
            fee: order.fee&.to_s,
            fee_coin: order.fee_coin,
            filled_at: order.filled_at&.iso8601,
          }
        end
      end
    end
  end
end
