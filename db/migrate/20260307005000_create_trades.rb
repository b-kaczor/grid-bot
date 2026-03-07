# frozen_string_literal: true

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

    add_index :trades, %i[bot_id completed_at]
  end
end
