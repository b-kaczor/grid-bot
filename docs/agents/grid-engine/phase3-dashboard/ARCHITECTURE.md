# Phase 3: The Dashboard — Architecture

**Area:** grid-engine
**Work Item:** phase3-dashboard

---

## 1. Backend Architecture

### 1.1 Controller Structure

All controllers inherit from `Api::V1::BaseController`, which provides error handling, pagination helpers, and the standard JSON response envelope.

```
app/controllers/
  api/
    v1/
      base_controller.rb
      bots_controller.rb        # CRUD + lifecycle actions
      bots/
        trades_controller.rb    # GET /bots/:bot_id/trades
        chart_controller.rb     # GET /bots/:bot_id/chart
        grid_controller.rb      # GET /bots/:bot_id/grid
      exchange/
        pairs_controller.rb     # GET /exchange/pairs
        balance_controller.rb   # GET /exchange/balance
```

**`Api::V1::BaseController`**

```ruby
module Api
  module V1
    class BaseController < ApplicationController
      rescue_from ActiveRecord::RecordNotFound, with: :not_found
      rescue_from ActiveRecord::RecordInvalid, with: :unprocessable
      rescue_from ActionController::ParameterMissing, with: :bad_request

      private

      def not_found(exception)
        render json: { error: exception.message }, status: :not_found
      end

      def unprocessable(exception)
        render json: { error: exception.record.errors.full_messages }, status: :unprocessable_entity
      end

      def bad_request(exception)
        render json: { error: exception.message }, status: :bad_request
      end

      def default_exchange_account
        @default_exchange_account ||= ExchangeAccount.first ||
          raise_setup_error('No exchange account configured. Create one in rails console first.')
      end

      def raise_setup_error(message)
        render json: { error: message, setup_required: true }, status: :service_unavailable
        nil
      end

      def paginate(scope, default_per: 20, max_per: 100)
        page = [params.fetch(:page, 1).to_i, 1].max
        per = [params.fetch(:per_page, default_per).to_i, max_per].min
        records = scope.offset((page - 1) * per).limit(per)
        total = scope.count
        { records:, page:, per_page: per, total:, total_pages: (total.to_f / per).ceil }
      end
    end
  end
end
```

Note: This is a single-user app (no auth). `default_exchange_account` returns the sole `ExchangeAccount` record. If none exists, it returns a 503 with `setup_required: true` and a helpful message, rather than a generic 404. The frontend can check for this and show a setup prompt.

### 1.2 Routes

```ruby
# config/routes.rb
Rails.application.routes.draw do
  get 'up' => 'rails/health#show', as: :rails_health_check

  namespace :api do
    namespace :v1 do
      resources :bots, only: [:index, :show, :create, :update, :destroy] do
        resource :grid, only: [:show], controller: 'bots/grid'
        resources :trades, only: [:index], controller: 'bots/trades'
        resource :chart, only: [:show], controller: 'bots/chart'
      end

      namespace :exchange do
        resource :pairs, only: [:show]
        resource :balance, only: [:show]
      end
    end
  end

  mount ActionCable.server => '/cable'
end
```

### 1.3 API Endpoints — Request/Response Contracts

All responses use a consistent envelope. Financial values are always strings (formatted BigDecimal).

#### POST /api/v1/bots

Creates a bot and enqueues `Grid::Initializer` via a Sidekiq job.

**Request:**
```json
{
  "bot": {
    "pair": "ETHUSDT",
    "base_coin": "ETH",
    "quote_coin": "USDT",
    "lower_price": "2000.00",
    "upper_price": "3000.00",
    "grid_count": 50,
    "spacing_type": "arithmetic",
    "investment_amount": "1000.00"
  }
}
```

**Response (201 Created):**

The response returns `status: "pending"` because the bot record is created synchronously but initialization happens asynchronously in `BotInitializerJob`. The status transitions: `pending` -> `initializing` (job starts) -> `running` (success) or `error` (failure). The frontend should subscribe to ActionCable immediately after create to receive the status transition events.

```json
{
  "bot": {
    "id": 1,
    "pair": "ETHUSDT",
    "status": "pending",
    "lower_price": "2000.00",
    "upper_price": "3000.00",
    "grid_count": 50,
    "spacing_type": "arithmetic",
    "investment_amount": "1000.00",
    "created_at": "2026-03-07T12:00:00Z"
  }
}
```

**Controller logic:**
1. Merge `exchange_account: default_exchange_account` into permitted params (the frontend does not send this — the backend assigns the sole exchange account automatically)
2. Create `Bot` record with `status: 'pending'`
3. Enqueue `BotInitializerJob.perform_async(bot.id)`
4. Return bot immediately (client polls or subscribes to ActionCable for status change)

**New job needed:** `app/jobs/bot_initializer_job.rb` — thin wrapper that calls `Grid::Initializer.new(bot).call`. This decouples the HTTP request from the blocking initialization process.

```ruby
class BotInitializerJob
  include Sidekiq::Worker
  sidekiq_options queue: :critical, retry: 1

  def perform(bot_id)
    bot = Bot.find(bot_id)
    Grid::Initializer.new(bot).call
  end
end
```

#### GET /api/v1/bots

**Response (200):**
```json
{
  "bots": [
    {
      "id": 1,
      "pair": "ETHUSDT",
      "base_coin": "ETH",
      "quote_coin": "USDT",
      "status": "running",
      "lower_price": "2000.00",
      "upper_price": "3000.00",
      "grid_count": 50,
      "spacing_type": "arithmetic",
      "investment_amount": "1000.00",
      "current_price": "2543.50",
      "realized_profit": "42.18",
      "trade_count": 15,
      "active_levels": 48,
      "uptime_seconds": 86400,
      "created_at": "2026-03-07T12:00:00Z"
    }
  ]
}
```

**Data source:** `Bot.kept` (excludes soft-deleted bots). Live stats (`current_price`, `realized_profit`, `trade_count`, `uptime_seconds`) come from Redis via `Grid::RedisState`. `active_levels` is a count from the Redis levels hash. DB is only queried for bot config.

