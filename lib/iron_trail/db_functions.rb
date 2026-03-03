# frozen_string_literal: true

module IronTrail
  class DbFunctions
    attr_reader :connection

    def initialize(connection)
      @connection = connection
    end

    # Creates the SQL functions/procedures in the DB. It will not create
    # any triggers.
    def install_functions
      # Install the helper function first
      sql = irontrail_merged_keys_function
      execute_multi_statement(sql)

      # Install the main stored procedure
      sql = irontrail_log_row_function
      execute_multi_statement(sql)
    end

    def irontrail_log_row_function
      path = File.expand_path('irontrail_log_row_function.sql', __dir__)
      File.read(path)
    end

    def irontrail_merged_keys_function
      path = File.expand_path('irontrail_merged_keys_function.sql', __dir__)
      File.read(path)
    end

    # Queries the database information schema and returns an array with all
    # table names that have the "iron_trail_log_changes" triggers enabled.
    #
    # This effectively returns all tables which are currently being tracked
    # by IronTrail.
    def collect_tracked_table_names
      db_name = current_database
      stmt = <<~SQL
        SELECT DISTINCT `EVENT_OBJECT_TABLE` AS `table_name`
        FROM `information_schema`.`TRIGGERS`
        WHERE `TRIGGER_NAME` LIKE 'iron_trail_%'
          AND `EVENT_OBJECT_SCHEMA` = #{connection.quote(db_name)}
        ORDER BY `table_name` ASC
      SQL

      connection.select_values(stmt)
    end

    def function_present?(function: 'irontrail_log_row', schema: nil)
      db_name = schema || current_database
      stmt = <<~SQL
        SELECT 1 FROM `information_schema`.`ROUTINES`
        WHERE `ROUTINE_NAME` = #{connection.quote(function)}
          AND `ROUTINE_SCHEMA` = #{connection.quote(db_name)}
        LIMIT 1
      SQL

      connection.select_values(stmt).any?
    end

    def remove_functions(cascade:)
      connection.execute("DROP PROCEDURE IF EXISTS irontrail_log_row")
      connection.execute("DROP FUNCTION IF EXISTS irontrail_merged_keys")
    end

    # Counting rows in MySQL can be slow for large tables with InnoDB.
    def trigger_errors_count
      stmt = 'SELECT COUNT(*) AS c FROM `irontrail_trigger_errors`'
      connection.select_value(stmt).to_i
    end

    # This returns metrics intended to be used for monitoring.
    def trigger_errors_metrics
      stmt = 'SELECT MAX(created_at) AS maxdate, MAX(id) AS maxid FROM `irontrail_trigger_errors`'
      res = connection.select_one(stmt)

      {
        max_created_at: (res && res['maxdate'] && res['maxdate'].to_i) || 0,
        max_id: (res && res['maxid']) || 0,
      }
    end

    def collect_all_tables(schema: nil)
      db_name = schema || current_database
      stmt = <<~SQL
        SELECT `TABLE_NAME` AS `table_name`
        FROM `information_schema`.`TABLES`
        WHERE `TABLE_SCHEMA` = #{connection.quote(db_name)}
          AND `TABLE_TYPE` = 'BASE TABLE'
        ORDER BY `table_name` ASC
      SQL

      connection.select_values(stmt)
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
      quoted = connection.quote_table_name(table_name)
      connection.execute("DROP TRIGGER IF EXISTS `iron_trail_insert_#{table_name}`")
      connection.execute("DROP TRIGGER IF EXISTS `iron_trail_update_#{table_name}`")
      connection.execute("DROP TRIGGER IF EXISTS `iron_trail_delete_#{table_name}`")
    end

    def enable_tracking_for_table(table_name)
      return false if IronTrail.ignore_table?(table_name)

      quoted = connection.quote_table_name(table_name)

      # Get column info for this table to build the JSON object
      columns = connection.columns(table_name).map(&:name)

      old_json_expr = build_json_object_expr('OLD', columns)
      new_json_expr = build_json_object_expr('NEW', columns)

      has_created_at = columns.include?('created_at')
      has_updated_at = columns.include?('updated_at')

      # Detect primary key column
      pk_column = detect_primary_key(table_name)

      # INSERT trigger
      insert_sql = <<~SQL
        CREATE TRIGGER `iron_trail_insert_#{table_name}` AFTER INSERT ON #{quoted}
        FOR EACH ROW
        BEGIN
          CALL irontrail_log_row(
            'i',
            #{connection.quote(table_name)},
            CAST(NEW.`#{pk_column}` AS CHAR),
            NULL,
            #{new_json_expr},
            #{has_created_at ? 'NEW.`created_at`' : 'NULL'},
            NULL,
            NULL
          );
        END
      SQL
      connection.execute(insert_sql)

      # UPDATE trigger
      update_sql = <<~SQL
        CREATE TRIGGER `iron_trail_update_#{table_name}` AFTER UPDATE ON #{quoted}
        FOR EACH ROW
        BEGIN
          CALL irontrail_log_row(
            'u',
            #{connection.quote(table_name)},
            CAST(NEW.`#{pk_column}` AS CHAR),
            #{old_json_expr},
            #{new_json_expr},
            NULL,
            #{has_updated_at ? 'OLD.`updated_at`' : 'NULL'},
            #{has_updated_at ? 'NEW.`updated_at`' : 'NULL'}
          );
        END
      SQL
      connection.execute(update_sql)

      # DELETE trigger
      delete_sql = <<~SQL
        CREATE TRIGGER `iron_trail_delete_#{table_name}` AFTER DELETE ON #{quoted}
        FOR EACH ROW
        BEGIN
          CALL irontrail_log_row(
            'd',
            #{connection.quote(table_name)},
            CAST(OLD.`#{pk_column}` AS CHAR),
            #{old_json_expr},
            NULL,
            NULL,
            NULL,
            NULL
          );
        END
      SQL
      connection.execute(delete_sql)
    end

    private

    def current_database
      connection.select_value('SELECT DATABASE()')
    end

    def detect_primary_key(table_name)
      pk = connection.primary_key(table_name)
      pk || 'id'
    end

    def build_json_object_expr(prefix, columns)
      pairs = columns.map do |col|
        "#{connection.quote(col)}, #{prefix}.`#{col}`"
      end
      "JSON_OBJECT(#{pairs.join(', ')})"
    end

    def execute_multi_statement(sql)
      # Split on statement boundaries and execute individually
      # We need to handle the DELIMITER-like behavior for stored procs
      # The SQL files use DROP ... ; CREATE ... BEGIN ... END; pattern
      statements = split_sql_statements(sql)
      statements.each do |stmt|
        stmt = stmt.strip
        next if stmt.empty?
        connection.execute(stmt)
      end
    end

    def split_sql_statements(sql)
      # Split stored procedure / function SQL into DROP and CREATE statements.
      # The CREATE PROCEDURE/FUNCTION has nested BEGIN...END and semicolons.
      parts = []
      # Find DROP statement first (ends at first ;)
      remaining = sql.strip

      while remaining.length > 0
        if remaining =~ /\A(DROP\s+(?:PROCEDURE|FUNCTION)\s+IF\s+EXISTS\s+\w+)\s*;/i
          parts << $1
          remaining = remaining[($~.end(0))..].strip
        elsif remaining =~ /\ACREATE\s+(PROCEDURE|FUNCTION)\s+/i
          # This is a CREATE PROCEDURE/FUNCTION - find the final END;
          # We need to count BEGIN/END pairs
          depth = 0
          i = 0
          in_string = false
          string_char = nil
          found_end = nil

          while i < remaining.length
            ch = remaining[i]

            if in_string
              if ch == string_char
                # Check for escaped quote
                if i + 1 < remaining.length && remaining[i + 1] == string_char
                  i += 1
                else
                  in_string = false
                end
              end
            elsif ch == "'" || ch == '"'
              in_string = true
              string_char = ch
            else
              # Check for BEGIN keyword
              word_at = remaining[i..]
              if word_at =~ /\ABEGIN\b/i
                depth += 1
              elsif word_at =~ /\AEND\s*;/i && depth > 0
                depth -= 1
                if depth == 0
                  end_pos = i + word_at.match(/\AEND\s*;/i)[0].length
                  parts << remaining[0...end_pos].sub(/;\s*\z/, '')
                  remaining = remaining[end_pos..].strip
                  found_end = true
                  break
                end
              end
            end
            i += 1
          end

          unless found_end
            parts << remaining
            remaining = ''
          end
        else
          # Generic statement
          semi = remaining.index(';')
          if semi
            parts << remaining[0...semi]
            remaining = remaining[(semi + 1)..].strip
          else
            parts << remaining
            remaining = ''
          end
        end
      end

      parts
    end
  end
end
