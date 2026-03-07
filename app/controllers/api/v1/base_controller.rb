# frozen_string_literal: true

module Api
  module V1
    class BaseController < ApplicationController
      rescue_from ActiveRecord::RecordNotFound, with: :not_found
      rescue_from ActiveRecord::RecordInvalid, with: :unprocessable
      rescue_from ActionController::ParameterMissing, with: :bad_request

      private

      def not_found(exception)
        render json: { error: exception.message }, status: :not_found
      end

      def unprocessable(exception)
        render json: { error: exception.record.errors.full_messages }, status: :unprocessable_content
      end

      def bad_request(exception)
        render json: { error: exception.message }, status: :bad_request
      end

      def default_exchange_account
        @default_exchange_account ||= ExchangeAccount.first ||
          raise_setup_error('No exchange account configured. Create one in rails console first.')
      end

      def raise_setup_error(message)
        render json: { error: message, setup_required: true }, status: :service_unavailable
        nil
      end

      def paginate(scope, default_per: 20, max_per: 100)
        page = [params.fetch(:page, 1).to_i, 1].max
        per = [params.fetch(:per_page, default_per).to_i, max_per].min
        records = scope.offset((page - 1) * per).limit(per)
        total = scope.count
        { records:, page:, per_page: per, total:, total_pages: (total.to_f / per).ceil }
      end
    end
  end
end