#### GET /api/v1/bots/:id

**Response (200):**
```json
{
  "bot": {
    "id": 1,
    "pair": "ETHUSDT",
    "base_coin": "ETH",
    "quote_coin": "USDT",
    "status": "running",
    "lower_price": "2000.00",
    "upper_price": "3000.00",
    "grid_count": 50,
    "spacing_type": "arithmetic",
    "investment_amount": "1000.00",
    "tick_size": "0.01",
    "base_precision": 6,
    "quote_precision": 2,
    "current_price": "2543.50",
    "realized_profit": "42.18",
    "unrealized_pnl": "12.50",
    "trade_count": 15,
    "active_levels": 48,
    "uptime_seconds": 86400,
    "created_at": "2026-03-07T12:00:00Z",
    "recent_trades": [
      {
        "id": 42,
        "level_index": 12,
        "buy_price": "2240.00",
        "sell_price": "2260.00",
        "quantity": "0.044200",
        "net_profit": "0.82",
        "total_fees": "0.06",
        "completed_at": "2026-03-07T14:30:00Z"
      }
    ]
  }
}
```

**Data sources:**
- Bot config: PostgreSQL
- `current_price`, `realized_profit`, `trade_count`, `uptime_seconds`: Redis
- `unrealized_pnl`: latest `BalanceSnapshot` record
- `recent_trades`: PostgreSQL `trades` table, `LIMIT 10 ORDER BY completed_at DESC`, with `.includes(:grid_level)` to avoid N+1

**Note on grid_levels:** The show endpoint does NOT include `grid_levels`. Grid level data is served exclusively by the dedicated `GET /bots/:id/grid` endpoint. This avoids duplicating the same data across two endpoints and keeps the show response focused on summary + recent trades. The frontend fetches grid data separately via `useBotGrid(id)`.

#### PATCH /api/v1/bots/:id

**Request (stop bot):**
```json
{
  "bot": { "status": "stopped" }
}
```

**Allowed transitions:**
- `running` -> `paused` (pause)
- `paused` -> `running` (resume — re-run reconciliation)
- `running` -> `stopping` -> `stopped` (stop — cancel all orders)
- `paused` -> `stopping` -> `stopped` (stop)

**Race condition prevention:** The `stopping` intermediate status prevents `OrderFillWorker` from placing new counter-orders while `Grid::Stopper` is cancelling exchange orders. Without it, a fill processed between "cancel all" and "update DB" would place an orphaned order on the exchange.

**Controller logic for stop:**
1. Set `bot.status = 'stopping'` and broadcast status change (blocks OrderFillWorker)
2. Call `client.cancel_all_orders(symbol: bot.pair)`
3. Update all active grid_levels to `status: 'filled'`, all open orders to `status: 'cancelled'`
4. Set `bot.status = 'stopped'`, `bot.stop_reason = 'user'`
5. Clean up Redis state: `Grid::RedisState.new.cleanup(bot.id)`
6. Broadcast final status change via ActionCable

This logic lives in a new service: `Grid::Stopper`.

**Required model change:** Add `stopping` to `Bot::STATUSES`:
```ruby
STATUSES = %w[pending initializing running paused stopping stopped error].freeze
```

**Required OrderFillWorker change:** Skip counter-order placement if bot is stopping/stopped:
```ruby
# In execute_fill, after finding bot:
return if %w[stopping stopped].include?(bot.status)
```

```ruby
# app/services/grid/stopper.rb
module Grid
  class Stopper
    def initialize(bot)
      @bot = bot
    end

    def call
      @bot.update!(status: 'stopping')
      ActionCable.server.broadcast("bot_#{@bot.id}", { type: 'status', status: 'stopping' })
      Grid::RedisState.new.update_status(@bot.id, 'stopping')

      client = Bybit::RestClient.new(exchange_account: @bot.exchange_account)
      client.cancel_all_orders(symbol: @bot.pair)

      ActiveRecord::Base.transaction do
        @bot.orders.active.update_all(status: 'cancelled')
        @bot.grid_levels.where(status: 'active').update_all(status: 'filled')
        @bot.update!(status: 'stopped', stop_reason: 'user')
      end

      Grid::RedisState.new.cleanup(@bot.id)
      ActionCable.server.broadcast("bot_#{@bot.id}", { type: 'status', status: 'stopped' })
    end
  end
end
```

**Response (200):** Same as GET /api/v1/bots/:id

#### DELETE /api/v1/bots/:id

Stops the bot (if running/paused) via `Grid::Stopper`, then sets `discarded_at` to soft-delete the record. The bot disappears from `GET /bots` index but trade history is preserved in the database.

**Required migration:** Add `discarded_at` column to `bots`:
```ruby
add_column :bots, :discarded_at, :datetime
add_index :bots, :discarded_at
```

**Required model change:** Add default scope filter and soft-delete method:
```ruby
# In Bot model
scope :kept, -> { where(discarded_at: nil) }

def discard!
  update!(discarded_at: Time.current)
end
```

The `GET /bots` index uses `Bot.kept` to exclude discarded bots. The record remains queryable via `Bot.unscoped` if needed for admin/debug purposes.

**Controller logic:**
1. If bot is running/paused/stopping: call `Grid::Stopper.new(bot).call`
2. Call `bot.discard!`
3. Return 200 with final bot state

**Response (200):** Same as GET /api/v1/bots/:id

#### GET /api/v1/bots/:bot_id/trades

**Query params:** `page` (default 1), `per_page` (default 20, max 100)

**Response (200):**
```json
{
  "trades": [
    {
      "id": 42,
      "level_index": 12,
      "buy_price": "2240.00",
      "sell_price": "2260.00",
      "quantity": "0.044200",
      "gross_profit": "0.88",
      "total_fees": "0.06",
      "net_profit": "0.82",
      "completed_at": "2026-03-07T14:30:00Z"
    }
  ],
  "pagination": {
    "page": 1,
    "per_page": 20,
    "total": 156,
    "total_pages": 8
  }
}
```

