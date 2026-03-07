# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Create Bot Wizard', type: :feature do
  let!(:exchange_account) { create(:exchange_account) }

  before do
    stub_exchange_client
    allow(BotInitializerJob).to receive(:perform_async)
    allow(BalanceSnapshotWorker).to receive(:perform_async)
  end

  describe 'step 1 - pair selection' do
    it 'shows the pair dropdown and allows selecting ETHUSDT' do
      visit_create_bot

      expect(page).to have_css('[data-testid="wizard-step-0"]')
      expect(page).to have_content('Select Pair')

      # Open the autocomplete and select ETHUSDT
      find('[data-testid="pair-select"] input').fill_in(with: 'ETH')
      expect(page).to have_content('ETHUSDT')
      find('li', text: 'ETHUSDT').click

      # Next button should be enabled
      click_button 'Next'
      expect(page).to have_css('[data-testid="wizard-step-1"]')
    end
  end

  describe 'step 2 - parameter entry with validation' do
    before do
      visit_create_bot
      select_pair('ETHUSDT')
      click_button 'Next'
    end

    it 'shows validation errors for out-of-range values and allows valid values' do
      expect(page).to have_css('[data-testid="wizard-step-1"]')
      expect(page).to have_content('Set Parameters')

      # Clear the defaults and enter invalid lower price (above current price 2500)
      lower_input = find('[data-testid="input-lower-price"] input')
      lower_input.fill_in(with: '')
      lower_input.fill_in(with: '3000')

      # Should show validation error
      expect(page).to have_content('Must be below current price')

      # Fix with valid value
      lower_input.fill_in(with: '')
      lower_input.fill_in(with: '2000')

      upper_input = find('[data-testid="input-upper-price"] input')
      upper_input.fill_in(with: '')
      upper_input.fill_in(with: '3000')

      expect(page).to have_content('Profit per grid')

      click_button 'Next'
      expect(page).to have_css('[data-testid="wizard-step-2"]')
    end
  end

  describe 'step 3 - summary' do
    before do
      visit_create_bot
      select_pair('ETHUSDT')
      click_button 'Next'
      fill_valid_parameters
      click_button 'Next'
    end

    it 'shows investment slider and order summary' do
      expect(page).to have_css('[data-testid="wizard-step-2"]')
      expect(page).to have_content('Investment')
      expect(page).to have_content('Order Summary')
      expect(page).to have_content('ETHUSDT')
      expect(page).to have_content('Create Bot')
    end
  end

  describe 'full happy path' do
    it 'completes all steps and redirects to Bot Detail' do
      visit_create_bot

      # Step 1: Select pair
      select_pair('ETHUSDT')
      click_button 'Next'

      # Step 2: Enter parameters
      fill_valid_parameters
      click_button 'Next'

      # Step 3: Confirm
      expect(page).to have_content('Order Summary')
      click_button 'Create Bot'

      # Should redirect to Bot Detail page
      expect(page).to have_current_path(%r{/bots/\d+})
      expect(page).to have_content('ETHUSDT')
    end
  end

  private

  def select_pair(symbol)
    find('[data-testid="pair-select"] input').fill_in(with: symbol[0..2])
    find('li', text: symbol).click
  end

  def fill_valid_parameters
    lower_input = find('[data-testid="input-lower-price"] input')
    lower_input.fill_in(with: '')
    lower_input.fill_in(with: '2000')

    upper_input = find('[data-testid="input-upper-price"] input')
    upper_input.fill_in(with: '')
    upper_input.fill_in(with: '3000')
  end
end
