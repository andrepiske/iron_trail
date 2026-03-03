# frozen_string_literal: true

if ENV['RAILS_ENV'] == 'production'
  raise 'This file should not be required in production. ' \
    'Change the RAILS_ENV env var temporarily to override this.'
end

require 'iron_trail'

module IronTrail
  module Testing
    module InstanceMethods
      def irontrail_set_actor(actor)
        if actor.nil?
          IronTrail::Current.metadata.delete(:_actor_type)
          IronTrail::Current.metadata.delete(:_actor_id)
        else
          IronTrail::Current.merge_metadata([], {
            _actor_type: actor.class.name,
            _actor_id: actor.id
          })
        end
      end
    end

    class << self
      attr_accessor :enabled

      def enable!
        DbFunctions.new(ActiveRecord::Base.connection).install_functions
        # Re-create all triggers to ensure they are pointing to the real procedure
        db_fun = DbFunctions.new(ActiveRecord::Base.connection)
        db_fun.collect_tracked_table_names.each do |table_name|
          db_fun.disable_tracking_for_table(table_name)
          db_fun.enable_tracking_for_table(table_name)
        end
        @enabled = true
      end

      def disable!
        # We "disable" it by replacing the stored procedure with a no-op one.
        conn = ActiveRecord::Base.connection
        conn.execute("DROP PROCEDURE IF EXISTS irontrail_log_row")
        conn.execute(<<~SQL)
          CREATE PROCEDURE irontrail_log_row(
            IN p_operation CHAR(1),
            IN p_table_name VARCHAR(255),
            IN p_rec_id TEXT,
            IN p_old_obj JSON,
            IN p_new_obj JSON,
            IN p_created_at_val DATETIME(6),
            IN p_updated_at_old DATETIME(6),
            IN p_updated_at_new DATETIME(6)
          )
          BEGIN
          END
        SQL
        @enabled = false
      end

      def with_iron_trail(want_enabled:, &block)
        was_enabled = IronTrail::Testing.enabled

        if want_enabled
          ::IronTrail::Testing.enable! unless was_enabled
        else
          ::IronTrail::Testing.disable! if was_enabled
        end

        block.call
      ensure
        if want_enabled && !was_enabled
          ::IronTrail::Testing.disable!
        elsif !want_enabled && was_enabled
          ::IronTrail::Testing.enable!
        end
      end
    end
  end
end

RSpec.configure do |config|
  config.include ::IronTrail::Testing::InstanceMethods

  config.around(:each, iron_trail: true) do |example|
    IronTrail::Testing.with_iron_trail(want_enabled: true) { example.run }
  end

  config.around(:each, iron_trail: false) do |example|
    raise "Using iron_trail: false does not do what you might think it does. To disable iron_trail, " \
      "use IronTrail::Testing.with_iron_trail(want_enabled: false) { ... } instead."
  end

  config.before(:each) do
    IronTrail::Current.reset
  end
end
