# frozen_string_literal: true

module Exwiw
  module DbIntrospector
    # Reads MySQL's `information_schema`, scoped to `DATABASE()` — the database
    # the connection was opened against, which is the one the dump would run in.
    #
    # Connects through MysqlClient, the same wrapper the dump path uses, so the
    # driver choice (mysql2 or trilogy) and the "install the gem" error message
    # are shared rather than reimplemented here.
    class MysqlIntrospector < Base
      # MySQL data_type (the type without its length/precision) -> the
      # ActiveRecord-ish symbol DefaultMask understands. Anything absent maps to
      # nil, which leaves the column unmasked: binary/blob columns must not
      # receive a text mask, and enum/set/geometry/bit have no constant that is
      # valid for every table's declaration.
      TYPE_MAP = {
        "char" => :string,
        "varchar" => :string,
        "tinytext" => :text,
        "text" => :text,
        "mediumtext" => :text,
        "longtext" => :text,
        "tinyint" => :integer,
        "smallint" => :integer,
        "mediumint" => :integer,
        "int" => :integer,
        "integer" => :integer,
        "bigint" => :integer,
        "decimal" => :decimal,
        "numeric" => :decimal,
        "float" => :float,
        "double" => :float,
        "date" => :date,
        "datetime" => :datetime,
        "timestamp" => :datetime,
        "time" => :time,
        "json" => :json,
      }.freeze

      # MySQL has no boolean type: `BOOLEAN` is an alias for `TINYINT(1)`, and
      # the display width is the only trace of the distinction left in the
      # catalog. Mapping it to :boolean (as every MySQL ORM does) is what makes
      # a flag column mask to false / to its own default rather than to 0.
      BOOLEAN_COLUMN_TYPE = "tinyint(1)"

      # A default MySQL evaluates per row rather than storing as a literal.
      # `extra` carries DEFAULT_GENERATED for an expression default, but only on
      # servers new enough to support them, so the text is screened as well: a
      # function call, or a bare keyword such as CURRENT_TIMESTAMP, is not a
      # value we can mask with. A literal string that happens to contain
      # parentheses is rejected too — losing a usable default costs nothing more
      # than falling back to the per-type constant, while accepting an
      # expression would write a mask the database re-evaluates.
      EXPRESSION_DEFAULT = /[()]|\Acurrent_(?:timestamp|date|time)\z|\Alocaltime(?:stamp)?\z/i

      def table_names
        rows(<<~SQL).map { |row| row[0] }.sort
          SELECT table_name
          FROM information_schema.tables
          WHERE table_schema = DATABASE() AND table_type = 'BASE TABLE'
        SQL
      end

      def primary_key(table_name)
        names = rows(<<~SQL).map { |row| row[0] }
          SELECT column_name
          FROM information_schema.key_column_usage
          WHERE table_schema = DATABASE()
            AND table_name = #{quote(table_name)}
            AND constraint_name = 'PRIMARY'
          ORDER BY ordinal_position
        SQL

        case names.size
        when 0 then nil
        when 1 then names.first
        else names
        end
      end

      def columns(table_name)
        sql = <<~SQL
          SELECT column_name, data_type, column_type, character_maximum_length, column_default, extra
          FROM information_schema.columns
          WHERE table_schema = DATABASE() AND table_name = #{quote(table_name)}
          ORDER BY ordinal_position
        SQL

        rows(sql).map do |name, data_type, column_type, character_maximum_length, column_default, extra|
          type = column_type == BOOLEAN_COLUMN_TYPE ? :boolean : TYPE_MAP[data_type]
          Column.new(
            name: name,
            type: type,
            limit: character_maximum_length&.to_i,
            # MySQL has no array column type; a multi-valued column is JSON,
            # which is masked as JSON rather than as an array.
            array: false,
            default: coerce_default(type, literal_default(column_default, extra)),
          )
        end
      end

      def unique_column_names(table_name)
        rows(<<~SQL).map { |row| row[0] }.to_set
          SELECT DISTINCT column_name
          FROM information_schema.statistics
          WHERE table_schema = DATABASE()
            AND table_name = #{quote(table_name)}
            AND non_unique = 0
        SQL
      rescue StandardError => e
        warn_once(
          :unique_column_names,
          "exwiw: could not read the indexes of '#{table_name}' (#{e.class}); " \
          "treating every column as unique-indexed so no constant mask is emitted.",
        )
        nil
      end

      def foreign_keys(table_name)
        # `referenced_table_name IS NOT NULL` is what distinguishes a foreign
        # key's rows from the primary/unique key rows sharing this view.
        build_foreign_keys(table_name, rows(<<~SQL))
          SELECT constraint_name, column_name, referenced_table_name
          FROM information_schema.key_column_usage
          WHERE table_schema = DATABASE()
            AND table_name = #{quote(table_name)}
            AND referenced_table_name IS NOT NULL
          ORDER BY constraint_name, ordinal_position
        SQL
      end

      # The catalog's `column_default` as a plain literal, or nil when it is
      # absent or is an expression (see EXPRESSION_DEFAULT).
      private def literal_default(column_default, extra)
        return nil if column_default.nil?
        return nil if extra.to_s.upcase.include?("DEFAULT_GENERATED")
        return nil if column_default.match?(EXPRESSION_DEFAULT)

        column_default
      end

      private def rows(sql)
        connection.query(sql).rows
      end

      # Table names reaching this class come from `table_names` (the catalog
      # itself), so they cannot carry an injection; quoting is defensive, for
      # the day a caller passes a name from elsewhere.
      private def quote(value)
        "'#{value.to_s.gsub("\\", "\\\\\\\\").gsub("'", "''")}'"
      end

      private def connection
        @connection ||= Adapter::MysqlClient.new(@connection_config)
      end
    end
  end
end
