# Phase 1: Foundation — DATA MODELS

## Overview

Six core tables supporting the grid trading bot. All tables use standard Rails auto-incrementing primary keys. Decimal columns use `precision: 20, scale: 8` for prices/quantities (supports values up to 999,999,999,999.99999999) and `scale: 10` for fees (higher precision). All financial math uses `BigDecimal` in Ruby.

---

## Entity Relationship Diagram

```
ExchangeAccount 1---* Bot
Bot 1---* GridLevel
Bot 1---* Order
Bot 1---* Trade
Bot 1---* BalanceSnapshot
GridLevel 1---* Order
Trade *---1 Order (buy_order)
Trade *---1 Order (sell_order)
GridLevel 1---* Trade
```

---

## 1. ExchangeAccount

Stores encrypted API credentials. Multiple accounts per exchange are supported (e.g., sub-accounts, different strategies).

### Migration

```ruby
# db/migrate/YYYYMMDDHHMMSS_create_exchange_accounts.rb
class CreateExchangeAccounts < ActiveRecord::Migration[7.1]
  def change
    create_table :exchange_accounts do |t|
      t.string :name, null: false
      t.string :exchange, null: false, default: "bybit"
      t.text :api_key_ciphertext, null: false
      t.text :api_secret_ciphertext, null: false
      t.string :environment, null: false, default: "testnet"
      t.timestamps
    end

    add_index :exchange_accounts, [:exchange, :environment, :name], unique: true
  end
end
```

### Model

```ruby
# app/models/exchange_account.rb
class ExchangeAccount < ApplicationRecord
  has_many :bots, dependent: :restrict_with_error

  encrypts :api_key, :api_secret  # Lockbox

  validates :name, presence: true
  validates :exchange, presence: true, inclusion: { in: %w[bybit] }
  validates :environment, presence: true, inclusion: { in: %w[testnet mainnet] }
  validates :api_key, presence: true
  validates :api_secret, presence: true
  validates :name, uniqueness: { scope: [:exchange, :environment] }
end
```

### Notes
- `api_key` and `api_secret` are virtual attributes backed by Lockbox-encrypted `*_ciphertext` columns.
- Unique constraint on `[exchange, environment, name]` allows multiple accounts per exchange (sub-accounts, different strategies) while preventing exact duplicates.
- `dependent: :restrict_with_error` prevents deleting an account that has bots.

---

## 2. Bot

Core configuration for a grid trading bot instance.

### Migration

```ruby
# db/migrate/YYYYMMDDHHMMSS_create_bots.rb
class CreateBots < ActiveRecord::Migration[7.1]
  def change
    create_table :bots do |t|
      t.references :exchange_account, null: false, foreign_key: true

      # Trading pair
      t.string :pair, null: false
      t.string :base_coin, null: false
      t.string :quote_coin, null: false

      # Grid configuration
      t.decimal :lower_price, precision: 20, scale: 8, null: false
      t.decimal :upper_price, precision: 20, scale: 8, null: false
      t.integer :grid_count, null: false
      t.string :spacing_type, null: false, default: "arithmetic"
      t.decimal :investment_amount, precision: 20, scale: 8, null: false

      # Instrument constraints (fetched from exchange on init)
      t.decimal :tick_size, precision: 20, scale: 12
      t.decimal :min_order_amt, precision: 20, scale: 8
      t.decimal :min_order_qty, precision: 20, scale: 8
      t.integer :base_precision
      t.integer :quote_precision

      # Lifecycle
      t.string :status, null: false, default: "pending"
      t.string :stop_reason

      # Risk management
      t.decimal :stop_loss_price, precision: 20, scale: 8
      t.decimal :take_profit_price, precision: 20, scale: 8
      t.boolean :trailing_up_enabled, null: false, default: false

      t.timestamps
    end
  end
end
```

### Model

```ruby
# app/models/bot.rb
class Bot < ApplicationRecord
  belongs_to :exchange_account
  has_many :grid_levels, dependent: :destroy
  has_many :orders, dependent: :destroy
  has_many :trades, dependent: :destroy
  has_many :balance_snapshots, dependent: :destroy

  STATUSES = %w[pending initializing running paused stopped error].freeze
  STOP_REASONS = %w[user stop_loss take_profit error maintenance].freeze
  SPACING_TYPES = %w[arithmetic geometric].freeze

  validates :pair, presence: true
  validates :base_coin, presence: true
  validates :quote_coin, presence: true
  validates :lower_price, presence: true, numericality: { greater_than: 0 }
  validates :upper_price, presence: true, numericality: { greater_than: 0 }
  validates :grid_count, presence: true, numericality: { greater_than_or_equal_to: 2, only_integer: true }
  validates :investment_amount, presence: true, numericality: { greater_than: 0 }
  validates :spacing_type, presence: true, inclusion: { in: SPACING_TYPES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :stop_reason, inclusion: { in: STOP_REASONS }, allow_nil: true
  validate :upper_price_greater_than_lower

  scope :running, -> { where(status: "running") }
  scope :active, -> { where(status: %w[running paused initializing]) }

  private

  def upper_price_greater_than_lower
    return unless upper_price && lower_price
    errors.add(:upper_price, "must be greater than lower price") unless upper_price > lower_price
  end
end
```

