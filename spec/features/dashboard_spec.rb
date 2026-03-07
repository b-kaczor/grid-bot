# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Dashboard', type: :feature do
  let!(:exchange_account) { create(:exchange_account) }

  before do
    stub_exchange_client
  end

  describe 'bot card display' do
    let!(:bot) { create_running_bot(exchange_account:) }

    it 'shows the bot card with pair, status, profit, and range visualizer' do
      visit_dashboard

      within("[data-testid='bot-card-#{bot.id}']") do
        expect(page).to have_content('ETHUSDT')
        expect(page).to have_content('running')
        expect(page).to have_css('[data-testid="status-badge"]')
        expect(page).to have_css('[data-testid="range-visualizer"]')
        expect(page).to have_content('Profit')
      end
    end
  end

  describe 'navigate to detail' do
    let!(:bot) { create_running_bot(exchange_account:) }

    it 'clicking a bot card navigates to the Bot Detail page' do
      visit_dashboard

      find("[data-testid='bot-card-#{bot.id}']").click

      expect(page).to have_current_path("/bots/#{bot.id}")
      expect(page).to have_content('ETHUSDT')
      expect(page).to have_content('Realized Profit')
    end
  end

  describe 'empty state' do
    it 'shows an empty state prompt when no bots exist' do
      visit_dashboard

      expect(page).to have_content('No bots yet')
      expect(page).to have_content('Create your first grid trading bot')
      expect(page).to have_content(/create bot/i)
    end
  end
end
