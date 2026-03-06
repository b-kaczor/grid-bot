class CreateExchangeAccounts < ActiveRecord::Migration[7.1]
  def change
    create_table :exchange_accounts do |t|
      t.string :name, null: false
      t.string :exchange, null: false, default: "bybit"
      t.text :api_key_ciphertext, null: false
      t.text :api_secret_ciphertext, null: false
      t.string :environment, null: false, default: "testnet"
      t.timestamps
    end

    add_index :exchange_accounts, %i[exchange environment name], unique: true
  end
end
