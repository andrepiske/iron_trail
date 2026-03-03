# frozen_string_literal: true

module IronTrail
  module ChangeModelConcern
    extend ::ActiveSupport::Concern

    def insert_operation? = (operation == 'i')
    def update_operation? = (operation == 'u')
    def delete_operation? = (operation == 'd')

    def reify
      Reifier.reify(self)
    end

    # We don't store the class name of the object, but we do store the rec_table.
    # This method infers the class name from the rec_table and also the "type"
    # attribute in the stored object in case it's a rails STI class.
    #
    # It returns the class instance. Raises an error in case the class couldn't
    # be inferred.
    def rec_class
      source_attributes = (delete_operation? ? rec_old : rec_new)
      Reifier.model_from_table_name(rec_table, source_attributes.fetch('type', nil))
    end

    # This mimics the method with the same name available in the papertrail gem.
    # It is an extended rec_delta, where attributes values are properly deserialized
    # as rails' ActiveRecord would do.
    #
    # For instance, timestamps are serialized as strings in JSON, so rec_delta
    # would return strings for timestamps. Using this method, it'd return a proper
    # timestamp deserialized from the string.
    #
    # This method doesn't do caching and always computes the full thing. It's
    # up to the user to perform caching if wanted.
    def compute_changeset
      return nil unless update_operation?

      klass = rec_class

      HashWithIndifferentAccess.new.tap do |changes|
        rec_delta.each do |col_name, in_delta|
          type_class = klass.type_for_attribute(col_name)
          out_delta = in_delta.map { |val| type_class.deserialize(val) }

          changes[col_name] = out_delta
        end
      end
    end

    module ClassMethods
      def where_object_changes_to(args = {})
        _where_object_changes(1, args)
      end

      def where_object_changes_from(args = {})
        _where_object_changes(0, args)
      end

      # Allows filtering out updates that changed just a certain set of columns.
      # This could be useful, for instance, to filter out updates made with
      # ActiveRecord's #touch method, which changes only the updated_at column.
      # In that case, calling `.with_delta_other_than(:updated_at)` would exclude
      # such changes from the result.
      #
      # This works by inspecting whether there are any keys in the rec_delta column
      # other than the columns specified in the `columns` parameter.
      def with_delta_other_than(*columns)
        if mysql_adapter?
          with_delta_other_than_mysql(columns)
        else
          with_delta_other_than_postgres(columns)
        end
      end

      private

      def mysql_adapter?
        connection.adapter_name.downcase.include?('mysql')
      end

def with_delta_other_than_mysql(columns)
        return all if columns.empty?

        # For MySQL, we need to check if rec_delta has any keys other than the specified columns.
        # We use JSON_REMOVE to remove all the excluded columns, then check if anything remains.
        # 
        # JSON_REMOVE takes multiple path arguments. We need to build paths like '$.col1', '$.col2'
        # If all keys are removed, JSON_REMOVE returns NULL (or an empty object in some cases).
        # 
        # We want: rec_delta IS NULL (inserts/deletes) OR 
        #          JSON_REMOVE(...) is not empty (has other changes)
        
        # Build the JSON_REMOVE paths
        paths = columns.map { |col| connection.quote("$.#{col}") }
        
        if paths.empty?
          # No columns to exclude, so all records pass
          all
        else
          # Build: rec_delta IS NULL OR JSON_REMOVE(rec_delta, '$.col1', '$.col2', ...) != CAST('{}' AS JSON)
          remove_expr = "JSON_REMOVE(rec_delta, #{paths.join(', ')})"
          sql = "rec_delta IS NULL OR (#{remove_expr} IS NOT NULL AND #{remove_expr} != CAST('{}' AS JSON))"
          where(::Arel::Nodes::SqlLiteral.new(sql))
        end
      end

      def with_delta_other_than_postgres(columns)
        quoted_columns = columns.map { |col_name| connection.quote(col_name) }
        exclude_array = "ARRAY[#{quoted_columns.join(', ')}]::text[]"

        sql = "rec_delta IS NULL OR (rec_delta - #{exclude_array}) <> '{}'::jsonb"
        where(::Arel::Nodes::SqlLiteral.new(sql))
      end

      def _where_object_changes(ary_index, args)
        ary_index = Integer(ary_index)
        scope = all

        args.each do |col_name, value|
          if mysql_adapter?
            scope = _where_object_changes_mysql(scope, ary_index, col_name, value)
          else
            scope = _where_object_changes_postgres(scope, ary_index, col_name, value)
          end
        end

        scope
      end

      def _where_object_changes_mysql(scope, ary_index, col_name, value)
        # MySQL uses JSON functions for JSON queries
        # Path syntax: '$."column_name"[index]' for accessing array elements in rec_delta
        safe_col_name = col_name.to_s.gsub("'", "\\'")
        path = "$.\"#{safe_col_name}\""
        
        node = if value.nil?
          # For nil values in MySQL JSON:
          # - Key doesn't exist: JSON_EXTRACT returns SQL NULL → JSON_TYPE returns SQL NULL
          # - Key exists with JSON null: JSON_EXTRACT returns JSON null → JSON_TYPE returns 'NULL'
          # We want records where the key EXISTS AND the value at that index is JSON null
          sql = "(JSON_CONTAINS_PATH(rec_delta, 'one', '#{path}') AND JSON_TYPE(JSON_EXTRACT(rec_delta, '#{path}[#{ary_index}]')) = 'NULL')"
          ::Arel::Nodes::SqlLiteral.new(sql)
        else
          # For non-NULL values in MySQL
          sql = "JSON_UNQUOTE(JSON_EXTRACT(rec_delta, '#{path}[#{ary_index}]'))"
          ::Arel::Nodes::SqlLiteral.new(sql).eq(value.to_s)
        end

        scope.where(node)
      end

      def _where_object_changes_postgres(scope, ary_index, col_name, value)
        col_delta = "rec_delta->#{connection.quote(col_name)}"
        
        node = if value == nil
          ::Arel::Nodes::SqlLiteral.new("#{col_delta}->#{ary_index} = 'null'::jsonb")
        else
          ::Arel::Nodes::SqlLiteral.new("#{col_delta}->>#{ary_index}").eq(
            ::Arel::Nodes::BindParam.new(value.to_s)
          )
        end

        scope.where(node)
      end
    end
  end
end
