# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BalanceSnapshotWorker do
  subject(:worker) { described_class.new }

  let(:exchange_account) { create(:exchange_account) }
  let(:bot) do
    create(
      :bot,
      exchange_account:,
      status: 'running',
      pair: 'ETHUSDT',
      base_coin: 'ETH',
      quote_coin: 'USDT',
      investment_amount: BigDecimal('1000')
    )
  end
  let(:client) { instance_double(Bybit::RestClient) }
  let(:redis_state) { instance_double(Grid::RedisState) }

  let(:ticker_response) do
    Exchange::Response.new(
      success: true,
      data: { list: [{ lastPrice: '2500.0' }] }
    )
  end

  before do
    allow(Bybit::RestClient).to receive(:new).and_return(client)
    allow(client).to receive(:get_tickers).and_return(ticker_response)
    allow(Grid::RedisState).to receive(:new).and_return(redis_state)
    allow(redis_state).to receive(:update_price)
    allow(ActionCable.server).to receive(:broadcast)
  end

  describe '#perform' do
    context 'with a running bot and filled orders' do
      let(:buy_level) { create(:grid_level, bot:, level_index: 0, price: 2400) }
      let(:sell_level) { create(:grid_level, bot:, level_index: 1, price: 2600) }

      let!(:filled_buy) do
        create(
          :order,
          bot:, grid_level: buy_level, side: 'buy', price: 2400,
          quantity: BigDecimal('0.2'), status: 'filled',
          filled_quantity: BigDecimal('0.2'), net_quantity: BigDecimal('0.1998'),
          avg_fill_price: BigDecimal('2400'), fee: BigDecimal('0.0002'),
          fee_coin: 'ETH', filled_at: 1.hour.ago
        )
      end

      let!(:filled_sell) do
        create(
          :order,
          bot:, grid_level: sell_level, side: 'sell', price: 2600,
          quantity: BigDecimal('0.1'), status: 'filled',
          filled_quantity: BigDecimal('0.1'), net_quantity: BigDecimal('0.1'),
          avg_fill_price: BigDecimal('2600'), fee: BigDecimal('0.26'),
          fee_coin: 'USDT', filled_at: 30.minutes.ago
        )
      end

      it 'creates a balance snapshot' do
        expect { worker.perform }.to change(BalanceSnapshot, :count).by(1)
      end

      it 'calculates base_held as bought minus sold net_quantity' do
        worker.perform
        snapshot = BalanceSnapshot.last
        # 0.1998 bought - 0.1 sold = 0.0998
        expect(snapshot.base_balance).to eq(BigDecimal('0.0998'))
      end

      it 'calculates quote_balance from investment, buy cost, sell revenue, and fees' do
        worker.perform
        snapshot = BalanceSnapshot.last
        # investment: 1000
        # buy cost: 2400 * 0.2 = 480
        # sell revenue: 2600 * 0.1 = 260
        # quote fees: sell fee 0.26 (buy fee is in ETH, not quote)
        # = 1000 - 480 + 260 - 0.26 = 779.74
        expect(snapshot.quote_balance).to eq(BigDecimal('779.74'))
      end

      it 'calculates total_value as quote_balance + base_held * current_price' do
        worker.perform
        snapshot = BalanceSnapshot.last
        # quote_balance: 779.74
        # base_held * price: 0.0998 * 2500 = 249.5
        # total: 1029.24
        expect(snapshot.total_value_quote).to eq(BigDecimal('1029.24'))
      end

      it 'sets current_price from ticker' do
        worker.perform
        expect(BalanceSnapshot.last.current_price).to eq(BigDecimal('2500'))
      end

      it 'sets granularity to fine' do
        worker.perform
        expect(BalanceSnapshot.last.granularity).to eq('fine')
      end

      it 'updates Redis price' do
        worker.perform
        expect(redis_state).to have_received(:update_price).with(bot.id, BigDecimal('2500'))
      end

      it 'broadcasts price_update via ActionCable' do
        worker.perform
        expect(ActionCable.server).to have_received(:broadcast).with(
          "bot_#{bot.id}",
          hash_including(
            type: 'price_update',
            current_price: '2500.0',
            unrealized_pnl: anything,
            total_value_quote: anything
          )
        )
      end
    end

    context 'with realized profit from trades' do
      let(:level) { create(:grid_level, bot:, level_index: 0) }
      let(:buy_order) { create(:order, bot:, grid_level: level, side: 'buy', status: 'filled') }
      let(:sell_order) { create(:order, bot:, grid_level: level, side: 'sell', status: 'filled') }

      before do
        create(
          :trade,
          bot:, grid_level: level, buy_order:, sell_order:,
          net_profit: BigDecimal('9.5')
        )
        create(
          :trade,
          bot:, grid_level: level,
          buy_order: create(:order, bot:, grid_level: level, side: 'buy', status: 'filled'),
          sell_order: create(:order, bot:, grid_level: level, side: 'sell', status: 'filled'),
          net_profit: BigDecimal('5.5')
        )
      end

      it 'sums realized_profit from trades' do
        worker.perform
        expect(BalanceSnapshot.last.realized_profit).to eq(BigDecimal('15'))
      end
    end

    context 'with unrealized PnL' do
      let(:buy_level) { create(:grid_level, bot:, level_index: 0, price: 2400) }
      let(:sell_level) { create(:grid_level, bot:, level_index: 1, price: 2600) }

      let!(:active_buy) do
        create(
          :order,
          bot:, grid_level: buy_level, side: 'buy', price: 2400,
          quantity: BigDecimal('0.1'), status: 'filled',
          filled_quantity: BigDecimal('0.1'), net_quantity: BigDecimal('0.1'),
          avg_fill_price: BigDecimal('2400'), fee: BigDecimal('0.24'),
          fee_coin: 'USDT', filled_at: 1.hour.ago
        )
      end

      it 'calculates unrealized_pnl based on avg buy price of unpaired buys' do
        # No trades exist, so active_buy is unpaired
        # avg_buy_price = 2400 * 0.1 / 0.1 = 2400
        # unrealized = (2500 - 2400) * 0.1 = 10
        worker.perform
        expect(BalanceSnapshot.last.unrealized_pnl).to eq(BigDecimal('10'))
      end

      it 'sets unrealized_pnl to 0 when no active buys exist' do
        # Pair the buy with a trade so it's not active
        sell_order = create(
          :order,
          bot:, grid_level: sell_level, side: 'sell', status: 'filled',
          filled_quantity: BigDecimal('0.1'), net_quantity: BigDecimal('0.1'),
          avg_fill_price: BigDecimal('2600')
        )
        create(:trade, bot:, grid_level: buy_level, buy_order: active_buy, sell_order:)

        worker.perform
        expect(BalanceSnapshot.last.unrealized_pnl).to eq(BigDecimal('0'))
      end
    end

    context 'with no running bots' do
      before { bot.update!(status: 'stopped') }

      it 'does not create any snapshots' do
        expect { worker.perform }.not_to change(BalanceSnapshot, :count)
      end
    end

    context 'with no filled orders' do
      before { bot }

      it 'creates a snapshot with zero balances' do
        worker.perform
        snapshot = BalanceSnapshot.last
        expect(snapshot.base_balance).to eq(BigDecimal('0'))
        expect(snapshot.quote_balance).to eq(BigDecimal('1000'))
        expect(snapshot.total_value_quote).to eq(BigDecimal('1000'))
        expect(snapshot.realized_profit).to eq(BigDecimal('0'))
        expect(snapshot.unrealized_pnl).to eq(BigDecimal('0'))
      end
    end

    context 'when ticker fetch fails' do
      before do
        bot
        allow(client).to receive(:get_tickers).and_return(
          Exchange::Response.new(success: false, error_code: 'TIMEOUT', error_message: 'timeout')
        )
      end

      it 'skips the bot without creating a snapshot' do
        expect { worker.perform }.not_to change(BalanceSnapshot, :count)
      end
    end

    context 'with risk check' do
      let(:risk_manager) { instance_double(Grid::RiskManager) }

      before do
        bot
        allow(Grid::RiskManager).to receive(:new).and_return(risk_manager)
      end

      it 'skips snapshot when risk manager triggers stop' do
        allow(risk_manager).to receive(:check!).and_return(:stop_loss)
        expect { worker.perform }.not_to change(BalanceSnapshot, :count)
      end

      it 'creates snapshot when risk manager returns nil' do
        allow(risk_manager).to receive(:check!).and_return(nil)
        expect { worker.perform }.to change(BalanceSnapshot, :count).by(1)
      end

      it 'creates snapshot when risk check raises (non-fatal)' do
        allow(risk_manager).to receive(:check!).and_raise(StandardError, 'boom')
        allow(Rails.logger).to receive(:error)
        expect { worker.perform }.to change(BalanceSnapshot, :count).by(1)
        expect(Rails.logger).to have_received(:error).with(/Risk check failed/)
      end
    end

    context 'with DCP health check' do
      let(:redis) { instance_double(Redis) }

      before do
        bot
        allow(Redis).to receive(:new).and_return(redis)
      end

      it 'logs warning when DCP confirmation is stale (>60s)' do
        allow(redis).to receive(:get).with('grid:dcp:registered_at').and_return('1000')
        allow(redis).to receive(:get).with('grid:dcp:last_confirmed').and_return('1000')
        allow(Time).to receive(:current).and_return(Time.zone.at(1100))
        allow(Rails.logger).to receive(:warn)
        worker.perform
        expect(Rails.logger).to have_received(:warn).with(/No DCP confirmation/)
      end

      it 'does not warn when DCP was never registered' do
        allow(redis).to receive(:get).with('grid:dcp:registered_at').and_return(nil)
        allow(Rails.logger).to receive(:warn)
        worker.perform
        expect(Rails.logger).not_to have_received(:warn).with(/DCP/)
      end
    end

    context 'with per-bot error isolation' do
      let(:bot2) { create(:bot, exchange_account:, status: 'running') }

      before do
        bot
        bot2
        call_count = 0
        allow(client).to receive(:get_tickers) do
          call_count += 1
          raise 'Exchange API error' if call_count == 1

          ticker_response
        end
      end

      it 'continues processing remaining bots when one fails' do
        expect { worker.perform }.to change(BalanceSnapshot, :count).by(1)
      end

      it 'logs the error for the failing bot' do
        allow(Rails.logger).to receive(:error)
        worker.perform
        expect(Rails.logger).to have_received(:error).with(/\[Snapshot\] Failed for bot/)
      end
    end
  end
end
