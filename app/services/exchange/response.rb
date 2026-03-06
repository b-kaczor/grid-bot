# frozen_string_literal: true

module Exchange
  Response = Struct.new(:success, :data, :error_code, :error_message, keyword_init: true) do
    def success? = success
  end
end
