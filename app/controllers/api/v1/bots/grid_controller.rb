# frozen_string_literal: true

module Api
  module V1
    module Bots
      class GridController < BaseController
        def show
          bot = Bot.kept.find_by!(id: params[:bot_id])
          redis = Grid::RedisState.new
          current_price = redis.read_price(bot.id)

          render json: {
            grid: {
              current_price: current_price || fallback_price(bot),
              levels: serialize_levels(bot),
            },
          }
        end

        private

        def fallback_price(bot)
          bot.balance_snapshots.order(snapshot_at: :desc).first&.current_price&.to_s
        end

        def serialize_levels(bot)
          bot.grid_levels.order(:level_index).map do |level|
            {
              level_index: level.level_index,
              price: level.price.to_s,
              expected_side: level.expected_side,
              status: level.status,
              cycle_count: level.cycle_count,
            }
          end
        end
      end
    end
  end
end