**Data source:** PostgreSQL `trades` table. Ordered by `completed_at DESC`.

#### GET /api/v1/bots/:bot_id/chart

**Query params:** `from` (ISO 8601, optional), `to` (ISO 8601, optional)

**Response (200):**
```json
{
  "snapshots": [
    {
      "snapshot_at": "2026-03-07T12:00:00Z",
      "total_value_quote": "1042.18",
      "realized_profit": "42.18",
      "unrealized_pnl": "12.50",
      "current_price": "2543.50"
    }
  ],
  "granularity": "fine"
}
```

**Granularity logic (automatic):**
- Last 24 hours: `fine` (5-min intervals)
- 1-7 days: `fine` (but will be dense)
- 7-30 days: `hourly`
- 30+ days: `daily`

The controller selects the appropriate granularity based on the requested time range. Defaults to last 24 hours if no `from`/`to` provided.

#### GET /api/v1/bots/:bot_id/grid

**Response (200):**
```json
{
  "grid": {
    "current_price": "2543.50",
    "levels": [
      {
        "level_index": 0,
        "price": "2000.00",
        "expected_side": "buy",
        "status": "active",
        "cycle_count": 3
      }
    ]
  }
}
```

**Data source:** Redis levels hash + Redis current_price. Falls back to DB if Redis is empty (bot not running).

#### GET /api/v1/exchange/pairs

**Response (200):**
```json
{
  "pairs": [
    {
      "symbol": "ETHUSDT",
      "base_coin": "ETH",
      "quote_coin": "USDT",
      "last_price": "2543.50",
      "tick_size": "0.01",
      "min_order_qty": "0.001",
      "min_order_amt": "1.00"
    }
  ]
}
```

**Query params:** `quote` (default `USDT`) — filters pairs by quote coin. Only USDT pairs are returned by default, avoiding 500+ irrelevant pairs.

**Data source:** `Bybit::RestClient.new.get_instruments_info` (category: spot) merged with `get_tickers` for last_price. Filtered server-side by `quoteCoin` matching the `quote` param. Cached in Redis for 5 minutes (`exchange:pairs:{quote}` key with TTL) to avoid repeated expensive API calls.

#### GET /api/v1/exchange/balance

**Response (200):**
```json
{
  "balance": {
    "coins": [
      { "coin": "USDT", "available": "5000.00", "locked": "1000.00", "total": "6000.00" },
      { "coin": "ETH", "available": "0.500000", "locked": "2.000000", "total": "2.500000" }
    ]
  }
}
```

**Data source:** `Bybit::RestClient.new(exchange_account:).get_wallet_balance`. No caching — must be real-time for the investment slider.

### 1.4 Serialization

Use plain Ruby hash construction in controllers (no gem dependency). The app is simple enough that jbuilder/blueprinter would add complexity without benefit. Each controller builds its response hash directly.

Helper module for common bot serialization:

```ruby
# app/controllers/api/v1/concerns/bot_serialization.rb
module Api::V1::BotSerialization
  extend ActiveSupport::Concern

  private

  def serialize_bot_summary(bot, redis_stats)
    {
      id: bot.id,
      pair: bot.pair,
      base_coin: bot.base_coin,
      quote_coin: bot.quote_coin,
      status: bot.status,
      lower_price: bot.lower_price.to_s,
      upper_price: bot.upper_price.to_s,
      grid_count: bot.grid_count,
      spacing_type: bot.spacing_type,
      investment_amount: bot.investment_amount.to_s,
      current_price: redis_stats[:current_price],
      realized_profit: redis_stats[:realized_profit],
      trade_count: redis_stats[:trade_count].to_i,
      active_levels: redis_stats[:active_levels].to_i,
      uptime_seconds: redis_stats[:uptime_seconds].to_i,
      created_at: bot.created_at.iso8601,
    }
  end

  def serialize_trade(trade)
    {
      id: trade.id,
      level_index: trade.grid_level.level_index,
      buy_price: trade.buy_price.to_s,
      sell_price: trade.sell_price.to_s,
      quantity: trade.quantity.to_s,
      gross_profit: trade.gross_profit.to_s,
      total_fees: trade.total_fees.to_s,
      net_profit: trade.net_profit.to_s,
      completed_at: trade.completed_at.iso8601,
    }
  end
end
```

### 1.5 Redis Stats Reader

Extend `Grid::RedisState` with a read method for the dashboard:

```ruby
# Add to Grid::RedisState
def read_stats(bot_id)
  status = @redis.get(key(bot_id, :status))
  price = @redis.get(key(bot_id, :current_price))
  stats = @redis.hgetall(key(bot_id, :stats))
  levels_raw = @redis.hgetall(key(bot_id, :levels))

  active_count = levels_raw.values.count do |json|
    Oj.load(json, symbol_keys: true)[:status] == 'active'
  end

  uptime_start = stats['uptime_start']&.to_i
  uptime_seconds = uptime_start ? (Time.current.to_i - uptime_start) : 0

  {
    status: status,
    current_price: price,
    realized_profit: stats['realized_profit'] || '0',
    trade_count: stats['trade_count'] || '0',
    active_levels: active_count,
    uptime_seconds: uptime_seconds,
  }
end

def read_levels(bot_id)
  levels_raw = @redis.hgetall(key(bot_id, :levels))
  levels_raw.map do |index, json|
    data = Oj.load(json, symbol_keys: true)
    data.merge(level_index: index.to_i)
  end.sort_by { |l| l[:level_index] }
end
```

### 1.6 ActionCable — BotChannel

```ruby
# app/channels/bot_channel.rb
class BotChannel < ApplicationCable::Channel
  def subscribed
    bot = Bot.find(params[:bot_id])
    stream_from "bot_#{bot.id}"
  end

  def unsubscribed
    stop_all_streams
  end
end
```

**Broadcast points (server-side):**

