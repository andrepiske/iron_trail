# frozen_string_literal: true

class Guitar < ApplicationRecord
  include IronTrail::Model

  self.primary_key = 'id'

  belongs_to :person
  has_many :guitar_parts

  before_create :generate_uuid, if: -> { id.blank? }

  private

  def generate_uuid
    self.id = SecureRandom.uuid
  end
end