### Notes
- `base_precision` and `quote_precision` are stored as integers (number of decimal places). Bybit returns `basePrecision` as a string like `"0.000001"` — convert on ingestion by counting decimal places (e.g., `"0.000001"` -> `6`).
- Instrument constraints (`tick_size`, `min_order_amt`, `min_order_qty`, precisions) are populated during bot initialization (Phase 2) from `get_instruments_info`.

### Status transitions

```
pending -> initializing -> running -> paused -> running  (resume)
                                   -> stopped            (user stop, SL, TP)
                                   -> error              (unrecoverable)
              any state  -> error                        (crash)
```

---

## 3. GridLevel

One record per price level in a bot's grid. Tracks what order should be at this level and its current state.

### Migration

```ruby
# db/migrate/YYYYMMDDHHMMSS_create_grid_levels.rb
class CreateGridLevels < ActiveRecord::Migration[7.1]
  def change
    create_table :grid_levels do |t|
      t.references :bot, null: false, foreign_key: true
      t.integer :level_index, null: false
      t.decimal :price, precision: 20, scale: 8, null: false
      t.string :expected_side, null: false
      t.string :status, null: false, default: "pending"
      t.string :current_order_id
      t.string :current_order_link_id
      t.integer :cycle_count, null: false, default: 0
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end

    add_index :grid_levels, [:bot_id, :level_index], unique: true
  end
end
```

### Model

```ruby
# app/models/grid_level.rb
class GridLevel < ApplicationRecord
  belongs_to :bot
  has_many :orders, dependent: :destroy
  has_many :trades, dependent: :destroy

  SIDES = %w[buy sell].freeze
  STATUSES = %w[pending active filled skipped].freeze

  validates :level_index, presence: true,
            numericality: { greater_than_or_equal_to: 0, only_integer: true },
            uniqueness: { scope: :bot_id }
  validates :price, presence: true, numericality: { greater_than: 0 }
  validates :expected_side, presence: true, inclusion: { in: SIDES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :cycle_count, numericality: { greater_than_or_equal_to: 0 }

  # Optimistic locking is automatic via lock_version column
end
```

### Notes
- `lock_version` enables Rails optimistic locking. When two workers try to update the same level, the second gets `ActiveRecord::StaleObjectError` and retries.
- `expected_side` tracks what the NEXT order at this level should be (flips on each fill).
- `current_order_id` is the Bybit `orderId`; `current_order_link_id` is our client-generated ID.
- `skipped` status is used for levels in the neutral zone during initialization.
- `filled` status means the current order at this level was filled and a counter-order needs to be placed. The reconciliation worker (Phase 2) must treat `filled` levels as "needs counter-order" and place the appropriate order if one is missing.

---

## 4. Order

One record per order placed on the exchange.

### Migration

```ruby
# db/migrate/YYYYMMDDHHMMSS_create_orders.rb
class CreateOrders < ActiveRecord::Migration[7.1]
  def change
    create_table :orders do |t|
      t.references :bot, null: false, foreign_key: true
      t.references :grid_level, null: false, foreign_key: true
      t.string :exchange_order_id
      t.string :order_link_id, null: false
      t.string :side, null: false
      t.decimal :price, precision: 20, scale: 8, null: false
      t.decimal :quantity, precision: 20, scale: 8, null: false
      t.decimal :filled_quantity, precision: 20, scale: 8, default: 0
      t.decimal :net_quantity, precision: 20, scale: 8
      t.decimal :avg_fill_price, precision: 20, scale: 8
      t.decimal :fee, precision: 20, scale: 10, default: 0
      t.string :fee_coin
      t.string :status, null: false, default: "pending"
      t.datetime :placed_at
      t.datetime :filled_at
      t.timestamps
    end

    add_index :orders, :order_link_id, unique: true
    add_index :orders, :exchange_order_id
    add_index :orders, [:grid_level_id, :status]
    add_index :orders, [:bot_id, :status]
  end
end
```

