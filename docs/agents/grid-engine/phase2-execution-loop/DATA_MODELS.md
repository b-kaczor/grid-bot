# Phase 2: The Execution Loop — DATA MODELS

## Overview

Phase 1's schema covers most of Phase 2's needs. Two new columns are required: one on `bots` and one on `orders`. No new tables are needed.

---

## Schema Changes

### 1. Add `quantity_per_level` to `bots`

**Rationale:** The OrderFillWorker needs to know the per-level buy quantity when placing counter-orders after a sell fills. Rather than recalculating (which is fragile — the original price and investment may yield different results at a later time), store the value once during initialization. This is the **only** source for buy counter-order quantities — no fallback logic.

#### Migration

```ruby
# db/migrate/YYYYMMDDHHMMSS_add_quantity_per_level_to_bots.rb
class AddQuantityPerLevelToBots < ActiveRecord::Migration[7.1]
  def change
    add_column :bots, :quantity_per_level, :decimal, precision: 20, scale: 8
  end
end
```

#### Model Change

```ruby
# app/models/bot.rb — add to existing model:
# No new validations needed — quantity_per_level is nil for pending bots
# and set during initialization.
```

#### Frontend TypeScript Type Update

```typescript
interface Bot {
  // ... existing fields ...
  quantityPerLevel: string | null;  // NEW — set during initialization
}
```

---

### 2. Add `paired_order_id` to `orders`

**Rationale:** When a buy fills at level N, the counter-sell is placed at level N+1. When that sell later fills, we need to find the originating buy to record the trade. Without a direct link, we'd have to search for "the most recent filled buy on some other grid level" — which is fragile and can return wrong results if multiple cycles overlap. `paired_order_id` creates an explicit link from counter-order back to the order that triggered it.

#### Migration

```ruby
# db/migrate/YYYYMMDDHHMMSS_add_paired_order_id_to_orders.rb
class AddPairedOrderIdToOrders < ActiveRecord::Migration[7.1]
  def change
    add_reference :orders, :paired_order, null: true, foreign_key: { to_table: :orders }
  end
end
```

#### Model Change

```ruby
# app/models/order.rb — add to existing model:
belongs_to :paired_order, class_name: "Order", optional: true
```

**Usage:**
- When `handle_buy_fill` creates a sell counter-order, it sets `paired_order_id` to the buy order's ID.
- When `handle_sell_fill` creates a buy counter-order, it sets `paired_order_id` to the sell order's ID.
- `record_trade` uses `sell_order.paired_order_id` to find the originating buy directly.
- Initial orders placed by `Grid::Initializer` have `paired_order_id: nil` (no triggering order).

#### Frontend TypeScript Type Update

```typescript
interface Order {
  // ... existing fields ...
  pairedOrderId: number | null;  // NEW — links counter-order to its trigger
}
```

---

## No New Tables or Migrations Beyond the Above

The Phase 1 schema already provides everything needed:

| Phase 2 Component | Tables Used | Notes |
|---|---|---|
| Grid::Initializer | `bots`, `grid_levels`, `orders` | Creates grid_levels and orders during init |
| OrderFillWorker | `orders`, `grid_levels`, `trades` | Updates on fill, creates counter-orders and trades |
| GridReconciliationWorker | `orders`, `grid_levels` | Reads to detect gaps, writes to repair |
| BalanceSnapshotWorker | `balance_snapshots`, `orders`, `trades` | Creates snapshots, reads orders/trades for calculations |

---

## Index Adequacy Check

Existing indexes are sufficient for Phase 2 query patterns:

| Query Pattern | Index Used |
|---|---|
| Find order by `exchange_order_id` | `orders.exchange_order_id` |
| Find order by `order_link_id` | `orders.order_link_id` (unique) |
| Find active orders for a bot | `orders.[bot_id, status]` |
| Find active order for a grid_level | `orders.[grid_level_id, status]` |
| Find grid_level by bot + index | `grid_levels.[bot_id, level_index]` (unique) |
| Sum trades profit for a bot | `trades.[bot_id, completed_at]` |
| Find paired order for trade recording | `orders.paired_order_id` (added by `add_reference` migration) |
| Find running bots | No index on `bots.status` — acceptable for small table (< 100 rows). Add if needed later. |
