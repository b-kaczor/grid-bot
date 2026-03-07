# frozen_string_literal: true

class AddQuantityPerLevelToBots < ActiveRecord::Migration[7.1]
  def change
    add_column :bots, :quantity_per_level, :decimal, precision: 20, scale: 8
  end
end
