# frozen_string_literal: true

module Grid
  class TrailingManager # rubocop:disable Metrics/ClassLength
    class TrailError < StandardError; end

    def initialize(bot, filled_level:, client:)
      @bot = bot
      @filled_level = filled_level
      @client = client
    end

    # Returns true if trailing was performed, false if not applicable
    def maybe_trail!
      return false unless should_trail?

      trail_up!
      true
    end

    private

    def should_trail?
      @bot.trailing_up_enabled &&
        @bot.status == 'running' &&
        @filled_level.level_index == max_level_index
    end

    def max_level_index
      @max_level_index ||= @bot.grid_levels.maximum(:level_index)
    end

    def trail_up!
      lowest_level = @bot.grid_levels.order(:level_index).first
      validate_lowest_level!(lowest_level)
      cancel_lowest_buy!(lowest_level)

      new_top_price = round_to_tick(@bot.upper_price + grid_step)
      new_sell_response = place_new_top_sell(new_top_price)
      raise TrailError, 'Failed to place trailing sell: exchange rejected' unless new_sell_response

      persist_trail!(lowest_level, new_top_price, new_sell_response)
      finalize_trail!
    end

    def finalize_trail!
      Grid::RedisState.new.seed(@bot.reload)
      Rails.logger.info(
        "[Trailing] Bot #{@bot.id} trailed up. " \
        "New range: #{@bot.lower_price}..#{@bot.upper_price}"
      )
    end

    def persist_trail!(lowest_level, new_top_price, new_sell_response)
      ActiveRecord::Base.transaction do
        lowest_level.orders.where(status: 'open').update_all(status: 'cancelled') # rubocop:disable Rails/SkipsModelValidations
        lowest_level.destroy!
        reindex_levels!
        create_new_top_level!(new_top_price, new_sell_response)
        update_bot_boundaries!(new_top_price)
      end
    end

    def reindex_levels!
      @bot.grid_levels.reload
      conn = ActiveRecord::Base.connection

      conn.execute(<<~SQL.squish)
        UPDATE grid_levels
        SET level_index = -(level_index)
        WHERE bot_id = #{conn.quote(@bot.id)}
      SQL

      conn.execute(<<~SQL.squish)
        UPDATE grid_levels
        SET level_index = (-level_index) - 1
        WHERE bot_id = #{conn.quote(@bot.id)}
      SQL
    end

    def create_new_top_level!(new_top_price, response)
      new_level_index = @bot.grid_levels.reload.maximum(:level_index) + 1
      new_level = create_grid_level!(new_top_price, new_level_index, response)
      create_order!(new_level, new_top_price, response)
    end

    def create_grid_level!(price, level_index, response)
      GridLevel.create!(
        bot: @bot, level_index:, price:,
        expected_side: 'sell', status: 'active',
        current_order_id: response[:order_id],
        current_order_link_id: response[:link_id]
      )
    end

    def create_order!(grid_level, price, response)
      Order.create!(
        bot: @bot, grid_level:,
        exchange_order_id: response[:order_id],
        order_link_id: response[:link_id],
        side: 'sell', price:,
        quantity: @bot.quantity_per_level,
        status: 'open', placed_at: Time.current
      )
    end

    def update_bot_boundaries!(new_top_price)
      new_lower = @bot.grid_levels.reload.order(:level_index).first.price
      @bot.update!(lower_price: new_lower, upper_price: new_top_price)
    end

    def validate_lowest_level!(level)
      return if level.status == 'active' && level.expected_side == 'buy'

      return unless level.status == 'filled'

      raise TrailError,
            "Lowest level #{level.level_index} already filled — skip trail, process fill first"
    end

    def cancel_lowest_buy!(level)
      return unless level.current_order_id

      response = @client.cancel_order(symbol: @bot.pair, order_id: level.current_order_id)
      return if response.success?

      raise_if_already_filled!(response, level)
      Rails.logger.warn("[Trailing] Cancel failed: #{response.error_message}, proceeding anyway")
    end

    def raise_if_already_filled!(response, level)
      return unless response.error_code == '110001'

      raise TrailError,
            "Lowest buy already filled on exchange (#{level.current_order_id}) — skip trail"
    end

    def place_new_top_sell(price)
      temp_index = max_level_index + 1
      link_id = "g#{@bot.id}-L#{temp_index}-S-0"

      response = @client.place_order(
        symbol: @bot.pair, side: 'Sell', order_type: 'Limit',
        qty: @bot.quantity_per_level.to_s, price: price.to_s, order_link_id: link_id
      )

      return nil unless response.success?

      { order_id: response.data[:orderId], link_id: }
    end

    def grid_step
      if @bot.spacing_type == 'arithmetic'
        (@bot.upper_price - @bot.lower_price) / @bot.grid_count
      else
        ratio = (@bot.upper_price / @bot.lower_price)**(BigDecimal('1') / @bot.grid_count)
        @bot.upper_price * (ratio - 1)
      end
    end

    def round_to_tick(price)
      return price unless @bot.tick_size&.positive?

      (price / @bot.tick_size).floor * @bot.tick_size
    end
  end
end
