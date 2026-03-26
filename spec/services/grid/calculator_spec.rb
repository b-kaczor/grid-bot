# frozen_string_literal: true

require_relative '../../../app/services/grid/calculator'

RSpec.describe Grid::Calculator do
  describe '#levels' do
    context 'with arithmetic spacing' do
      subject(:calc) { described_class.new(lower: 2000, upper: 3000, count: 10, spacing: :arithmetic) }

      it 'generates count + 1 levels' do
        expect(calc.levels.size).to eq(11)
      end

      it 'starts at lower price' do
        expect(calc.levels.first).to eq(BigDecimal('2000'))
      end

      it 'ends at upper price' do
        expect(calc.levels.last).to eq(BigDecimal('3000'))
      end

      it 'has uniform step between levels' do
        steps = calc.levels.each_cons(2).map { |a, b| b - a }
        expect(steps).to all(eq(BigDecimal('100')))
      end

      it 'produces correct known values' do
        expected = (0..10).map { |i| BigDecimal('2000') + (i * BigDecimal('100')) }
        expect(calc.levels).to eq(expected)
      end
    end

    context 'with 50 levels (AC-003)' do
      subject(:calc) { described_class.new(lower: 2000, upper: 3000, count: 50, spacing: :arithmetic) }

      it 'returns exactly 51 price levels' do
        expect(calc.levels.size).to eq(51)
      end
    end

    context 'with geometric spacing' do
      subject(:calc) { described_class.new(lower: 2000, upper: 3000, count: 10, spacing: :geometric) }

      it 'generates count + 1 levels' do
        expect(calc.levels.size).to eq(11)
      end

      it 'starts at lower price' do
        expect(calc.levels.first).to eq(BigDecimal('2000'))
      end

      it 'ends at upper price (within rounding)' do
        expect(calc.levels.last).to be_within(BigDecimal('0.01')).of(BigDecimal('3000'))
      end

      it 'has constant ratio between consecutive levels' do
        ratios = calc.levels.each_cons(2).map { |a, b| b / a }
        ratios.each_cons(2) do |r1, r2|
          expect(r1).to be_within(BigDecimal('0.0000001')).of(r2)
        end
      end

      it 'produces levels in ascending order' do
        expect(calc.levels).to eq(calc.levels.sort)
      end
    end

    context 'with tick_size rounding' do
      subject(:calc) do
        described_class.new(lower: 2000, upper: 3000, count: 5, spacing: :arithmetic, tick_size: '0.01')
      end

      it 'rounds prices to tick_size' do
        calc.levels.each do |level|
          remainder = level % BigDecimal('0.01')
          expect(remainder).to eq(BigDecimal('0')),
                               "Level #{level} not rounded to tick_size 0.01 (remainder: #{remainder})"
        end
      end

      it 'clamps boundary levels within range' do
        calc.levels.each do |level|
          expect(level).to be >= BigDecimal('2000')
          expect(level).to be <= BigDecimal('3000')
        end
      end
    end

    context 'with tick_size that could push levels out of range' do
      subject(:calc) do
        described_class.new(lower: '100.03', upper: '200.07', count: 2, spacing: :arithmetic, tick_size: '0.1')
      end

      it 'clamps rounded levels to stay within range' do
        expect(calc.levels.first).to be >= BigDecimal('100.03')
        expect(calc.levels.last).to be <= BigDecimal('200.07')
      end
    end

    context 'edge case: count 1' do
      subject(:calc) { described_class.new(lower: 1000, upper: 2000, count: 1, spacing: :arithmetic) }

      it 'generates exactly 2 levels' do
        expect(calc.levels.size).to eq(2)
      end

      it 'produces lower and upper' do
        expect(calc.levels).to eq([BigDecimal('1000'), BigDecimal('2000')])
      end
    end

    context 'edge case: very large range' do
      subject(:calc) { described_class.new(lower: 1, upper: 100_000, count: 10, spacing: :arithmetic) }

      it 'generates levels across the full range' do
        expect(calc.levels.first).to eq(BigDecimal('1'))
        expect(calc.levels.last).to eq(BigDecimal('100000'))
        expect(calc.levels.size).to eq(11)
      end
    end

    it 'returns BigDecimal values' do
      calc = described_class.new(lower: 2000, upper: 3000, count: 5, spacing: :arithmetic)
      expect(calc.levels).to all(be_a(BigDecimal))
    end

    it 'raises for unknown spacing type' do
      calc = described_class.new(lower: 2000, upper: 3000, count: 5, spacing: :linear)
      expect { calc.levels }.to raise_error(ArgumentError, /Unknown spacing type/)
    end
  end

  describe '#classify_levels' do
    subject(:calc) { described_class.new(lower: 2000, upper: 3000, count: 10, spacing: :arithmetic) }

    it 'classifies levels below current_price as :buy' do
      result = calc.classify_levels(current_price: 2500)
      expect(result[0]).to eq(:buy) # 2000
      expect(result[1]).to eq(:buy) # 2100
      expect(result[2]).to eq(:buy) # 2200
    end

    it 'classifies levels above current_price as :sell' do
      result = calc.classify_levels(current_price: 2500)
      expect(result[6]).to eq(:sell) # 2600
      expect(result[10]).to eq(:sell) # 3000
    end

    it 'skips levels within 0.1% of current_price (neutral zone)' do
      result = calc.classify_levels(current_price: 2500)
      expect(result[5]).to eq(:skip) # 2500 exactly
    end

    it 'skips a level just inside the neutral zone boundary' do
      # 2500 * 0.001 = 2.5, so within [2497.5, 2502.5] is neutral
      result = calc.classify_levels(current_price: 2501)
      expect(result[5]).to eq(:skip) # 2500 is within 0.1% of 2501
    end

    it 'does not skip a level just outside the neutral zone' do
      # With step 100 between levels, levels are 100 apart — well outside 0.1%
      result = calc.classify_levels(current_price: 2550)
      expect(result[5]).to eq(:buy)  # 2500 is 50/2550 = ~1.96% away
      expect(result[6]).to eq(:sell) # 2600 is 50/2550 = ~1.96% away
    end

    it 'returns a hash with all level indices' do
      result = calc.classify_levels(current_price: 2500)
      expect(result.keys.sort).to eq((0..10).to_a)
    end

    context 'when current_price is below all levels' do
      it 'classifies all levels as :sell (no :skip)' do
        result = calc.classify_levels(current_price: 1000)
        expect(result.values).to all(eq(:sell))
      end
    end

    context 'when current_price is above all levels' do
      it 'classifies all levels as :buy (no :skip)' do
        result = calc.classify_levels(current_price: 5000)
        expect(result.values).to all(eq(:buy))
      end
    end
  end

  describe '#quantity_per_level' do
    subject(:calc) do
      described_class.new(
        lower: 2000, upper: 3000, count: 10, spacing: :arithmetic,
        base_precision: 6
      )
    end

    it 'returns a BigDecimal' do
      qty = calc.quantity_per_level(investment: 1000, current_price: 2500)
      expect(qty).to be_a(BigDecimal)
    end

    it 'calculates correctly: investment / active_count / current_price' do
      # At price 2500, with step 100:
      # levels 0-4 are buy (2000-2400), level 5 is skip (2500), levels 6-10 are sell (2600-3000)
      # active_count = 10 (5 buy + 5 sell)
      qty = calc.quantity_per_level(investment: 1000, current_price: 2500)
      expected = BigDecimal('1000') / 10 / BigDecimal('2500')
      expect(qty).to eq(expected.truncate(6))
    end

    it 'truncates to base_precision (not rounds)' do
      qty = calc.quantity_per_level(investment: 1000, current_price: 2500)
      expect(qty).to eq(BigDecimal('0.04').truncate(6))
    end

    it 'raises when no active levels exist' do
      # Single level at exactly the current price falls in the neutral zone
      calc = described_class.new(lower: 2500, upper: 2500, count: 1, spacing: :arithmetic, base_precision: 6)
      expect { calc.quantity_per_level(investment: 1000, current_price: 2500) }
        .to raise_error(Grid::Calculator::ValidationError, /No active levels/)
    end

    it 'budgets for both buy and sell sides' do
      # investment=10000, price=2070, lower=2050, upper=2095, count=7
      # 3 buy + 4 sell + 1 skip = 7 active
      calc = described_class.new(lower: 2050, upper: 2095, count: 7, spacing: :arithmetic, base_precision: 8)
      qty = calc.quantity_per_level(investment: 10_000, current_price: 2070)
      total_cost = 7 * qty * BigDecimal('2070')
      expect(total_cost).to be <= BigDecimal('10000')
    end

    context 'without base_precision' do
      subject(:calc) do
        described_class.new(lower: 2000, upper: 3000, count: 10, spacing: :arithmetic)
      end

      it 'returns untruncated quantity' do
        qty = calc.quantity_per_level(investment: 1000, current_price: 2500)
        expect(qty).to eq(BigDecimal('1000') / 10 / BigDecimal('2500'))
      end
    end
  end

  describe '#validate!' do
    context 'when all constraints are met' do
      subject(:calc) do
        described_class.new(
          lower: 2000, upper: 3000, count: 5, spacing: :arithmetic,
          tick_size: '0.01', base_precision: 6,
          min_order_qty: '0.0001', min_order_amt: '1'
        )
      end

      it 'returns true' do
        expect(calc.validate!(investment: 1000, current_price: 2500)).to be true
      end
    end

    context 'when quantity is below min_order_qty' do
      subject(:calc) do
        described_class.new(
          lower: 2000, upper: 3000, count: 5, spacing: :arithmetic,
          base_precision: 6, min_order_qty: '100'
        )
      end

      it 'raises ValidationError' do
        expect { calc.validate!(investment: 1000, current_price: 2500) }
          .to raise_error(Grid::Calculator::ValidationError, /below minimum order quantity/)
      end
    end

    context 'when notional is below min_order_amt' do
      subject(:calc) do
        described_class.new(
          lower: 2000, upper: 3000, count: 5, spacing: :arithmetic,
          base_precision: 6, min_order_amt: '1000000'
        )
      end

      it 'raises ValidationError' do
        expect { calc.validate!(investment: 1000, current_price: 2500) }
          .to raise_error(Grid::Calculator::ValidationError, /below minimum order amount/)
      end
    end

    context 'when missing required arguments' do
      subject(:calc) { described_class.new(lower: 2000, upper: 3000, count: 5) }

      it 'raises when investment is nil' do
        expect { calc.validate!(investment: nil, current_price: 2500) }
          .to raise_error(Grid::Calculator::ValidationError, /required/)
      end

      it 'raises when current_price is nil' do
        expect { calc.validate!(investment: 1000, current_price: nil) }
          .to raise_error(Grid::Calculator::ValidationError, /required/)
      end
    end
  end

  describe 'BigDecimal consistency' do
    it 'never returns Float values from levels' do
      calc = described_class.new(lower: '1999.99', upper: '3000.01', count: 7, spacing: :geometric)
      calc.levels.each do |level|
        expect(level).to be_a(BigDecimal), "Expected BigDecimal but got #{level.class}"
      end
    end
  end
end
