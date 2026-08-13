# frozen_string_literal: true

require "set"

module Exwiw
  # Reads a database's structure — tables, primary keys, columns, unique
  # indexes, foreign keys — straight from its catalog, with no application code
  # in the process.
  #
  # This is what lets a non-Ruby application keep an exwiw schema config: the
  # ActiveRecord generator needs the app's models loaded in memory, which only
  # its own runtime can do, while the database schema is a description every
  # application shares regardless of the language it is written in. What is
  # lost by reading the database instead of the models is relations that exist
  # only in application code (no foreign-key constraint backs them) — which is
  # why DbSchemaGenerator only ever *adds* belongs_tos and never rewrites the
  # ones already in the config.
  #
  # Everything is scoped to the connection's current database/schema (MySQL:
  # `DATABASE()`, PostgreSQL: `current_schema()`), i.e. exactly the objects the
  # extraction itself would see through the same connection. There is no
  # multi-database grouping equivalent to the ActiveRecord generator's: a
  # connection points at one database, so one run generates one config
  # directory, and a second database is a second run.
  module DbIntrospector
    # The adapters that can be introspected. sqlite is excluded because its
    # catalog (PRAGMA-based) is a different shape entirely, and mongodb has no
    # fixed schema to read — MongoidSchemaGenerator covers that case from the
    # application side.
    SUPPORTED_ADAPTERS = %w[mysql postgresql].freeze

    # One column of a table, in the vocabulary DefaultMask.for speaks:
    #
    # - `type` is an ActiveRecord-ish symbol (:string, :integer, ...) or nil
    #   when the database type has no equivalent there. nil is deliberate and
    #   safe: DefaultMask emits no mask for a type it does not recognize, so an
    #   exotic column is exported unmasked-but-flagged rather than masked with a
    #   value it cannot hold.
    # - `limit` is the character length for text-ish columns, else nil.
    # - `array` marks a PostgreSQL ARRAY column, where no scalar mask fits.
    # - `default` is the column's default as a Ruby scalar, or nil when it is
    #   absent or is an expression the database evaluates per row.
    Column = Data.define(:name, :type, :limit, :array, :default)

    # Build the introspector for a connection. Takes the same ConnectionConfig
    # the adapters do, so the CLI can hand over exactly what it already parsed.
    def self.build(connection_config)
      case Adapter.normalize_name(connection_config.adapter)
      when "mysql" then MysqlIntrospector.new(connection_config)
      when "postgresql" then PostgresqlIntrospector.new(connection_config)
      else
        raise ArgumentError,
              "Schema generation from a database connection supports " \
              "#{SUPPORTED_ADAPTERS.join(' / ')} only, got #{connection_config.adapter.inspect}."
      end
    end

    class Base
      def initialize(connection_config)
        @connection_config = connection_config
      end

      # Sorted names of the tables in the current database/schema. Views are
      # excluded: they hold no rows of their own, so exporting one would
      # duplicate data already covered by its underlying tables (and the
      # restore would fail against a target where the same view exists).
      def table_names
        raise NotImplementedError
      end

      # The table's primary key as a String, an Array for a composite key, or
      # nil when the table has none. The three cases are what the generator
      # branches on, so they are kept distinct rather than normalized.
      def primary_key(_table_name)
        raise NotImplementedError
      end

      # The table's columns as Column structs, in ordinal_position order — the
      # order the config lists them in, which mirrors what a `SELECT *` returns.
      def columns(_table_name)
        raise NotImplementedError
      end

      # The names of columns covered by any unique index or constraint, or nil
      # when the catalog could not be read. Callers treat nil as "assume every
      # column is unique", since masking a unique column with a constant makes
      # every row collide on restore. The primary key is included; it is
      # unique, and the generator never masks it anyway.
      def unique_column_names(_table_name)
        raise NotImplementedError
      end

      # The table's single-column foreign keys as sorted
      # `{ table_name:, foreign_key: }` hashes — the belongs_to shape. Composite
      # foreign keys are skipped with a warning: exwiw joins on one column, so a
      # multi-column edge cannot be expressed, and silently emitting one of its
      # columns would produce a join that is quietly wrong.
      def foreign_keys(_table_name)
        raise NotImplementedError
      end

      # Turn the plain default literal the catalog reported into the Ruby
      # scalar DefaultMask can use as a mask value.
      #
      # Deliberately narrow. A default only earns its place as a mask because it
      # is a value the column provably holds and the application treats as
      # neutral; a value we had to guess at loses both properties. So a type
      # whose text form we cannot map back with certainty yields nil and the
      # per-type constant is used instead. JSON is excluded for that reason:
      # DefaultMask re-serializes a JSON default with #to_json, which would turn
      # the catalog's already-serialized text into a doubly-encoded string.
      private def coerce_default(type, literal)
        return nil if literal.nil?

        case type
        when :integer then Integer(literal, exception: false)
        when :decimal, :float then Float(literal, exception: false)
        when :boolean then BOOLEAN_DEFAULTS[literal.downcase]
        when :string, :text, :date, :datetime, :time then literal
        end
      end

      # How the two databases spell a boolean default in the catalog: MySQL
      # stores a TINYINT(1) default as "1"/"0", PostgreSQL a boolean one as
      # "true"/"false". Anything else is not a boolean literal and falls through
      # to nil.
      BOOLEAN_DEFAULTS = {
        "1" => true, "true" => true,
        "0" => false, "false" => false,
      }.freeze

      # Emit `message` to stderr the first time this introspector hits `key`.
      # A catalog failure is systematic rather than per-table, so repeating it
      # once per table would bury the rest of the run's output.
      private def warn_once(key, message)
        @warned ||= {}
        return if @warned[key]

        @warned[key] = true
        warn(message)
      end

      # Group the catalog's one-row-per-key-column foreign-key listing into
      # `{ table_name:, foreign_key: }` entries, dropping composite constraints.
      # Both introspectors read their catalog in that shape (ordered by
      # constraint name, then key position), so the grouping and the warning
      # live here rather than being written twice.
      private def build_foreign_keys(table_name, rows)
        rows.group_by { |constraint_name, _column_name, _referenced_table| constraint_name }
            .filter_map do |constraint_name, group|
              if group.size > 1
                warn "exwiw: skipping composite foreign key '#{constraint_name}' on '#{table_name}' " \
                     "(#{group.map { |_c, column_name, _r| column_name }.join(', ')}); " \
                     "exwiw joins a belongs_to on a single column."
                next
              end

              _constraint_name, column_name, referenced_table = group.first
              { table_name: referenced_table, foreign_key: column_name }
            end
            .uniq
            .sort_by { |entry| [entry[:table_name], entry[:foreign_key]] }
      end
    end
  end
end
