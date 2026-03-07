# frozen_string_literal: true

class AddPairedOrderIdToOrders < ActiveRecord::Migration[7.1]
  def change
    add_reference :orders, :paired_order, null: true, foreign_key: { to_table: :orders }
  end
end