1. **OrderFillWorker** — after processing a fill and updating Redis, broadcast. Read `realized_profit` and `trade_count` from Redis (already updated by `update_on_fill`), not from DB queries in the critical path:
   ```ruby
   redis_stats = Grid::RedisState.new.read_stats(bot.id)
   ActionCable.server.broadcast("bot_#{bot.id}", {
     type: 'fill',
     grid_level: { level_index:, price:, expected_side:, status:, cycle_count: },
     trade: trade ? serialize_trade(trade) : nil,
     realized_profit: redis_stats[:realized_profit],
     trade_count: redis_stats[:trade_count].to_i,
   })
   ```

2. **BalanceSnapshotWorker** — after saving snapshot, broadcast price update:
   ```ruby
   ActionCable.server.broadcast("bot_#{bot.id}", {
     type: 'price_update',
     current_price: current_price.to_s,
     unrealized_pnl: snapshot.unrealized_pnl.to_s,
     total_value_quote: snapshot.total_value_quote.to_s,
   })
   ```

3. **Bot status changes** — from `Grid::Initializer`, `Grid::Stopper`, any status transition:
   ```ruby
   ActionCable.server.broadcast("bot_#{bot.id}", {
     type: 'status',
     status: bot.status,
     stop_reason: bot.stop_reason,
   })
   ```

**Message types sent over ActionCable:**

| Type | Trigger | Payload |
|------|---------|---------|
| `fill` | OrderFillWorker completes | grid_level state, trade record, updated profit |
| `price_update` | BalanceSnapshotWorker (every 5 min) | current_price, unrealized_pnl, total_value |
| `status` | Bot lifecycle transition | new status, stop_reason |

### 1.7 ActionCable Configuration

**Development:** Use the `async` adapter (already configured in `config/cable.yml`). This works for single-server development.

**Production:** Switch to `redis` adapter (already configured). Set `REDIS_URL` env var. ActionCable will share the same Redis instance as Sidekiq and `Grid::RedisState`.

**CORS for ActionCable:** Add to `config/environments/development.rb`:
```ruby
config.action_cable.url = 'ws://localhost:3000/cable'
config.action_cable.allowed_request_origins = ['http://localhost:5173'] # Vite dev server
```

### 1.8 CORS Configuration

Update `config/initializers/cors.rb`:

```ruby
Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins ENV.fetch('CORS_ORIGIN', 'http://localhost:5173')

    resource '*',
      headers: :any,
      methods: [:get, :post, :put, :patch, :delete, :options, :head]
  end
end
```

Uses `CORS_ORIGIN` env var (defaults to Vite dev server). In production, set to the deployed frontend URL.

### 1.9 Error Response Format

All error responses use the same shape:

```json
{
  "error": "Human-readable message"
}
```

Or for validation errors:

```json
{
  "error": ["Lower price must be greater than 0", "Grid count must be at least 2"]
}
```

HTTP status codes: 200 (OK), 201 (Created), 400 (Bad Request), 404 (Not Found), 422 (Unprocessable Entity), 500 (Internal Server Error).

### 1.10 New Services Summary

| Service | Purpose |
|---------|---------|
| `Grid::Stopper` | Stop bot: cancel orders, clean up state, broadcast |
| `BotInitializerJob` | Sidekiq job wrapper for `Grid::Initializer` |
| `Grid::RedisState#read_stats` | Read-only dashboard data from Redis |
| `Grid::RedisState#read_levels` | Read grid levels from Redis for visualization |

---

## 2. Frontend Architecture

### 2.1 Project Scaffolding

The frontend does not exist yet. Scaffold under `frontends/app/` using Vite + React + TypeScript.

```bash
cd frontends
npm create vite@latest app -- --template react-ts
cd app
npm install @mui/material @emotion/react @emotion/styled @mui/icons-material
npm install @tanstack/react-query axios
npm install react-router-dom
npm install recharts
npm install @rails/actioncable
```

### 2.2 Directory Structure

```
frontends/app/src/
  main.tsx                    # Entry point: providers, router
  App.tsx                     # Top-level layout with AppBar
  theme.ts                    # MUI v6 theme config
  api/
    client.ts                 # Axios instance (base URL, interceptors)
    bots.ts                   # Bot API calls + React Query hooks
    exchange.ts               # Exchange API calls + React Query hooks
  cable/
    consumer.ts               # ActionCable consumer singleton
    useBotChannel.ts           # Hook: subscribe to bot updates
  pages/
    BotDashboard.tsx           # /bots — card grid of all bots
    BotDetail.tsx              # /bots/:id — tabs: overview, grid, trades
    CreateBotWizard.tsx        # /bots/new — 3-step wizard
  components/
    BotCard.tsx                # Dashboard card for a single bot
    GridVisualization.tsx       # Vertical price axis grid view
    PerformanceCharts.tsx       # Line + bar charts
    TradeHistoryTable.tsx       # Paginated trade table
    RangeVisualizer.tsx         # Horizontal price range bar
    StatusBadge.tsx             # Color-coded status chip
    wizard/
      StepSelectPair.tsx        # Step 1
      StepSetParameters.tsx     # Step 2
      StepInvestment.tsx        # Step 3
  types/
    bot.ts                     # TypeScript interfaces
    trade.ts
    exchange.ts
    cable.ts
```

### 2.3 TypeScript Types

