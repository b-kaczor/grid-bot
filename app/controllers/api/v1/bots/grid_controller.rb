# frozen_string_literal: true

module Api
  module V1
    module Bots
      class GridController < BaseController
        def show
          bot = Bot.kept.find_by!(id: params[:bot_id])
          redis = Grid::RedisState.new
          levels = load_levels(bot, redis)
          current_price = redis.read_price(bot.id)

          render json: {
            grid: {
              current_price: current_price || fallback_price(bot),
              levels:,
            },
          }
        end

        private

        def fallback_price(bot)
          bot.balance_snapshots.order(snapshot_at: :desc).first&.current_price&.to_s
        end

        def load_levels(bot, redis)
          redis_levels = redis.read_levels(bot.id)

          if redis_levels.any?
            levels_from_redis(redis_levels)
          else
            levels_from_db(bot)
          end
        end

        def levels_from_redis(redis_levels)
          redis_levels.sort_by { |idx, _| idx.to_i }.map do |index, data|
            {
              level_index: index.to_i,
              price: data['price'],
              expected_side: data['side'],
              status: data['status'],
              cycle_count: data['cycle_count'].to_i,
            }
          end
        end

        def levels_from_db(bot)
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
