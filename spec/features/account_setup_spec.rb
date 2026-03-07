# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Account Setup & Settings', type: :feature do
  before do
    stub_exchange_client
  end

  describe 'Setup Page (no account exists)' do
    it 'redirects to /setup when no account exists' do
      visit '/bots'

      expect(page).to have_current_path('/setup')
      expect(page).to have_content('Account Setup')
    end

    it 'shows setup form with correct fields and defaults' do
      visit '/setup'

      expect(page).to have_css('[data-testid="setup-name"]')
      expect(page).to have_css('[data-testid="setup-environment"]')
      expect(page).to have_css('[data-testid="setup-api-key"]')
      expect(page).to have_css('[data-testid="setup-api-secret"]')
      expect(page).to have_css('[data-testid="setup-test-btn"]')
      expect(page).to have_css('[data-testid="setup-save-btn"]')

      # Default name
      name_input = find('[data-testid="setup-name"] input')
      expect(name_input.value).to eq('My Demo Account')

      # Default environment is demo
      env_input = find('[data-testid="setup-environment"] input', visible: :all)
      expect(env_input.value).to eq('demo')
    end

    it 'disables save button until test passes' do
      visit '/setup'

      save_btn = find('[data-testid="setup-save-btn"]')
      expect(save_btn).to be_disabled

      # Fill in credentials
      find('[data-testid="setup-api-key"] input').fill_in(with: 'test_key_1234')
      find('[data-testid="setup-api-secret"] input').fill_in(with: 'test_secret_5678')

      # Save should still be disabled before test
      expect(save_btn).to be_disabled

      # Run test connection
      click_button 'Test Connection'

      # Wait for success result
      expect(page).to have_css('[data-testid="setup-test-result"]')
      expect(page).to have_content('Connection successful')

      # Now save should be enabled
      save_btn = find('[data-testid="setup-save-btn"]')
      expect(save_btn).not_to be_disabled
    end

    it 'shows error when test connection fails' do
      Features::FakeBybitClient.force_failure = true

      visit '/setup'

      find('[data-testid="setup-api-key"] input').fill_in(with: 'bad_key')
      find('[data-testid="setup-api-secret"] input').fill_in(with: 'bad_secret')

      click_button 'Test Connection'

      expect(page).to have_css('[data-testid="setup-test-result"]')
      expect(page).to have_content('Connection failed')

      # Save should remain disabled
      save_btn = find('[data-testid="setup-save-btn"]')
      expect(save_btn).to be_disabled
    ensure
      Features::FakeBybitClient.force_failure = false
    end

    it 'creates account and redirects to dashboard after setup' do
      visit '/setup'

      # Fill the form
      name_input = find('[data-testid="setup-name"] input')
      name_input.fill_in(with: '')
      name_input.fill_in(with: 'My Test Account')

      find('[data-testid="setup-api-key"] input').fill_in(with: 'live_key_abcd')
      find('[data-testid="setup-api-secret"] input').fill_in(with: 'live_secret_efgh')

      # Test connection first
      click_button 'Test Connection'
      expect(page).to have_content('Connection successful')

      # Save
      click_button 'Save'

      # Should redirect to dashboard
      expect(page).to have_current_path('/bots')
      expect(page).to have_content('No bots yet')

      # Verify account was persisted
      account = ExchangeAccount.first
      expect(account.name).to eq('My Test Account')
      expect(account.exchange).to eq('bybit')
      expect(account.environment).to eq('demo')
    end
  end

  describe 'Settings Page (account exists)' do
    let!(:exchange_account) do
      create(:exchange_account, name: 'Demo Account', environment: 'demo', api_key: 'key_ending_ab3f')
    end

    it 'shows account info in view mode with masked key' do
      visit '/settings'

      within('[data-testid="settings-card"]') do
        expect(page).to have_content('Demo Account')
        expect(page).to have_content('bybit')
        expect(page).to have_content('demo')
        expect(page).to have_content('********ab3f')
        expect(page).to have_css('[data-testid="settings-edit-btn"]')
      end
    end

    it 'enters edit mode and cancel returns to view mode' do
      visit '/settings'

      within('[data-testid="settings-card"]') do
        click_button 'Edit'

        # Should show edit form fields
        expect(page).to have_css('[data-testid="settings-name"]')
        expect(page).to have_css('[data-testid="settings-environment"]')
        expect(page).to have_css('[data-testid="settings-api-key"]')
        expect(page).to have_css('[data-testid="settings-api-secret"]')
        expect(page).to have_css('[data-testid="settings-cancel-btn"]')

        click_button 'Cancel'

        # Should return to view mode
        expect(page).to have_content('Demo Account')
        expect(page).to have_css('[data-testid="settings-edit-btn"]')
        expect(page).to have_no_css('[data-testid="settings-name"]')
      end
    end

    it 'can update name without re-entering credentials' do
      visit '/settings'

      within('[data-testid="settings-card"]') do
        click_button 'Edit'

        # Update only the name
        name_input = find('[data-testid="settings-name"] input')
        name_input.fill_in(with: '')
        name_input.fill_in(with: 'Updated Account')

        # Leave API key and secret blank — should not need test
        # Save should be enabled since no new keys entered
        click_button 'Save'
      end

      # Should show success and updated name
      expect(page).to have_content('Account updated successfully')
      expect(page).to have_content('Updated Account')

      # Verify in DB
      expect(exchange_account.reload.name).to eq('Updated Account')
      # Credentials should be unchanged
      expect(exchange_account.api_key).to eq('key_ending_ab3f')
    end

    it 'navigates to settings via the nav icon' do
      visit '/bots'

      find('[data-testid="nav-settings"]').click

      expect(page).to have_current_path('/settings')
      expect(page).to have_content('Settings')
    end
  end
end
