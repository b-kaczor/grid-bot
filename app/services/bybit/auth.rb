# frozen_string_literal: true

require 'openssl'

module Bybit
  class Auth
    RECV_WINDOW = '5000'

    def initialize(api_key:, api_secret:)
      @api_key = api_key
      @api_secret = api_secret
    end

    def sign_request(timestamp:, params_string: '')
      payload = "#{timestamp}#{@api_key}#{RECV_WINDOW}#{params_string}"
      signature = OpenSSL::HMAC.hexdigest('SHA256', @api_secret, payload)

      {
        'X-BAPI-API-KEY' => @api_key,
        'X-BAPI-TIMESTAMP' => timestamp.to_s,
        'X-BAPI-SIGN' => signature,
        'X-BAPI-RECV-WINDOW' => RECV_WINDOW,
      }
    end
  end
end
