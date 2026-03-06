# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.1].define(version: 2026_03_07_005001) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "balance_snapshots", force: :cascade do |t|
    t.bigint "bot_id", null: false
    t.decimal "base_balance", precision: 20, scale: 8
    t.decimal "quote_balance", precision: 20, scale: 8
    t.decimal "total_value_quote", precision: 20, scale: 8
    t.decimal "current_price", precision: 20, scale: 8
    t.decimal "realized_profit", precision: 20, scale: 8
    t.decimal "unrealized_pnl", precision: 20, scale: 8
    t.string "granularity", default: "fine", null: false
    t.datetime "snapshot_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["bot_id", "granularity", "snapshot_at"], name: "idx_on_bot_id_granularity_snapshot_at_9f7187b3be"
    t.index ["bot_id", "snapshot_at"], name: "index_balance_snapshots_on_bot_id_and_snapshot_at"
    t.index ["bot_id"], name: "index_balance_snapshots_on_bot_id"
  end

  create_table "bots", force: :cascade do |t|
    t.bigint "exchange_account_id", null: false
    t.string "pair", null: false
    t.string "base_coin", null: false
    t.string "quote_coin", null: false
    t.decimal "lower_price", precision: 20, scale: 8, null: false
    t.decimal "upper_price", precision: 20, scale: 8, null: false
    t.integer "grid_count", null: false
    t.string "spacing_type", default: "arithmetic", null: false
    t.decimal "investment_amount", precision: 20, scale: 8, null: false
    t.decimal "tick_size", precision: 20, scale: 12
    t.decimal "min_order_amt", precision: 20, scale: 8
    t.decimal "min_order_qty", precision: 20, scale: 8
    t.integer "base_precision"
    t.integer "quote_precision"
    t.string "status", default: "pending", null: false
    t.string "stop_reason"
    t.decimal "stop_loss_price", precision: 20, scale: 8
    t.decimal "take_profit_price", precision: 20, scale: 8
    t.boolean "trailing_up_enabled", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["exchange_account_id"], name: "index_bots_on_exchange_account_id"
  end

  create_table "exchange_accounts", force: :cascade do |t|
    t.string "name", null: false
    t.string "exchange", default: "bybit", null: false
    t.text "api_key_ciphertext", null: false
    t.text "api_secret_ciphertext", null: false
    t.string "environment", default: "testnet", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["exchange", "environment", "name"], name: "index_exchange_accounts_on_exchange_and_environment_and_name", unique: true
  end

  create_table "grid_levels", force: :cascade do |t|
    t.bigint "bot_id", null: false
    t.integer "level_index", null: false
    t.decimal "price", precision: 20, scale: 8, null: false
    t.string "expected_side", null: false
    t.string "status", default: "pending", null: false
    t.string "current_order_id"
    t.string "current_order_link_id"
    t.integer "cycle_count", default: 0, null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["bot_id", "level_index"], name: "index_grid_levels_on_bot_id_and_level_index", unique: true
    t.index ["bot_id"], name: "index_grid_levels_on_bot_id"
  end

  create_table "orders", force: :cascade do |t|
    t.bigint "bot_id", null: false
    t.bigint "grid_level_id", null: false
    t.string "exchange_order_id"
    t.string "order_link_id", null: false
    t.string "side", null: false
    t.decimal "price", precision: 20, scale: 8, null: false
    t.decimal "quantity", precision: 20, scale: 8, null: false
    t.decimal "filled_quantity", precision: 20, scale: 8, default: "0.0"
    t.decimal "net_quantity", precision: 20, scale: 8
    t.decimal "avg_fill_price", precision: 20, scale: 8
    t.decimal "fee", precision: 20, scale: 10, default: "0.0"
    t.string "fee_coin"
    t.string "status", default: "pending", null: false
    t.datetime "placed_at"
    t.datetime "filled_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["bot_id", "status"], name: "index_orders_on_bot_id_and_status"
    t.index ["bot_id"], name: "index_orders_on_bot_id"
    t.index ["exchange_order_id"], name: "index_orders_on_exchange_order_id"
    t.index ["grid_level_id", "status"], name: "index_orders_on_grid_level_id_and_status"
    t.index ["grid_level_id"], name: "index_orders_on_grid_level_id"
    t.index ["order_link_id"], name: "index_orders_on_order_link_id", unique: true
  end

  create_table "trades", force: :cascade do |t|
    t.bigint "bot_id", null: false
    t.bigint "grid_level_id", null: false
    t.bigint "buy_order_id", null: false
    t.bigint "sell_order_id", null: false
    t.decimal "buy_price", precision: 20, scale: 8, null: false
    t.decimal "sell_price", precision: 20, scale: 8, null: false
    t.decimal "quantity", precision: 20, scale: 8, null: false
    t.decimal "gross_profit", precision: 20, scale: 10, null: false
    t.decimal "total_fees", precision: 20, scale: 10, null: false
    t.decimal "net_profit", precision: 20, scale: 10, null: false
    t.datetime "completed_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["bot_id", "completed_at"], name: "index_trades_on_bot_id_and_completed_at"
    t.index ["bot_id"], name: "index_trades_on_bot_id"
    t.index ["buy_order_id"], name: "index_trades_on_buy_order_id"
    t.index ["grid_level_id"], name: "index_trades_on_grid_level_id"
    t.index ["sell_order_id"], name: "index_trades_on_sell_order_id"
  end

  add_foreign_key "balance_snapshots", "bots"
  add_foreign_key "bots", "exchange_accounts"
  add_foreign_key "grid_levels", "bots"
  add_foreign_key "orders", "bots"
  add_foreign_key "orders", "grid_levels"
  add_foreign_key "trades", "bots"
  add_foreign_key "trades", "grid_levels"
  add_foreign_key "trades", "orders", column: "buy_order_id"
  add_foreign_key "trades", "orders", column: "sell_order_id"
end
