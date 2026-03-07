# frozen_string_literal: true

module Api
  module V1
    module Exchange
      class BalancesController < BaseController
        def show
          account = default_exchange_account
          return unless account

          client = Bybit::RestClient.new(exchange_account: account)
          response = client.get_wallet_balance

          unless response.success?
            render json: { error: response.error_message }, status: :bad_gateway
            return
          end

          render json: { balance: { coins: extract_coins(response.data) } }
        end

        private

        def extract_coins(data)
          accounts = data[:list] || []
          accounts.flat_map do |account|
            (account[:coin] || []).map do |coin|
              {
                coin: coin[:coin],
                available: coin[:availableToWithdraw],
                locked: coin[:locked],
                total: coin[:walletBalance],
              }
            end
          end
        end
      end
    end
  end
end
