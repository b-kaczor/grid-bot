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
    add_index :orders, %i[grid_level_id status]
    add_index :orders, %i[bot_id status]
  end
end
