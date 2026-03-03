# frozen_string_literal: true

module IronTrail
  class DbFunctions
    attr_reader :connection

    def initialize(connection)
      @connection = connection
    end

    def postgresql?
      connection.adapter_name.downcase.include?('postgresql')
    end

    def mysql?
      connection.adapter_name.downcase.include?('mysql')
    end

    # Creates the SQL functions in the DB. It will not run the function or create
    # any triggers.
    def install_functions
      if postgresql?
        sql = irontrail_log_row_function_postgres
        connection.execute(sql)
      elsif mysql?
        # MySQL requires each procedure to be executed separately
        connection.execute(irontrail_log_row_procedure_mysql_insert)
        connection.execute(irontrail_log_row_procedure_mysql_delete)
        connection.execute(irontrail_log_row_procedure_mysql_update)
      else
        raise "Unsupported database adapter: #{connection.adapter_name}"
      end
    end

    def irontrail_log_row_function_postgres
      path = File.expand_path('irontrail_log_row_function.sql', __dir__)
      File.read(path)
    end

    def irontrail_log_row_procedure_mysql_insert
      path = File.expand_path('irontrail_log_row_procedure_mysql_insert.sql', __dir__)
      File.read(path)
    end

    def irontrail_log_row_procedure_mysql_delete
      path = File.expand_path('irontrail_log_row_procedure_mysql_delete.sql', __dir__)
      File.read(path)
    end

    def irontrail_log_row_procedure_mysql_update
      path = File.expand_path('irontrail_log_row_procedure_mysql_update.sql', __dir__)
      File.read(path)
    end

    # Queries the database information schema and returns an array with all
    # table names that have the "iron_trail_log_changes" trigger enabled.
    #
    # This effectively returns all tables which are currently being tracked
    # by IronTrail.
    def collect_tracked_table_names
      if postgresql?
        collect_tracked_table_names_postgres
      elsif mysql?
        collect_tracked_table_names_mysql
      end
    end

    def collect_tracked_table_names_postgres
      stmt = <<~SQL
        SELECT DISTINCT("event_object_table") AS "table"
        FROM "information_schema"."triggers"
        WHERE "trigger_name"='iron_trail_log_changes' AND "event_object_schema"='public'
        ORDER BY "table" ASC;
      SQL

      connection.execute(stmt).map { |row| row['table'] }
    end

    def collect_tracked_table_names_mysql
      stmt = <<~SQL
        SELECT DISTINCT EVENT_OBJECT_TABLE
        FROM information_schema.triggers
        WHERE TRIGGER_NAME LIKE 'iron_trail_log_changes_%_insert'
        AND TRIGGER_SCHEMA = DATABASE()
        ORDER BY EVENT_OBJECT_TABLE ASC;
      SQL

      connection.execute(stmt).map { |row| row[0] }
    end

    def function_present?(function: 'irontrail_log_row', schema: 'public')
      if postgresql?
        function_present_postgres?(function: function, schema: schema)
      elsif mysql?
        function_present_mysql?
      end
    end

    def function_present_postgres?(function:, schema:)
      stmt = <<~SQL
        SELECT 1 FROM "pg_proc" p
        INNER JOIN "pg_namespace" ns
        ON (ns.oid = p.pronamespace)
        WHERE p."proname"=#{connection.quote(function)}
          AND ns."nspname"=#{connection.quote(schema)}
        LIMIT 1;
      SQL

      connection.execute(stmt).to_a.count > 0
    end

    def function_present_mysql?
      stmt = <<~SQL
        SELECT 1 FROM information_schema.routines
        WHERE routine_schema = DATABASE()
        AND routine_name = 'irontrail_log_row_insert'
        LIMIT 1;
      SQL

      connection.execute(stmt).to_a.count > 0
    end

    def remove_functions(cascade:)
      if postgresql?
        query = +"DROP FUNCTION IF EXISTS irontrail_log_row"
        query << " CASCADE" if cascade
        connection.execute(query)
      elsif mysql?
        connection.execute("DROP PROCEDURE IF EXISTS irontrail_log_row_insert")
        connection.execute("DROP PROCEDURE IF EXISTS irontrail_log_row_update")
        connection.execute("DROP PROCEDURE IF EXISTS irontrail_log_row_delete")
      end
    end

    # Counting rows in Postgres is known to be a slow operation for large tables.
    # Because of this, avoid using this for monitoring new errors. Instead,
    # use the trigger_errors_metrics method.
    def trigger_errors_count
      table_name = mysql? ? 'irontrail_trigger_errors' : '"irontrail_trigger_errors"'
      stmt = "SELECT COUNT(*) AS c FROM #{table_name}"
      result = connection.execute(stmt)
      if mysql?
        result.first[0].to_i
      else
        result.first['c'].to_i
      end
    end

    # This returns metrics intended to be used for monitoring. One can send
    # these values to something like a Prometheus deployment and add monitoring
    # on top of it.
    # It should be much faster to run than trigger_errors_count.
    #
    # If the irontrail_trigger_errors table is empty, the resulting values
    # will all be zero and never nil. This is so that data in a monitoring setup
    # can tell apart a failure from a no-data scenario.
    def trigger_errors_metrics
      table_name = mysql? ? 'irontrail_trigger_errors' : '"irontrail_trigger_errors"'
      stmt = "SELECT MAX(created_at) maxdate, MAX(id) AS maxid FROM #{table_name}"
      res = connection.execute(stmt).first

      {
        max_created_at: (res && res[0] && res[0].to_i) || 0,
        max_id: (res && res[1]) || 0,
      }
    end

    def collect_all_tables(schema: 'public')
      if postgresql?
        collect_all_tables_postgres(schema: schema)
      elsif mysql?
        collect_all_tables_mysql
      end
    end

    def collect_all_tables_postgres(schema:)
      # query pg_class rather than information schema because this way
      # we can get only regular tables and ignore partitions.
      stmt = <<~SQL
        SELECT c.relname AS "table"
        FROM "pg_class" c INNER JOIN "pg_namespace" ns
        ON (ns.oid = c.relnamespace)
        WHERE ns.nspname=#{connection.quote(schema)}
          AND c.relkind IN ('r', 'p')
          AND NOT c.relispartition
        ORDER BY "table" ASC;
      SQL

      connection.execute(stmt).map { |row| row['table'] }
    end

    def collect_all_tables_mysql
      stmt = <<~SQL
        SELECT TABLE_NAME
        FROM information_schema.tables
        WHERE table_schema = DATABASE()
        AND table_type = 'BASE TABLE'
        ORDER BY TABLE_NAME ASC;
      SQL

      connection.execute(stmt).map { |row| row[0] }
    end

    def enable_for_all_missing_tables
      collect_tables_tracking_status[:missing].each do |table_name|
        enable_tracking_for_table(table_name)
      end
    end

    def disable_for_all_ignored_tables
      affected_tables = collect_tracked_table_names & (
        OWN_TABLES + (IronTrail.config.ignored_tables || [])
      )

      affected_tables.each do |table_name|
        disable_tracking_for_table(table_name)
      end

      affected_tables
    end

    def collect_tables_tracking_status
      ignored_tables = OWN_TABLES + (IronTrail.config.ignored_tables || [])

      all_tables = collect_all_tables - ignored_tables
      tracked_tables = collect_tracked_table_names - ignored_tables

      {
        tracked: tracked_tables,
        missing: all_tables - tracked_tables
      }
    end

    def disable_tracking_for_table(table_name)
      # Note: will disable even if table is ignored as this allows
      # one to fix ignored tables mnore easily. Since the table is already
      # ignored, it is an expected destructive operation.

      if postgresql?
        stmt = <<~SQL
          DROP TRIGGER IF EXISTS "iron_trail_log_changes" ON
          #{connection.quote_table_name(table_name)}
        SQL

        connection.execute(stmt)
      elsif mysql?
        # MySQL has separate triggers for each operation, named per table
        %w[insert update delete].each do |operation|
          connection.execute("DROP TRIGGER IF EXISTS iron_trail_log_changes_#{table_name}_#{operation}")
        end
      end
    end

    def enable_tracking_for_table(table_name)
      return false if IronTrail.ignore_table?(table_name)

      if postgresql?
        enable_tracking_for_table_postgres(table_name)
      elsif mysql?
        enable_tracking_for_table_mysql(table_name)
      end
    end

    def enable_tracking_for_table_postgres(table_name)
      stmt = <<~SQL
        CREATE TRIGGER "iron_trail_log_changes" AFTER INSERT OR UPDATE OR DELETE ON
        #{connection.quote_table_name(table_name)}
        FOR EACH ROW EXECUTE FUNCTION irontrail_log_row();
      SQL

      connection.execute(stmt)
    end

    def enable_tracking_for_table_mysql(table_name)
      quoted_table = connection.quote_table_name(table_name)
      
      # Drop existing triggers first (if any) - trigger names must include table name to be unique
      %w[insert update delete].each do |operation|
        connection.execute("DROP TRIGGER IF EXISTS iron_trail_log_changes_#{table_name}_#{operation}")
      end
      
      # Create INSERT trigger
      insert_trigger = <<~SQL
        CREATE TRIGGER iron_trail_log_changes_#{table_name}_insert
        AFTER INSERT ON #{quoted_table}
        FOR EACH ROW
        BEGIN
          CALL irontrail_log_row_insert(
            '#{table_name}',
            CAST(NEW.id AS CHAR),
            JSON_OBJECT(
              #{mysql_table_columns(table_name).map { |col| "'#{col}', NEW.#{connection.quote_column_name(col)}" }.join(', ')}
            )
          );
        END;
      SQL
      
      # Create UPDATE trigger
      update_trigger = <<~SQL
        CREATE TRIGGER iron_trail_log_changes_#{table_name}_update
        AFTER UPDATE ON #{quoted_table}
        FOR EACH ROW
        BEGIN
          CALL irontrail_log_row_update(
            '#{table_name}',
            CAST(NEW.id AS CHAR),
            JSON_OBJECT(
              #{mysql_table_columns(table_name).map { |col| "'#{col}', OLD.#{connection.quote_column_name(col)}" }.join(', ')}
            ),
            JSON_OBJECT(
              #{mysql_table_columns(table_name).map { |col| "'#{col}', NEW.#{connection.quote_column_name(col)}" }.join(', ')}
            )
          );
        END;
      SQL
      
      # Create DELETE trigger
      delete_trigger = <<~SQL
        CREATE TRIGGER iron_trail_log_changes_#{table_name}_delete
        AFTER DELETE ON #{quoted_table}
        FOR EACH ROW
        BEGIN
          CALL irontrail_log_row_delete(
            '#{table_name}',
            CAST(OLD.id AS CHAR),
            JSON_OBJECT(
              #{mysql_table_columns(table_name).map { |col| "'#{col}', OLD.#{connection.quote_column_name(col)}" }.join(', ')}
            )
          );
        END;
      SQL

      connection.execute(insert_trigger)
      connection.execute(update_trigger)
      connection.execute(delete_trigger)
    end

    def mysql_table_columns(table_name)
      stmt = <<~SQL
        SELECT COLUMN_NAME
        FROM information_schema.columns
        WHERE table_schema = DATABASE()
        AND table_name = '#{table_name}';
      SQL
      
      connection.execute(stmt).map { |row| row[0] }
    end
  end
end
