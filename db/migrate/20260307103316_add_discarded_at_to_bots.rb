# frozen_string_literal: true

class AddDiscardedAtToBots < ActiveRecord::Migration[7.1]
  def change
    add_column :bots, :discarded_at, :datetime
    add_index :bots, :discarded_at
  end
end
