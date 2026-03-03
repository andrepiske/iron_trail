# frozen_string_literal: true

class Guitar < ApplicationRecord
  include IronTrail::Model

  belongs_to :person
  has_many :guitar_parts

  before_create :set_uuid_id

  private

  def set_uuid_id
    self.id ||= SecureRandom.uuid
  end
end
