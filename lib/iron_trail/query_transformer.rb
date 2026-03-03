# frozen_string_literal: true

module IronTrail
  class QueryTransformer
    METADATA_MAX_LENGTH = 1048576 # 1 MiB

    attr_reader :transformer_proc

    def initialize
      @transformer_proc = create_query_transformer_proc
    end

    def setup_active_record
      ActiveRecord.query_transformers << @transformer_proc
    end

    private

    def create_query_transformer_proc
      proc do |query, adapter|
        if adapter.write_query?(query)
          current_metadata = IronTrail::Current.metadata

          begin
            if current_metadata.is_a?(Hash) && !current_metadata.empty?
              metadata = JSON.dump(current_metadata)

              if metadata.length > METADATA_MAX_LENGTH
                Rails.logger.warn("IronTrail metadata is longer than maximum length! #{metadata.length} > #{METADATA_MAX_LENGTH}")
              else
                safe_md = metadata.gsub("'", "\\\\'")
                ActiveRecord::Base.connection.execute("SET @irontrail_metadata = '#{safe_md}'")
              end
            else
              # Clear the session variable so stale metadata from a previous
              # write is not picked up by the trigger.
              ActiveRecord::Base.connection.execute("SET @irontrail_metadata = NULL")
            end
          rescue => e
            Rails.logger.warn("IronTrail failed to set metadata session variable: #{e.message}")
          end
        end
        query
      end
    end
  end
end
