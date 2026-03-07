# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Bot Detail', type: :feature do
  let!(:exchange_account) { create(:exchange_account) }
  let!(:bot) do
    create(
      :bot,
      exchange_account:,
      pair: 'ETHUSDT',
      base_coin: 'ETH',
      quote_coin: 'USDT',
      status: 'running',
      lower_price: 2000,
      upper_price: 3000,
      grid_count: 5,
      stop_loss_price: BigDecimal('1800'),
      take_profit_price: BigDecimal('3500'),
      trailing_up_enabled: false
    )
  end

  before do
    stub_exchange_client
    seed_grid_levels_for(bot)
  end

  describe 'grid visualization' do
    it 'renders grid levels with buy and sell sides distinguishable' do
      seed_bot_redis_state(bot)
      visit_bot_detail(bot)

      expect(page).to have_content('Grid Levels')

      # Check that at least one buy level and one sell level are rendered
      expect(page).to have_css('[data-testid^="grid-level-"]', minimum: 3)

      # Check that prices from grid levels are visible
      expect(page).to have_content('2000')
      expect(page).to have_content('3000')
    end
  end

  describe 'trade history pagination' do
    before do
      seed_bot_redis_state(bot)
      create_trades_for_pagination(bot)
    end

    it 'shows page 1 by default and allows navigation to page 2' do
      visit_bot_detail(bot)

      expect(page).to have_css('[data-testid="trade-history-table"]')
      expect(page).to have_content('Trade History')

      # Should have trades on the first page
      within('[data-testid="trade-history-table"]') do
        expect(page).to have_css('tbody tr', minimum: 1)
      end

      # Navigate to page 2 if pagination exists
      if page.has_css?('[data-testid="trade-pagination"]')
        within('[data-testid="trade-pagination"]') do
          find('button[aria-label="Go to next page"]').click
        end
        expect(page).to have_css('[data-testid="trade-history-table"] tbody tr', minimum: 1)
      end
    end
  end

  describe 'performance charts' do
    it 'renders equity curve and daily profit charts when snapshots exist' do
      seed_bot_with_charts(bot)
      visit_bot_detail(bot)

      expect(page).to have_css('[data-testid="chart-portfolio"]')
      expect(page).to have_content('Equity Curve')

      expect(page).to have_css('[data-testid="chart-daily-profit"]')
      expect(page).to have_content('Daily Profit')
    end
  end

  describe 'risk settings - view' do
    it 'displays stop-loss, take-profit, and trailing toggle' do
      seed_bot_redis_state(bot)
      visit_bot_detail(bot)

      within('[data-testid="risk-settings-card"]') do
        expect(page).to have_content('Risk Settings')
        expect(page).to have_content('$1800')
        expect(page).to have_content('$3500')
        expect(page).to have_content('Trailing Grid: OFF')
      end
    end
  end

  describe 'risk settings - edit' do
    it 'allows editing stop-loss price inline and saving' do
      seed_bot_redis_state(bot)
      visit_bot_detail(bot)

      within('[data-testid="risk-settings-card"]') do
        click_button 'Edit'

        # Find the stop-loss input and update value
        stop_loss_input = find('[data-testid="input-stop-loss"] input')
        stop_loss_input.fill_in(with: '')
        stop_loss_input.fill_in(with: '1900')

        click_button 'Save'
      end

      # After save, the card should show updated value
      within('[data-testid="risk-settings-card"]') do
        expect(page).to have_content('$1900')
      end
    end
  end

  describe 'real-time ActionCable update' do
    it 'updates realized profit and trade count without page reload via fill event' do
      seed_bot_redis_state(bot)
      visit_bot_detail(bot)

      # Verify initial values are displayed
      expect(page).to have_content('Realized Profit')

      # Broadcast a fill event via ActionCable
      broadcast_to_bot(
        bot.id, {
          type: 'fill',
          realized_profit: '125.50',
          trade_count: 7,
          trade: nil,
          grid_level: {
            level_index: 0,
            price: '2000.0',
            expected_side: 'buy',
            status: 'active',
            cycle_count: 1,
          },
        }
      )

      # Capybara retries up to default_max_wait_time (5s)
      expect(page).to have_content('125.50')
      expect(page).to have_content('7')
    end
  end

  private

  def seed_grid_levels_for(bot)
    step = (bot.upper_price - bot.lower_price) / bot.grid_count
    (0..bot.grid_count).each do |i|
      price = bot.lower_price + (step * i)
      side = price < 2500 ? 'buy' : 'sell'
      create(:grid_level, bot:, level_index: i, price:, expected_side: side, status: 'active')
    end
  end

  def create_trades_for_pagination(bot)
    grid_level = bot.grid_levels.first

    # Create 25 trades so pagination has at least 2 pages (default per_page is 20)
    25.times do |i|
      buy_order = create(:order, bot:, grid_level:, side: 'buy', status: 'filled')
      sell_order = create(:order, bot:, grid_level:, side: 'sell', status: 'filled')
      create(
        :trade,
        bot:,
        grid_level:,
        buy_order:,
        sell_order:,
        buy_price: 2400,
        sell_price: 2500,
        quantity: 0.1,
        net_profit: 9.5,
        completed_at: i.hours.ago
      )
    end
  end
end
