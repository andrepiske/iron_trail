# frozen_string_literal: true

RSpec.describe Hotel do
  before do
    # Insert with explicit timestamps (MySQL doesn't have dollar-quoting)
    room_map_json = '{"floors": ["Floor 1", "Floor 2", "Gym"], "rooms": {"floor_1_room_22": "User:1234", "floor_2_room_01": "Reserved"}}'

    conn = ActiveRecord::Base.connection
    conn.execute("INSERT INTO hotels (id, name, hotel_time, time_in_japan, room_map) VALUES (100, 'Wonky', '2023-04-25 20:22:54.833', '2023-07-23 12:22:55.021', '#{conn.quote_string(room_map_json)}')")
    conn.execute("UPDATE hotels SET hotel_time='2023-10-12 14:18:29.422', time_in_japan='2023-10-13 15:16:15.021' WHERE id=100")
  end

  let(:hotel) { Hotel.find(100) }
  let(:ordered_trails) { hotel.iron_trails.order(id: :asc) }

  it 'is sane' do
    expect(ordered_trails).to have_attributes(count: 2)
  end

  describe 'ChangeModelConcern#compute_changeset' do
    before { hotel }

    let(:trail) { ordered_trails[1] }

    subject(:changeset) { trail.compute_changeset }

    it 'has the right time in Japan' do
      expect(changeset['time_in_japan'][0]).to eq(Time.utc(2023, 7, 23, 12, 22, 55, 21000))
      expect(changeset['time_in_japan'][1]).to eq(Time.utc(2023, 10, 13, 15, 16, 15, 21000))
    end

    it 'has the right time at the Hotel' do
      expect(changeset['hotel_time'][0]).to eq(Time.utc(2023, 4, 25, 20, 22, 54, 833000))
      expect(changeset['hotel_time'][1]).to eq(Time.utc(2023, 10, 12, 14, 18, 29, 422000))
    end
  end

  describe 'timestamp column' do
    before { hotel }

    it 'deserializes correctly' do
      original_hotel = ordered_trails.first.reify

      original_time_utc = Time.utc(2023, 4, 25, 20, 22, 54, 833000)
      current_time_utc = Time.utc(2023, 10, 12, 14, 18, 29, 422000)

      expect(original_hotel.hotel_time).to eq(original_time_utc)
      expect(hotel.hotel_time).to eq(current_time_utc)
    end
  end

  describe 'timestamp column (time_in_japan)' do
    it 'deserializes correctly' do
      original_hotel = ordered_trails.first.reify

      original_japan_time = Time.utc(2023, 7, 23, 12, 22, 55, 21000)
      current_japan_time = Time.utc(2023, 10, 13, 15, 16, 15, 21000)

      expect(original_hotel.time_in_japan).to eq(original_japan_time)
      expect(hotel.time_in_japan).to eq(current_japan_time)
    end
  end

  describe 'reifying JSON columns' do
    before do
      conn = ActiveRecord::Base.connection
      new_map = '{"floors": ["Floor 1", "Floor 2", "Gym"], "rooms": {"floor_1_room_22": "User:9001", "floor_2_room_03": "User:1234", "floor_2_room_01": "User:987654321"}}'
      conn.execute("UPDATE hotels SET room_map='#{conn.quote_string(new_map)}' WHERE id=100")
      conn.execute("UPDATE hotels SET room_map=CAST('null' AS JSON) WHERE id=100")
    end

    it 'correctly serializes/deserializes JSON columns' do
      expect(hotel.iron_trails.count).to eq(4)

      expect(ordered_trails[-2].reify.room_map).to eq(JSON.parse(<<~JSON))
        {
          "floors": ["Floor 1", "Floor 2", "Gym"],
          "rooms": {
            "floor_1_room_22": "User:9001",
            "floor_2_room_03": "User:1234",
            "floor_2_room_01": "User:987654321"
          }
        }
      JSON

      expect(ordered_trails[-1].reify.room_map).to be(nil)
    end
  end

  context 'when the hotel has an owner' do
    let(:hotel_owner) { Person.create!(first_name: 'Ada', last_name: 'Lacelove', owns_the_hotel: 100) }

    before do
      hotel_owner

      hotel.reload
    end

    context 'when there was a owner_person column in the old times' do
      let(:past_owner_person_value) { nil }
      subject(:reify_it) { hotel.iron_trails.inserts.first.reify }

      before do
        trail = hotel.iron_trails.inserts.first
        trail.rec_new['owner_person'] = past_owner_person_value
        trail.save!

        hotel.reload
      end

      it 'does not reify a non-attribute' do
        expect(hotel.owner_person).to eq(hotel_owner)

        reify_it

        expect(Person.find_by(id: hotel_owner.id)).to eq(hotel_owner)
      end

      it 'reifies owner_person as a ghost attribute' do
        reify_it

        expect(reify_it.irontrail_reified_ghost_attributes).to match({
          'owner_person' => nil
        })
      end

      describe 'non-transformation of ghost attributes' do
        subject { reify_it.irontrail_reified_ghost_attributes['owner_person'] }

        let(:past_owner_person_value) { '2024-10-27 23:56:10.388451 +5:00' }

        it { eq(past_owner_person_value) }
      end
    end
  end
end