```typescript
// types/bot.ts
export interface Bot {
  id: number;
  pair: string;
  base_coin: string;
  quote_coin: string;
  status: 'pending' | 'initializing' | 'running' | 'paused' | 'stopping' | 'stopped' | 'error';
  lower_price: string;
  upper_price: string;
  grid_count: number;
  spacing_type: 'arithmetic' | 'geometric';
  investment_amount: string;
  tick_size?: string;
  base_precision?: number;
  quote_precision?: number;
  current_price?: string;
  realized_profit?: string;
  unrealized_pnl?: string;
  trade_count?: number;
  active_levels?: number;
  uptime_seconds?: number;
  created_at: string;
}

export interface GridLevel {
  level_index: number;
  price: string;
  expected_side: 'buy' | 'sell';
  status: 'pending' | 'active' | 'filled' | 'skipped';
  cycle_count: number;
}

export interface BotDetail extends Bot {
  recent_trades: Trade[];
  // grid_levels served separately via GET /bots/:id/grid (useBotGrid hook)
}

export interface CreateBotParams {
  pair: string;
  base_coin: string;
  quote_coin: string;
  lower_price: string;
  upper_price: string;
  grid_count: number;
  spacing_type: 'arithmetic' | 'geometric';
  investment_amount: string;
}

// types/trade.ts
export interface Trade {
  id: number;
  level_index: number;
  buy_price: string;
  sell_price: string;
  quantity: string;
  gross_profit: string;
  total_fees: string;
  net_profit: string;
  completed_at: string;
}

export interface PaginatedTrades {
  trades: Trade[];
  pagination: {
    page: number;
    per_page: number;
    total: number;
    total_pages: number;
  };
}

// types/exchange.ts
export interface TradingPair {
  symbol: string;
  base_coin: string;
  quote_coin: string;
  last_price: string;
  tick_size: string;
  min_order_qty: string;
  min_order_amt: string;
}

export interface CoinBalance {
  coin: string;
  available: string;
  locked: string;
  total: string;
}

// types/cable.ts
export interface FillEvent {
  type: 'fill';
  grid_level: GridLevel;
  trade: Trade | null;
  realized_profit: string;
  trade_count: number;
}

export interface PriceUpdateEvent {
  type: 'price_update';
  current_price: string;
  unrealized_pnl: string;
  total_value_quote: string;
}

export interface StatusEvent {
  type: 'status';
  status: string;
  stop_reason: string | null;
}

export type BotCableEvent = FillEvent | PriceUpdateEvent | StatusEvent;
```

### 2.4 Routing

```typescript
// React Router v6 (note: BRIEF says React Router; v6 is current)
<Routes>
  <Route path="/" element={<Navigate to="/bots" replace />} />
  <Route path="/bots" element={<BotDashboard />} />
  <Route path="/bots/new" element={<CreateBotWizard />} />
  <Route path="/bots/:id" element={<BotDetail />} />
</Routes>
```

Three routes total. Simple and flat.

### 2.5 API Client Layer

```typescript
// api/client.ts
import axios from 'axios';

const apiClient = axios.create({
  baseURL: import.meta.env.VITE_API_URL || 'http://localhost:3000/api/v1',
  headers: { 'Content-Type': 'application/json' },
});

export default apiClient;
```

```typescript
// api/bots.ts
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query';
import apiClient from './client';

export const useBots = () =>
  useQuery({ queryKey: ['bots'], queryFn: () => apiClient.get('/bots').then(r => r.data.bots) });

export const useBot = (id: number) =>
  useQuery({ queryKey: ['bots', id], queryFn: () => apiClient.get(`/bots/${id}`).then(r => r.data.bot) });

export const useBotGrid = (id: number) =>
  useQuery({ queryKey: ['bots', id, 'grid'], queryFn: () => apiClient.get(`/bots/${id}/grid`).then(r => r.data.grid) });

export const useBotTrades = (id: number, page: number) =>
  useQuery({
    queryKey: ['bots', id, 'trades', page],
    queryFn: () => apiClient.get(`/bots/${id}/trades`, { params: { page } }).then(r => r.data),
  });

export const useBotChart = (id: number) =>
  useQuery({ queryKey: ['bots', id, 'chart'], queryFn: () => apiClient.get(`/bots/${id}/chart`).then(r => r.data) });

export const useCreateBot = () => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (params: CreateBotParams) => apiClient.post('/bots', { bot: params }),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['bots'] }),
  });
};

export const useUpdateBot = (id: number) => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (params: Partial<Bot>) => apiClient.patch(`/bots/${id}`, { bot: params }),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['bots'] });
      qc.invalidateQueries({ queryKey: ['bots', id] });
    },
  });
};

export const useDeleteBot = () => {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (id: number) => apiClient.delete(`/bots/${id}`),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['bots'] }),
  });
};
```

### 2.6 ActionCable Client Integration

```typescript
// cable/consumer.ts
import { createConsumer } from '@rails/actioncable';

const cableUrl = import.meta.env.VITE_CABLE_URL || 'ws://localhost:3000/cable';
const consumer = createConsumer(cableUrl);

export default consumer;
```

```typescript
// cable/useBotChannel.ts
import { useEffect, useRef, useState, useCallback } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import consumer from './consumer';
import type { BotCableEvent, FillEvent, PriceUpdateEvent } from '../types/cable';
import type { BotDetail } from '../types/bot';

export function useBotChannel(botId: number) {
  const qc = useQueryClient();
  const subRef = useRef<any>(null);
  const [connectionStatus, setConnectionStatus] = useState<'connected' | 'disconnected'>('disconnected');

  useEffect(() => {
    subRef.current = consumer.subscriptions.create(
      { channel: 'BotChannel', bot_id: botId },
      {
        connected() {
          setConnectionStatus('connected');
        },

        disconnected() {
          setConnectionStatus('disconnected');
        },

        received(event: BotCableEvent) {
          if (event.type === 'fill') {
            // Direct cache update — data is already in the payload, no refetch needed
            qc.setQueryData<BotDetail>(['bots', botId], (old) => {
              if (!old) return old;
              return {
                ...old,
                realized_profit: event.realized_profit,
                trade_count: event.trade_count,
                recent_trades: event.trade
                  ? [event.trade, ...old.recent_trades.slice(0, 9)]
                  : old.recent_trades,
              };
            });
            // Grid data updated inline from event
            qc.setQueryData(['bots', botId, 'grid'], (old: any) => {
              if (!old) return old;
              return {
                ...old,
                levels: old.levels.map((l: any) =>
                  l.level_index === event.grid_level.level_index ? event.grid_level : l
                ),
              };
            });
            // Invalidate trades list (pagination may have shifted)
            qc.invalidateQueries({ queryKey: ['bots', botId, 'trades'] });
          }

          if (event.type === 'price_update') {
            qc.setQueryData<BotDetail>(['bots', botId], (old) => {
              if (!old) return old;
              return {
                ...old,
                current_price: event.current_price,
                unrealized_pnl: event.unrealized_pnl,
              };
            });
            qc.setQueryData(['bots', botId, 'grid'], (old: any) => {
              if (!old) return old;
              return { ...old, current_price: event.current_price };
            });
          }

          if (event.type === 'status') {
            // Status changes are infrequent — full refetch is fine
            qc.invalidateQueries({ queryKey: ['bots'] });
            qc.invalidateQueries({ queryKey: ['bots', botId] });
          }
        },
      }
    );

    return () => {
      subRef.current?.unsubscribe();
    };
  }, [botId, qc]);

  return { connectionStatus };
}
```

