# frozen_string_literal: true

module Api
  module V1
    class BotsController < BaseController
      include BotSerialization

      before_action :set_bot, only: %i[show update destroy]

      def index
        bots = Bot.kept.order(created_at: :desc)
        redis = Grid::RedisState.new
        render json: { bots: bots.map { |bot| bot_summary(bot, redis) } }
      end

      def show
        redis = Grid::RedisState.new
        recent_trades = @bot.trades.includes(:grid_level)
          .order(completed_at: :desc).limit(10)
        render json: { bot: bot_detail(@bot, redis, recent_trades) }
      end

      def create
        account = default_exchange_account
        return unless account

        bot = Bot.new(bot_params.merge(exchange_account: account))
        bot.save!
        BotInitializerJob.perform_async(bot.id)
        render json: { bot: bot_response(bot) }, status: :created
      end

      def update
        if params.dig(:bot, :status)
          handle_status_change
          return if performed?
        end

        @bot.update!(risk_params) if risk_params.present?

        render json: { bot: bot_detail(@bot, Grid::RedisState.new, recent_trades_for(@bot)) }
      end

      def destroy
        stop_if_active!
        @bot.discard!
        render json: { bot: bot_response(@bot) }
      end

      private

      def set_bot
        @bot = Bot.find_by!(id: params[:id])
      end

      def bot_params
        params.require(:bot).permit(
          :pair, :base_coin, :quote_coin, :lower_price, :upper_price,
          :grid_count, :spacing_type, :investment_amount,
          :stop_loss_price, :take_profit_price, :trailing_up_enabled
        )
      end

      def risk_params
        params.require(:bot).permit(
          :stop_loss_price, :take_profit_price, :trailing_up_enabled
        )
      end

      def handle_status_change
        new_status = params.dig(:bot, :status)
        case new_status
        when 'paused'
          @bot.update!(status: 'paused')
        when 'running'
          @bot.update!(status: 'running')
        when 'stopped'
          Grid::Stopper.new(@bot).call
          @bot.reload
        else
          render json: { error: "Invalid status transition: #{new_status}" }, status: :bad_request
        end
      end

      def stop_if_active!
        return unless %w[running paused stopping].include?(@bot.status)

        Grid::Stopper.new(@bot).call
        @bot.reload
      end

      def recent_trades_for(bot)
        bot.trades.includes(:grid_level).order(completed_at: :desc).limit(10)
      end
    end
  end
end
