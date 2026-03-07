# frozen_string_literal: true

module Exchange
  Response = Struct.new(:success, :data, :error_code, :error_message) do
    def success? = success
  end
end