**Design decisions:**
- **Fill events** use `setQueryData` for direct cache mutation — the ActionCable payload contains all needed data, so a refetch would be wasteful during rapid fills. Only the paginated trades list is invalidated (pagination offset may have shifted).
- **Price updates** also use direct cache mutation (same reasoning).
- **Status events** use invalidate + refetch — these are infrequent and may require full state refresh.
- **Connection status** is tracked via ActionCable's `connected()`/`disconnected()` callbacks and returned from the hook. The BotDetail page shows a "Disconnected" banner when `connectionStatus === 'disconnected'`.

### 2.7 MUI v6 Theme

```typescript
// theme.ts
import { createTheme } from '@mui/material/styles';

const theme = createTheme({
  palette: {
    mode: 'dark',
    primary: { main: '#4caf50' },     // Green — profit, buy
    secondary: { main: '#f44336' },   // Red — loss, sell
    background: {
      default: '#121212',
      paper: '#1e1e1e',
    },
  },
  typography: {
    fontFamily: '"Inter", "Roboto", sans-serif',
    h6: { fontWeight: 600 },
  },
  components: {
    MuiCard: {
      defaultProps: { elevation: 2 },
    },
  },
});

export default theme;
```

Dark theme by default — standard for trading UIs.

### 2.8 Component Design

#### BotDashboard (`/bots`)

- Fetches bots list via `useBots()`
- Renders a responsive MUI `Grid` of `BotCard` components
- "New Bot" FAB button navigates to `/bots/new`
- Auto-refreshes every 30s via React Query `refetchInterval`

#### BotCard

- MUI `Card` with:
  - Pair name (large), StatusBadge (chip)
  - `RangeVisualizer` — horizontal bar with lower/current/upper price markers
  - Realized profit (green text), trade count
  - Daily APR (calculated client-side: `realized_profit / investment * 365 / days_running * 100`)
  - Uptime (formatted: "2d 5h 30m")
- Click navigates to `/bots/:id`

#### RangeVisualizer

- Simple horizontal bar (MUI `LinearProgress` variant or custom div)
- Position = `(parseFloat(current_price) - parseFloat(lower)) / (parseFloat(upper) - parseFloat(lower)) * 100` clamped 0-100
- Color: green if in range, amber if near edge (<10%), red if out of range
- **Note on parseFloat:** Using `parseFloat()` is acceptable for display-only positioning calculations (pixel offsets, progress percentages). It must NEVER be used for financial calculations (profit, fees, quantities) — those are computed server-side with BigDecimal and sent as pre-formatted strings.

#### BotDetail (`/bots/:id`)

- Fetches bot detail via `useBot(id)`
- Subscribes to ActionCable via `useBotChannel(id)`
- Four sections, no tabs (single scrollable page for simplicity):
  1. **Header**: Pair, StatusBadge, uptime, Stop/Pause/Resume buttons
  2. **Stats Row**: Realized Profit | Unrealized PnL | Trade Count | Active Levels — as MUI `Card` components
  3. **Grid Visualization + Performance Charts** (side by side on desktop, stacked on mobile)
  4. **Trade History Table**

#### GridVisualization

- Vertical price axis (Y axis = price, ascending bottom to top)
- Each grid level rendered as a horizontal row:
  - Price label on left
  - Color-coded bar: green = buy active, red = sell active, grey = filled/pending
  - Cycle count badge on right
- Current price: prominent horizontal marker line with label
- Implementation: Custom SVG or simple CSS grid. Recharts is overkill for this — a custom component with `div` elements and absolute positioning is simpler and more controllable.
- Scrollable if many levels (>20 visible at once)

#### PerformanceCharts

Uses **Recharts** (lightweight, React-native, good MUI compatibility).

1. **Equity Curve** (`LineChart`):
   - X: time, Y: `total_value_quote` from snapshots
   - Single line, green fill area below
   - Tooltip with exact values

2. **Daily Profit** (`BarChart`):
   - X: date, Y: realized profit per day
   - Green bars (positive), red bars (negative)
   - Computed client-side by grouping `trades` by date if daily_bot_stats not yet available (Phase 5)
   - For MVP: derive from snapshots difference in `realized_profit` between consecutive days

#### TradeHistoryTable

- MUI `Table` with sortable `completed_at` column
- Columns: Date, Level, Buy Price, Sell Price, Qty, Net Profit, Fees
- Paginated via `useBotTrades(id, page)` — server-side pagination
- Net profit cell: green text if positive, red if negative

#### CreateBotWizard (`/bots/new`)

Three steps using MUI `Stepper`.

**Step 1 — Select Pair:**
- `useExchangePairs()` fetches pairs list
- MUI `Autocomplete` (searchable dropdown) — AC-023
- On select: stores `{ symbol, base_coin, quote_coin, last_price, tick_size, min_order_qty, min_order_amt }`
- **Click 1: Select pair from dropdown**

**Step 2 — Set Parameters:**
- Lower price, Upper price: MUI `TextField` (number input)
- Grid count: MUI `Slider` (2-200) + `TextField`
- Spacing type: MUI `ToggleButtonGroup` (Arithmetic / Geometric)
- Live preview panel (updates on every change):
  - Grid step size: `(upper - lower) / grid_count`
  - Profit per grid: `step_size / lower_price * 100` (gross %)
  - Computed client-side using the same formulas as `Grid::Calculator`
