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
      # MySQL version using JSON functions.
      def with_delta_other_than(*columns)
        if columns.empty?
          where(::Arel::Nodes::SqlLiteral.new("rec_delta IS NULL OR JSON_LENGTH(rec_delta) > 0"))
        else
          # Build a condition: after removing listed keys from rec_delta, check if any remain
          removal_expr = 'rec_delta'
          columns.each do |col_name|
            removal_expr = "JSON_REMOVE(#{removal_expr}, #{connection.quote("$.#{col_name}")})"
          end
          sql = "rec_delta IS NULL OR (#{removal_expr} IS NOT NULL AND JSON_LENGTH(#{removal_expr}) > 0)"
          where(::Arel::Nodes::SqlLiteral.new(sql))
        end
      end

      private

      def _where_object_changes(ary_index, args)
        ary_index = Integer(ary_index)
        scope = all

        args.each do |col_name, value|
          json_path = "$.#{col_name}[#{ary_index}]"

          node = if value == nil
            ::Arel::Nodes::SqlLiteral.new(
              "JSON_EXTRACT(rec_delta, #{connection.quote(json_path)}) = CAST('null' AS JSON)"
            )
          else
            ::Arel::Nodes::SqlLiteral.new(
              "JSON_UNQUOTE(JSON_EXTRACT(rec_delta, #{connection.quote(json_path)})) = #{connection.quote(value.to_s)}"
            )
          end

          scope.where!(node)
        end

        scope
      end
    end
  end
end
