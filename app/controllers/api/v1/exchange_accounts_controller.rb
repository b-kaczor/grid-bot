# frozen_string_literal: true

module Api
  module V1
    class ExchangeAccountsController < BaseController
      def show
        account = ExchangeAccount.first
        if account
          render json: { account: account_json(account) }
        else
          render json: { setup_required: true }, status: :not_found
        end
      end

      def create
        if ExchangeAccount.exists?
          render json: { error: 'Account already exists. Use PATCH to update.' }, status: :unprocessable_content
          return
        end

        account = ExchangeAccount.create!(account_params)
        render json: { account: account_json(account) }, status: :created
      end

      def update
        account = ExchangeAccount.first!
        update_attrs = account_params.to_h.compact_blank
        account.update!(update_attrs)
        render json: { account: account_json(account) }
      end

      def test
        response = test_connection
        if response.success?
          usdt = extract_usdt_balance(response.data)
          render json: { success: true, balance: "#{usdt} USDT" }
        else
          render json: { success: false, error: response.error_message }
        end
      rescue Bybit::AuthenticationError => e
        render json: { success: false, error: e.message }
      rescue Bybit::NetworkError => e
        render json: { success: false, error: "Connection failed: #{e.message}" }
      end

      private

      def test_connection
        client = Bybit::RestClient.new(
          api_key: params[:api_key],
          api_secret: params[:api_secret],
          environment: params[:environment] || 'testnet'
        )
        client.get_wallet_balance
      end

      def account_params
        params.require(:exchange_account).permit(:name, :exchange, :environment, :api_key, :api_secret)
      end

      def account_json(account)
        {
          id: account.id,
          name: account.name,
          exchange: account.exchange,
          environment: account.environment,
          api_key_hint: mask_key(account.api_key),
          created_at: account.created_at,
          updated_at: account.updated_at,
        }
      end

      def mask_key(key)
        return nil if key.blank?

        "#{'*' * 8}#{key[-4..]}"
      end

      def extract_usdt_balance(data)
        coins = data.dig(:list, 0, :coin) || []
        usdt_coin = coins.find { |c| c[:coin] == 'USDT' }
        usdt_coin ? BigDecimal(usdt_coin[:walletBalance]).to_s('F') : '0.00'
      end
    end
  end
end
