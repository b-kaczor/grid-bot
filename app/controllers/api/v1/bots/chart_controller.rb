# frozen_string_literal: true

module Api
  module V1
    module Bots
      class ChartController < BaseController
        def show
          bot = Bot.kept.find_by!(id: params[:bot_id])
          range = parse_time_range
          granularity = determine_granularity(range)

          snapshots = bot.balance_snapshots
            .where(granularity:)
            .for_period(range.first, range.last)
            .order(:snapshot_at)

          render json: {
            snapshots: snapshots.map { |s| snapshot_response(s) },
            granularity:,
          }
        end

        private

        def parse_time_range
          from = params[:from] ? Time.zone.parse(params[:from]) : 24.hours.ago
          to = params[:to] ? Time.zone.parse(params[:to]) : Time.current
          [from, to]
        end

        def determine_granularity(range)
          span = range.last - range.first

          if span > 30.days
            'daily'
          elsif span > 7.days
            'hourly'
          else
            'fine'
          end
        end

        def snapshot_response(snapshot)
          {
            snapshot_at: snapshot.snapshot_at.iso8601,
            total_value_quote: snapshot.total_value_quote.to_s,
            realized_profit: snapshot.realized_profit.to_s,
            unrealized_pnl: snapshot.unrealized_pnl.to_s,
            current_price: snapshot.current_price.to_s,
          }
        end
      end
    end
  end
end
