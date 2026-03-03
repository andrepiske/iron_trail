# frozen_string_literal: true

class SetupTestDb < ::ActiveRecord::Migration::Current
  def up
    create_table :people, id: :bigint, force: true do |t|
      t.string :first_name, null: false
      t.string :last_name, null: false
      t.string :favorite_planet
      t.bigint :converted_by_pill_id
      t.bigint :owns_the_hotel
      t.datetime :first_acquired_guitar_at, precision: 6
    end

    # For guitars, we use a VARCHAR(36) primary key to simulate UUID
    create_table :guitars, id: false, force: true do |t|
      t.string :id, limit: 36, null: false, primary_key: true
      t.bigint :person_id, null: false
      t.string :description, null: false
    end

    create_table :hotels, id: :bigint, force: true do |t|
      t.string :name
      t.datetime :hotel_time, precision: 6
      t.datetime :time_in_japan, precision: 6
      t.json :room_map
    end

    create_table :guitar_parts, id: :bigint, force: true do |t|
      t.string :guitar_id, limit: 36
      t.string :name

      t.timestamps precision: 6
    end

    create_table :matrix_pills, id: :bigint, force: true do |t|
      t.string :type, null: false
      t.integer :pill_size
    end
  end

  def down
    # no need to implement this
    raise ActiveRecord::IrreversibleMigration
  end
end