### Model

```ruby
# app/models/order.rb
class Order < ApplicationRecord
  belongs_to :bot
  belongs_to :grid_level

  SIDES = %w[buy sell].freeze
  STATUSES = %w[pending open partially_filled filled cancelled rejected].freeze

  validates :order_link_id, presence: true, uniqueness: true
  validates :side, presence: true, inclusion: { in: SIDES }
  validates :price, presence: true, numericality: { greater_than: 0 }
  validates :quantity, presence: true, numericality: { greater_than: 0 }
  validates :status, presence: true, inclusion: { in: STATUSES }

  scope :active, -> { where(status: %w[open partially_filled]) }
  scope :filled, -> { where(status: "filled") }
  scope :buys, -> { where(side: "buy") }
  scope :sells, -> { where(side: "sell") }

  # Fee-adjusted quantity: what was actually received
  def effective_quantity
    net_quantity || filled_quantity
  end
end
```

### Order Link ID Format

`g{bot_id}L{level_index}{B|S}{cycle_count}`

Examples:
- `g12L25B3` — bot 12, level 25, buy, 3rd cycle
- `g1L0S0` — bot 1, level 0, sell, 0th cycle

Max 36 characters (Bybit limit). With reasonable bot_id and level_index values, this stays well under the limit.

---

## 5. Trade

A completed buy+sell cycle at a grid level. Created when a sell order fills and its paired buy order is already filled.

### Migration

```ruby
# db/migrate/YYYYMMDDHHMMSS_create_trades.rb
class CreateTrades < ActiveRecord::Migration[7.1]
  def change
    create_table :trades do |t|
      t.references :bot, null: false, foreign_key: true
      t.references :grid_level, null: false, foreign_key: true
      t.references :buy_order, null: false, foreign_key: { to_table: :orders }
      t.references :sell_order, null: false, foreign_key: { to_table: :orders }
      t.decimal :buy_price, precision: 20, scale: 8, null: false
      t.decimal :sell_price, precision: 20, scale: 8, null: false
      t.decimal :quantity, precision: 20, scale: 8, null: false
      t.decimal :gross_profit, precision: 20, scale: 10, null: false
      t.decimal :total_fees, precision: 20, scale: 10, null: false
      t.decimal :net_profit, precision: 20, scale: 10, null: false
      t.datetime :completed_at, null: false
      t.timestamps
    end

    add_index :trades, [:bot_id, :completed_at]
  end
end
```

### Model

```ruby
# app/models/trade.rb
class Trade < ApplicationRecord
  belongs_to :bot
  belongs_to :grid_level
  belongs_to :buy_order, class_name: "Order"
  belongs_to :sell_order, class_name: "Order"

  validates :buy_price, presence: true, numericality: { greater_than: 0 }
  validates :sell_price, presence: true, numericality: { greater_than: 0 }
  validates :quantity, presence: true, numericality: { greater_than: 0 }
  validates :gross_profit, presence: true
  validates :total_fees, presence: true
  validates :net_profit, presence: true
  validates :completed_at, presence: true

  scope :profitable, -> { where("net_profit > 0") }
  scope :recent, -> { order(completed_at: :desc) }
end
```

### Profit calculation

```
quantity     = sell_order.effective_quantity
gross_profit = (sell_price - buy_price) * quantity
total_fees   = buy_order.fee_in_quote + sell_order.fee_in_quote
net_profit   = gross_profit - total_fees
```

Fee normalization to quote currency:
- If `fee_coin` == quote coin (e.g., USDT): `fee_in_quote = fee`
- If `fee_coin` == base coin (e.g., ETH): `fee_in_quote = fee * fill_price`

---

## 6. BalanceSnapshot

Periodic portfolio value snapshots for charting and analytics.

### Migration

```ruby
# db/migrate/YYYYMMDDHHMMSS_create_balance_snapshots.rb
class CreateBalanceSnapshots < ActiveRecord::Migration[7.1]
  def change
    create_table :balance_snapshots do |t|
      t.references :bot, null: false, foreign_key: true
      t.decimal :base_balance, precision: 20, scale: 8
      t.decimal :quote_balance, precision: 20, scale: 8
      t.decimal :total_value_quote, precision: 20, scale: 8
      t.decimal :current_price, precision: 20, scale: 8
      t.decimal :realized_profit, precision: 20, scale: 8
      t.decimal :unrealized_pnl, precision: 20, scale: 8
      t.string :granularity, null: false, default: "fine"
      t.datetime :snapshot_at, null: false
      t.timestamps
    end

    add_index :balance_snapshots, [:bot_id, :snapshot_at]
    add_index :balance_snapshots, [:bot_id, :granularity, :snapshot_at]
  end
end
```

