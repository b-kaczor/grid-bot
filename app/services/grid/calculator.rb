# frozen_string_literal: true

require 'bigdecimal'
require 'bigdecimal/math'

module Grid
  class Calculator
    NEUTRAL_ZONE_THRESHOLD = BigDecimal('0.001')

    class ValidationError < StandardError; end

    attr_reader :lower, :upper, :count, :spacing, :tick_size, :base_precision,
                :min_order_amt, :min_order_qty, :max_order_qty

    def initialize(lower:, upper:, count:, spacing: :arithmetic,
                   tick_size: nil, base_precision: nil,
                   min_order_amt: nil, min_order_qty: nil, max_order_qty: nil
    )
      @lower = BigDecimal(lower.to_s)
      @upper = BigDecimal(upper.to_s)
      @count = count
      @spacing = spacing.to_sym
      @tick_size = tick_size ? BigDecimal(tick_size.to_s) : nil
      @base_precision = base_precision
      @min_order_amt = min_order_amt ? BigDecimal(min_order_amt.to_s) : nil
      @min_order_qty = min_order_qty ? BigDecimal(min_order_qty.to_s) : nil
      @max_order_qty = max_order_qty ? BigDecimal(max_order_qty.to_s) : nil
    end

    def levels
      @levels ||= compute_levels
    end

    def classify_levels(current_price:)
      price = BigDecimal(current_price.to_s)

      levels.each_with_index.with_object({}) do |(level, index), result|
        distance = (level - price).abs / price
        result[index] = if distance < NEUTRAL_ZONE_THRESHOLD
                          :skip
                        elsif level < price
                          :buy
                        else
                          :sell
                        end
      end
    end

    def quantity_per_level(investment:, current_price:)
      inv = BigDecimal(investment.to_s)
      price = BigDecimal(current_price.to_s)
      classification = classify_levels(current_price: price)

      buy_count = classification.count { |_, side| side == :buy }
      raise ValidationError, 'No buy levels found' if buy_count.zero?

      qty = inv / buy_count / price
      base_precision ? qty.truncate(base_precision) : qty
    end

    def validate!(investment: nil, current_price: nil)
      raise ValidationError, 'investment and current_price are required' unless investment && current_price

      qty = quantity_per_level(investment:, current_price:)
      validate_qty_limits!(qty)
      validate_notional!(qty)
      true
    end

    private

    def validate_qty_limits!(qty)
      if min_order_qty && qty < min_order_qty
        raise ValidationError,
              "Quantity per level #{qty} is below minimum order quantity #{min_order_qty}"
      end

      return unless max_order_qty && qty > max_order_qty

      raise ValidationError,
            "Quantity per level #{qty} exceeds maximum order quantity #{max_order_qty}"
    end

    def validate_notional!(qty)
      return unless min_order_amt

      levels.each do |level|
        notional = qty * level
        next unless notional < min_order_amt

        raise ValidationError,
              "Notional #{notional} at price #{level} is below minimum order amount #{min_order_amt}"
      end
    end

    def compute_levels
      raw = case spacing
            when :arithmetic then compute_arithmetic
            when :geometric  then compute_geometric
            else raise ArgumentError, "Unknown spacing type: #{spacing}"
            end

      raw.map { |price| round_and_clamp(price) }
    end

    def compute_arithmetic
      step = (upper - lower) / count
      (0..count).map { |i| lower + (i * step) }
    end

    def compute_geometric
      ratio = (upper / lower)**(BigDecimal('1') / count)
      (0..count).map { |i| lower * (ratio**i) }
    end

    def round_and_clamp(price)
      rounded = if tick_size
                  (price / tick_size).round * tick_size
                else
                  price
                end

      [[rounded, lower].max, upper].min
    end
  end
end
