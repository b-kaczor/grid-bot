class AddMaxOrderQtyToBots < ActiveRecord::Migration[7.1]
  def change
    add_column :bots, :max_order_qty, :decimal, precision: 20, scale: 8
  end
end
