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

    add_index :balance_snapshots, %i[bot_id snapshot_at]
    add_index :balance_snapshots, %i[bot_id granularity snapshot_at]
  end
end
