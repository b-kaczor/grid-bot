# frozen_string_literal: true

class CreateGridLevels < ActiveRecord::Migration[7.1]
  def change
    create_table :grid_levels do |t|
      t.references :bot, null: false, foreign_key: true
      t.integer :level_index, null: false
      t.decimal :price, precision: 20, scale: 8, null: false
      t.string :expected_side, null: false
      t.string :status, null: false, default: 'pending'
      t.string :current_order_id
      t.string :current_order_link_id
      t.integer :cycle_count, null: false, default: 0
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end

    add_index :grid_levels, %i[bot_id level_index], unique: true
  end
end