- **Defaults pre-filled:** lower = last_price * 0.9, upper = last_price * 1.1, count = 20, arithmetic
- Validation: lower < last_price < upper, count >= 2
- **Click 2: "Next" button (defaults are acceptable)**

**Step 3 — Investment:**
- `useExchangeBalance()` fetches USDT balance
- MUI `Slider` for % of available USDT (10%-100%, default 50%)
- Calculated display:
  - Total USDT to invest
  - Quantity per grid level
  - Fee impact: `grid_count * 2 * qty * price * 0.001` (round-trip taker fee estimate)
- Confirmation summary of all params
- **Click 3: "Create Bot" submit button**
- On submit: `useCreateBot().mutate(params)` then navigate to `/bots/:id`

**3-click flow (AC-016):** Select pair -> Next (accept defaults) -> Create Bot

### 2.9 Chart Library

**Recharts** — chosen because:
- React-native (no DOM manipulation)
- Lightweight (~40kb gzipped)
- Good default styling with dark themes
- Sufficient for line/bar charts needed here
- No complex time-series requirements that would justify heavier libraries (like TradingView Lightweight Charts)

### 2.10 Entry Point

```typescript
// main.tsx
import React from 'react';
import ReactDOM from 'react-dom/client';
import { BrowserRouter } from 'react-router-dom';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { ThemeProvider, CssBaseline } from '@mui/material';
import theme from './theme';
import App from './App';

const queryClient = new QueryClient({
  defaultOptions: {
    queries: { staleTime: 10_000, refetchOnWindowFocus: true },
  },
});

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <BrowserRouter>
      <QueryClientProvider client={queryClient}>
        <ThemeProvider theme={theme}>
          <CssBaseline />
          <App />
        </ThemeProvider>
      </QueryClientProvider>
    </BrowserRouter>
  </React.StrictMode>
);
```

```typescript
// App.tsx
import { Routes, Route, Navigate } from 'react-router-dom';
import { AppBar, Toolbar, Typography, Container } from '@mui/material';
import BotDashboard from './pages/BotDashboard';
import BotDetail from './pages/BotDetail';
import CreateBotWizard from './pages/CreateBotWizard';

export default function App() {
  return (
    <>
      <AppBar position="static">
        <Toolbar>
          <Typography variant="h6" component="a" href="/bots" sx={{ textDecoration: 'none', color: 'inherit' }}>
            Volatility Harvester
          </Typography>
        </Toolbar>
      </AppBar>
      <Container maxWidth="lg" sx={{ mt: 3 }}>
        <Routes>
          <Route path="/" element={<Navigate to="/bots" replace />} />
          <Route path="/bots" element={<BotDashboard />} />
          <Route path="/bots/new" element={<CreateBotWizard />} />
          <Route path="/bots/:id" element={<BotDetail />} />
        </Routes>
      </Container>
    </>
  );
}
```

### 2.11 Frontend States: Loading, Empty, Error

Every page and data-dependent component must handle three states beyond the happy path:

**Loading states:**
- Use MUI `Skeleton` components that match the shape of the loaded content (card skeletons on dashboard, table row skeletons on trades)
- BotDashboard: grid of 3 `Skeleton` cards
- BotDetail: skeleton for stats row, placeholder for grid visualization
- CreateBotWizard Step 1: `Skeleton` in the Autocomplete while pairs load
- CreateBotWizard Step 3: `Skeleton` for balance while fetching

**Empty states:**
- BotDashboard (no bots): Centered message "No bots yet" with prominent "Create Your First Bot" button
- TradeHistoryTable (no trades): "No trades completed yet. Waiting for the first grid cycle."
- PerformanceCharts (no snapshots): "Not enough data yet. Charts appear after the first few minutes of running."

**Error states:**
- API errors: MUI `Alert` component (severity: error) with the error message from the API response
- 503 with `setup_required: true`: Full-page message "Exchange account not configured" with setup instructions
- ActionCable disconnected: `Snackbar` or `Alert` banner at top of BotDetail: "Real-time connection lost. Data may be stale." (driven by `connectionStatus` from `useBotChannel`)
- Bot in `error` status: Red `Alert` on BotDetail header explaining the bot failed, with the stop_reason if available
- Bot in `initializing`/`pending`: Show a `CircularProgress` with "Setting up your bot..." message instead of the normal detail view

**Retry behavior:**
- React Query handles automatic retry (3 attempts with exponential backoff by default)
- Manual retry: Error states include a "Retry" button that calls `queryClient.invalidateQueries`

---

## 3. Data Flow Diagrams

### 3.1 Create Bot Flow

```
User (Wizard)
  |-- POST /api/v1/bots --> BotsController#create
  |                           |-- Bot.create!(status: 'pending')
  |                           |-- BotInitializerJob.perform_async(bot.id)
  |                           |-- render bot JSON (201)
  |
  |-- Subscribe to BotChannel(bot_id)
  |
  BotInitializerJob:
    |-- Grid::Initializer.new(bot).call
    |-- (fetches instrument, places orders, seeds Redis)
    |-- bot.update!(status: 'running')
    |-- ActionCable broadcast: { type: 'status', status: 'running' }
  |
  Frontend receives 'status' event --> React Query invalidates --> UI updates
```

### 3.2 Real-Time Update Flow

```
Exchange WebSocket
  |-- Fill event
  |-- WebsocketListener enqueues OrderFillWorker
  |
OrderFillWorker:
  |-- Process fill (update order, grid_level, record trade)
  |-- Grid::RedisState.update_on_fill(...)
  |-- ActionCable broadcast: { type: 'fill', ... }
  |
BotChannel --> Frontend
  |-- useBotChannel hook receives event
  |-- React Query invalidates ['bots', id] and ['bots', id, 'grid']
  |-- Components re-render with fresh data
```

