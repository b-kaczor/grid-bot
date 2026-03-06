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
