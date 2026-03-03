# frozen_string_literal: true

class SetupTestDb < ::ActiveRecord::Migration::Current
  def up
    if connection.adapter_name.downcase.include?('mysql')
      setup_mysql_tables
    else
      setup_postgres_tables
    end
  end

  def setup_postgres_tables
    create_table :people, id: :bigserial, force: true do |t|
      t.string :first_name, null: false
      t.string :last_name, null: false
      t.string :favorite_planet
      t.bigint :converted_by_pill_id
      t.bigint :owns_the_hotel
      t.timestamp :first_acquired_guitar_at
    end

    create_table :guitars, id: :uuid, force: true do |t|
      t.bigint :person_id, null: false
      t.string :description, null: false
    end

    create_table :hotels, id: :bigserial, force: true do |t|
      t.string :name
      t.timestamp :hotel_time
      t.timestamptz :time_in_japan
      t.jsonb :room_map
    end

    create_table :guitar_parts, id: :bigserial, force: true do |t|
      t.uuid :guitar_id
      t.string :name

      t.timestamps
    end

    create_table :matrix_pills, id: :bigserial, force: true do |t|
      t.string :type, null: false
      t.integer :pill_size
    end
  end

  def setup_mysql_tables
    create_table :people, id: :bigint, auto_increment: true, force: true do |t|
      t.string :first_name, null: false
      t.string :last_name, null: false
      t.string :favorite_planet
      t.bigint :converted_by_pill_id
      t.bigint :owns_the_hotel
      t.timestamp :first_acquired_guitar_at
    end

    # MySQL doesn't have native UUID type, use string with UUID() default
    create_table :guitars, id: false, force: true do |t|
      t.string :id, limit: 36, null: false, primary_key: true
      t.bigint :person_id, null: false
      t.string :description, null: false
    end
    execute("ALTER TABLE guitars MODIFY COLUMN id VARCHAR(36) DEFAULT (UUID()) NOT NULL")

    create_table :hotels, id: :bigint, auto_increment: true, force: true do |t|
      t.string :name
      t.timestamp :hotel_time
      t.timestamp :time_in_japan
      t.json :room_map
    end

    create_table :guitar_parts, id: :bigint, auto_increment: true, force: true do |t|
      t.string :guitar_id, limit: 36
      t.string :name

      t.timestamps
    end

    create_table :matrix_pills, id: :bigint, auto_increment: true, force: true do |t|
      t.string :type, null: false
      t.integer :pill_size
    end
  end

  def down
    # no need to implement this
    raise ActiveRecord::IrreversibleMigration
  end
end