### 3.3 Dashboard Read Flow

```
Frontend loads /bots
  |-- GET /api/v1/bots
  |     |-- BotsController#index
  |     |-- Bot.all (DB: config only)
  |     |-- Grid::RedisState.read_stats(bot.id) for each bot (Redis: live stats)
  |     |-- Merge and return JSON
  |
  React Query caches result, refreshes every 30s
```

---

## 4. Technical Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Serialization | Plain Ruby hashes | No need for a gem — 10 endpoints, single-user app. Adding blueprinter/jbuilder is unnecessary abstraction. |
| Frontend framework | Vite + React 18 + TypeScript | Matches IMPLEMENTATION_PLAN. Vite for fast dev, TS for type safety on API contracts. |
| React Router | v6 | Current stable version. Only 3 routes. |
| State management | React Query only | Server state only, no complex client state. ActionCable events update cache directly for fills/prices, invalidate for status. |
| ActionCable strategy | Direct cache update for fills/prices, invalidate for status | `setQueryData` avoids refetch storms during rapid fills. Status changes are rare and warrant full refresh. |
| Chart library | Recharts | Lightweight, React-native, good for line/bar charts. No need for TradingView-class charting. |
| Grid visualization | Custom CSS/SVG component | More control than any charting library. The grid is a domain-specific visualization. |
| Pagination | Offset-based (page/per_page) | Simple, sufficient for trade history. Cursor-based would be needed at scale but is overkill here. |
| Bot creation | Async via Sidekiq job | Grid::Initializer makes exchange API calls (slow). HTTP request returns immediately. |
| Bot deletion | Soft-delete via `discarded_at` column | Trade history preserved. Bot removed from index. Record queryable via `Bot.unscoped` for debug. |
| Bot stopping | Two-phase via `stopping` status | Prevents OrderFillWorker from placing orphaned counter-orders during shutdown. |
| CORS | `CORS_ORIGIN` env var, defaults to localhost:5173 | Configurable per environment. |
| Exchange pairs | Filtered by quote coin (default USDT) | Avoids fetching 500+ irrelevant pairs. Cached in Redis for 5 min. |
| parseFloat in frontend | OK for display positions only | Never for financial math. All financial values are pre-formatted strings from the server. |

---

## 5. Implementation Task Breakdown

### Backend Tasks

| # | Task | Files | Depends On |
|---|------|-------|------------|
| T1 | Migration: add `discarded_at` to bots + add `stopping` to Bot::STATUSES | migration, `bot.rb` model update | — |
| T2 | Base controller + routes + CORS | `base_controller.rb`, `routes.rb`, `cors.rb` | — |
| T3 | BotInitializerJob + Grid::Stopper (with `stopping` status) | `bot_initializer_job.rb`, `grid/stopper.rb` | T1 |
| T4 | Grid::RedisState read methods | `grid/redis_state.rb` (extend) | — |
| T5 | BotsController (index, show, create, update, destroy) | `bots_controller.rb`, `bot_serialization.rb` | T1, T2, T3, T4 |
| T6 | Trades, Chart, Grid sub-controllers | `bots/trades_controller.rb`, `bots/chart_controller.rb`, `bots/grid_controller.rb` | T2, T4 |
| T7 | Exchange pairs + balance controllers | `exchange/pairs_controller.rb`, `exchange/balance_controller.rb` | T2 |
| T8 | BotChannel + ActionCable broadcasts (read from Redis, not DB) | `bot_channel.rb`, update `OrderFillWorker`, `BalanceSnapshotWorker` | T2, T4 |
| T9 | Backend RSpec tests | `spec/controllers/api/v1/`, `spec/services/grid/stopper_spec.rb` | T5-T8 |

### Frontend Tasks

| # | Task | Files | Depends On |
|---|------|-------|------------|
| T10 | Vite project scaffold + deps + theme | `frontends/app/` scaffold | — |
| T11 | API client + React Query hooks + types | `api/`, `types/` | T10 |
| T12 | ActionCable client + useBotChannel hook (with connectionStatus) | `cable/` | T10 |
| T13 | BotDashboard + BotCard + RangeVisualizer (with loading/empty states) | `pages/BotDashboard.tsx`, `components/` | T11 |
| T14 | CreateBotWizard (3 steps, with loading/error states) | `pages/CreateBotWizard.tsx`, `components/wizard/` | T11 |
| T15 | BotDetail page + GridVisualization (with disconnected banner) | `pages/BotDetail.tsx`, `components/GridVisualization.tsx` | T11, T12 |
| T16 | PerformanceCharts + TradeHistoryTable (with empty states) | `components/PerformanceCharts.tsx`, `components/TradeHistoryTable.tsx` | T11 |

### Parallelism

- T1, T2, T4 can run in parallel (no dependencies)
- T3 depends on T1; T5-T8 depend on T2-T4 but can run in parallel with each other
- T10 can start immediately (no backend dependency)
- T11-T12 depend on T10
- T13-T16 depend on T11 and can run in parallel

---

## 6. Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Grid::Stopper races with OrderFillWorker | Orphaned orders on exchange | Two-phase stop: set `stopping` status first (blocks counter-orders), then cancel exchange orders. |
| Exchange pairs endpoint is slow (fetches all 500+ pairs) | Wizard step 1 feels laggy | Filter to USDT pairs only by default. Cache in Redis for 5 min. Show loading skeleton. |
| ActionCable connection drops | Dashboard shows stale data | React Query still polls every 30s as fallback. Show "Disconnected" indicator if cable drops. |
| Redis unavailable | Dashboard returns empty stats | Fall back to DB queries (slower but correct). `read_stats` should rescue Redis errors and query DB. |
| Many grid levels (200) makes visualization crowded | Bad UX on grid view | Virtual scrolling or zoom/collapse for levels outside +-10% of current price. |
| Bot creation fails mid-initialization | User sees "initializing" forever | BotInitializerJob transitions to 'error' on failure. Frontend shows error status with retry option. Already handled by Grid::Initializer. |
