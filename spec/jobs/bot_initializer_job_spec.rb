# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BotInitializerJob, type: :job do
  let(:exchange_account) { create(:exchange_account) }
  let(:bot) { create(:bot, exchange_account:, status: 'pending') }
  let(:initializer) { instance_double(Grid::Initializer) }

  before do
    allow(Grid::Initializer).to receive(:new).and_return(initializer)
    allow(initializer).to receive(:call).and_return(bot)
  end

  describe '#perform' do
    it 'finds the bot and calls Grid::Initializer' do
      described_class.new.perform(bot.id)
      expect(Grid::Initializer).to have_received(:new).with(bot)
      expect(initializer).to have_received(:call)
    end

    it 'raises ActiveRecord::RecordNotFound for missing bot' do
      expect { described_class.new.perform(-1) }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe 'sidekiq options' do
    it 'uses the critical queue' do
      expect(described_class.sidekiq_options['queue'].to_s).to eq('critical')
    end

    it 'does not retry' do
      expect(described_class.sidekiq_options['retry']).to eq(0)
    end
  end
end