### Model

```ruby
# app/models/balance_snapshot.rb
class BalanceSnapshot < ApplicationRecord
  belongs_to :bot

  GRANULARITIES = %w[fine hourly daily].freeze

  validates :granularity, presence: true, inclusion: { in: GRANULARITIES }
  validates :snapshot_at, presence: true

  scope :fine, -> { where(granularity: "fine") }
  scope :hourly, -> { where(granularity: "hourly") }
  scope :daily, -> { where(granularity: "daily") }
  scope :for_period, ->(from, to) { where(snapshot_at: from..to) }
end
```

### Retention policy

Executed by `SnapshotRetentionJob` (Sidekiq-cron, daily at 03:00 UTC):

| Age | Granularity kept | Action |
|-----|-----------------|--------|
| 0-7 days | `fine` (every 5 min) | No action |
| 7-30 days | `hourly` | Delete `fine` rows; keep one per hour (closest to :00) |
| 30+ days | `daily` | Delete `hourly` rows; keep one per day (last snapshot of day) |

---

## Frontend TypeScript Types

These types will be used by the React frontend when API endpoints are built in Phase 3.

```typescript
// frontends/app/src/types/models.ts

type BotStatus = "pending" | "initializing" | "running" | "paused" | "stopped" | "error";
type StopReason = "user" | "stop_loss" | "take_profit" | "error" | "maintenance";
type SpacingType = "arithmetic" | "geometric";
type OrderSide = "buy" | "sell";
type OrderStatus = "pending" | "open" | "partially_filled" | "filled" | "cancelled" | "rejected";
type GridLevelStatus = "pending" | "active" | "filled" | "skipped";
type Granularity = "fine" | "hourly" | "daily";

interface Bot {
  id: number;
  exchangeAccountId: number;
  pair: string;
  baseCoin: string;
  quoteCoin: string;
  lowerPrice: string;  // decimal as string
  upperPrice: string;
  gridCount: number;
  spacingType: SpacingType;
  investmentAmount: string;
  status: BotStatus;
  stopReason: StopReason | null;
  stopLossPrice: string | null;
  takeProfitPrice: string | null;
  trailingUpEnabled: boolean;
  createdAt: string;   // ISO 8601
  updatedAt: string;
}

interface GridLevel {
  id: number;
  botId: number;
  levelIndex: number;
  price: string;
  expectedSide: OrderSide;
  status: GridLevelStatus;
  currentOrderId: string | null;
  cycleCount: number;
}

interface Order {
  id: number;
  botId: number;
  gridLevelId: number;
  exchangeOrderId: string | null;
  orderLinkId: string;
  side: OrderSide;
  price: string;
  quantity: string;
  filledQuantity: string;
  netQuantity: string | null;
  avgFillPrice: string | null;
  fee: string;
  feeCoin: string | null;
  status: OrderStatus;
  placedAt: string | null;
  filledAt: string | null;
}

interface Trade {
  id: number;
  botId: number;
  gridLevelId: number;
  buyOrderId: number;
  sellOrderId: number;
  buyPrice: string;
  sellPrice: string;
  quantity: string;
  grossProfit: string;
  totalFees: string;
  netProfit: string;
  completedAt: string;
}

interface BalanceSnapshot {
  id: number;
  botId: number;
  baseBalance: string;
  quoteBalance: string;
  totalValueQuote: string;
  currentPrice: string;
  realizedProfit: string;
  unrealizedPnl: string;
  granularity: Granularity;
  snapshotAt: string;
}
```

---

## Index Summary

| Table | Index | Type | Purpose |
|-------|-------|------|---------|
| exchange_accounts | `[exchange, environment, name]` | unique | Prevent duplicate accounts |
| grid_levels | `[bot_id, level_index]` | unique | One level per index per bot |
| orders | `order_link_id` | unique | Idempotency / dedup |
| orders | `exchange_order_id` | non-unique | Lookup by Bybit order ID |
| orders | `[grid_level_id, status]` | non-unique | Find active order per level |
| orders | `[bot_id, status]` | non-unique | Find all orders for a bot by status |
| trades | `[bot_id, completed_at]` | non-unique | Chronological trade history |
| balance_snapshots | `[bot_id, snapshot_at]` | non-unique | Time-series queries |
| balance_snapshots | `[bot_id, granularity, snapshot_at]` | non-unique | Retention policy queries |
