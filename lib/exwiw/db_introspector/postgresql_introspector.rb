# frozen_string_literal: true

module Exwiw
  module DbIntrospector
    # Reads PostgreSQL's catalog, scoped to `current_schema()` — the first
    # schema on the connection's search_path, which is the one an unqualified
    # table name in the dump resolves to.
    #
    # `information_schema` is used where it is unambiguous (tables, columns,
    # primary keys); unique indexes and foreign keys go through `pg_catalog`
    # instead. information_schema only lists what a *constraint* declares, so a
    # bare `CREATE UNIQUE INDEX` would be invisible there, and its
    # `constraint_column_usage` join multiplies the rows of a composite foreign
    # key into a cross product that cannot be grouped back.
    class PostgresqlIntrospector < Base
      # PostgreSQL data_type (information_schema's spelling) -> the
      # ActiveRecord-ish symbol DefaultMask understands. An unmapped type stays
      # nil so no mask is emitted: 'USER-DEFINED' covers every enum and
      # extension type, where the set of valid values is per-column, and
      # bytea/uuid/inet/interval have no constant that is safe to write back.
      TYPE_MAP = {
        "character" => :string,
        "character varying" => :string,
        "text" => :text,
        "smallint" => :integer,
        "integer" => :integer,
        "bigint" => :integer,
        "numeric" => :decimal,
        "decimal" => :decimal,
        "real" => :float,
        "double precision" => :float,
        "boolean" => :boolean,
        "date" => :date,
        "timestamp without time zone" => :datetime,
        "timestamp with time zone" => :datetime,
        "time without time zone" => :time,
        "time with time zone" => :time,
        "json" => :json,
        "jsonb" => :jsonb,
      }.freeze

      # An ARRAY column reports data_type 'ARRAY' and carries the element type
      # in udt_name, prefixed with an underscore (`_int4`). The element type is
      # mapped so the column is still described accurately, even though
      # DefaultMask emits no mask for an array either way.
      ARRAY_DATA_TYPE = "ARRAY"
      ELEMENT_TYPE_MAP = {
        "bpchar" => :string,
        "varchar" => :string,
        "text" => :text,
        "int2" => :integer,
        "int4" => :integer,
        "int8" => :integer,
        "numeric" => :decimal,
        "float4" => :float,
        "float8" => :float,
        "bool" => :boolean,
        "date" => :date,
        "timestamp" => :datetime,
        "timestamptz" => :datetime,
        "time" => :time,
        "timetz" => :time,
        "json" => :json,
        "jsonb" => :jsonb,
      }.freeze

      # PostgreSQL renders a stored default back as the SQL text that produced
      # it, so a plain literal arrives with its cast attached
      # (`'member'::user_role`, `0`, `true`) and a computed one as the call that
      # computes it (`now()`, `nextval('...')`). Only the literal forms are
      # recognized, and the cast is stripped: matching what a mask may be built
      # from, rather than trying to exclude every expression, keeps an
      # unfamiliar expression on the safe side of the line.
      QUOTED_LITERAL = /\A'((?:[^']|'')*)'(?:::[^']+)?\z/
      NUMERIC_LITERAL = /\A-?\d+(?:\.\d+)?\z/
      BOOLEAN_LITERAL = /\A(?:true|false)\z/i

      def table_names
        rows(<<~SQL).map { |row| row[0] }.sort
          SELECT table_name
          FROM information_schema.tables
          WHERE table_schema = current_schema() AND table_type = 'BASE TABLE'
        SQL
      end

      def primary_key(table_name)
        names = rows(<<~SQL, [table_name]).map { |row| row[0] }
          SELECT kcu.column_name
          FROM information_schema.table_constraints tc
          JOIN information_schema.key_column_usage kcu
            ON kcu.constraint_name = tc.constraint_name
           AND kcu.constraint_schema = tc.constraint_schema
           AND kcu.table_name = tc.table_name
          WHERE tc.constraint_type = 'PRIMARY KEY'
            AND tc.table_schema = current_schema()
            AND tc.table_name = $1
          ORDER BY kcu.ordinal_position
        SQL

        case names.size
        when 0 then nil
        when 1 then names.first
        else names
        end
      end

      def columns(table_name)
        sql = <<~SQL
          SELECT column_name, data_type, udt_name, character_maximum_length, column_default
          FROM information_schema.columns
          WHERE table_schema = current_schema() AND table_name = $1
          ORDER BY ordinal_position
        SQL

        rows(sql, [table_name]).map do |name, data_type, udt_name, character_maximum_length, column_default|
          array = data_type == ARRAY_DATA_TYPE
          type = array ? ELEMENT_TYPE_MAP[udt_name.to_s.delete_prefix("_")] : TYPE_MAP[data_type]
          Column.new(
            name: name,
            type: type,
            limit: character_maximum_length&.to_i,
            array: array,
            default: coerce_default(type, literal_default(column_default)),
          )
        end
      end

      def unique_column_names(table_name)
        # `attnum = ANY(indkey)` keeps an expression index out of the result on
        # its own: its entries are recorded as attnum 0, which no real column
        # has, so the index simply contributes nothing.
        rows(<<~SQL, [table_name]).map { |row| row[0] }.to_set
          SELECT att.attname
          FROM pg_index i
          JOIN pg_class rel ON rel.oid = i.indrelid
          JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
          JOIN pg_attribute att ON att.attrelid = rel.oid AND att.attnum = ANY(i.indkey)
          WHERE i.indisunique
            AND nsp.nspname = current_schema()
            AND rel.relname = $1
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
        # `conkey` lists the constrained columns in key order; unnesting it WITH
        # ORDINALITY yields the one-row-per-key-column shape build_foreign_keys
        # groups, so a composite constraint stays recognizable as one.
        build_foreign_keys(table_name, rows(<<~SQL, [table_name]))
          SELECT con.conname, att.attname, ref.relname
          FROM pg_constraint con
          JOIN pg_class rel ON rel.oid = con.conrelid
          JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
          JOIN pg_class ref ON ref.oid = con.confrelid
          JOIN unnest(con.conkey) WITH ORDINALITY AS u(attnum, ord) ON TRUE
          JOIN pg_attribute att ON att.attrelid = con.conrelid AND att.attnum = u.attnum
          WHERE con.contype = 'f'
            AND nsp.nspname = current_schema()
            AND rel.relname = $1
          ORDER BY con.conname, u.ord
        SQL
      end

      # The catalog's `column_default` as a plain literal, or nil when it is
      # absent or is an expression (see QUOTED_LITERAL and friends).
      private def literal_default(column_default)
        return nil if column_default.nil?

        if (match = QUOTED_LITERAL.match(column_default))
          # Inside a SQL string literal a quote is doubled; undouble it so the
          # mask is the value the column actually defaults to.
          return match[1].gsub("''", "'")
        end
        return column_default if column_default.match?(NUMERIC_LITERAL)
        return column_default.downcase if column_default.match?(BOOLEAN_LITERAL)

        nil
      end

      private def rows(sql, params = nil)
        params.nil? ? connection.exec(sql).values : connection.exec_params(sql, params).values
      end

      private def connection
        @connection ||= begin
          require_driver!
          PG.connect(
            host: @connection_config.host,
            port: @connection_config.port,
            user: @connection_config.user,
            password: @connection_config.password,
            dbname: @connection_config.database_name,
          )
        end
      end

      # Soft-require the driver, like MysqlClient does, so a host that only ever
      # runs the MySQL path is not forced to build the pg gem — and so the
      # failure names the gem to install instead of surfacing a bare LoadError.
      private def require_driver!
        require "pg"
      rescue LoadError
        raise LoadError,
              "exwiw needs the 'pg' gem to connect to PostgreSQL. " \
              "Add `gem \"pg\"` to your Gemfile."
      end
    end
  end
end
