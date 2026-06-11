# frozen_string_literal: true

module Exwiw
  # Rewrites raw CREATE statements emitted by mysqldump / pg_dump /
  # sqlite_master.sql into idempotent forms so the generated
  # `insert-000-schema.sql` file can be re-applied without error.
  module DdlPostprocessor
    module_function

    # `CREATE TABLE [name]` → `CREATE TABLE IF NOT EXISTS [name]`.
    # `TEMP` / `TEMPORARY` variants and already-IF-NOT-EXISTS lines are skipped.
    def add_if_not_exists_to_create_table(sql)
      sql.gsub(/\bCREATE\s+TABLE\b(?!\s+IF\s+NOT\s+EXISTS)/i) do |m|
        "#{m} IF NOT EXISTS"
      end
    end

    # `CREATE [UNIQUE] INDEX [name]` → `CREATE [UNIQUE] INDEX IF NOT EXISTS [name]`.
    # Use only for databases that support it (PostgreSQL, SQLite). MySQL does NOT
    # support `CREATE INDEX IF NOT EXISTS` — do not call from the MySQL adapter.
    def add_if_not_exists_to_create_index(sql)
      sql.gsub(/\bCREATE(\s+UNIQUE)?\s+INDEX\b(?!\s+IF\s+NOT\s+EXISTS)/i) do
        unique = Regexp.last_match(1) || ""
        "CREATE#{unique} INDEX IF NOT EXISTS"
      end
    end

    # `CREATE SCHEMA [name]` → `CREATE SCHEMA IF NOT EXISTS [name]`.
    def add_if_not_exists_to_create_schema(sql)
      sql.gsub(/\bCREATE\s+SCHEMA\b(?!\s+IF\s+NOT\s+EXISTS)/i) do |m|
        "#{m} IF NOT EXISTS"
      end
    end

    # `CREATE SEQUENCE [name]` → `CREATE SEQUENCE IF NOT EXISTS [name]`.
    def add_if_not_exists_to_create_sequence(sql)
      sql.gsub(/\bCREATE\s+SEQUENCE\b(?!\s+IF\s+NOT\s+EXISTS)/i) do |m|
        "#{m} IF NOT EXISTS"
      end
    end

    # `ALTER TABLE ... ADD CONSTRAINT ...;` is not idempotent on its own.
    # PostgreSQL's PL/pgSQL has no IF-NOT-EXISTS clause for ADD CONSTRAINT, so wrap
    # each statement in a DO block that swallows `duplicate_object`.
    # Matches only statements whose ALTER TABLE clause leads directly into ADD CONSTRAINT
    # (no intervening ALTER COLUMN / DROP / etc) so that unrelated ALTER TABLE statements
    # in the same dump are not absorbed.
    ADD_CONSTRAINT_RE = /^[ \t]*ALTER\s+TABLE\s+(?:ONLY\s+)?[^\s;,]+\s+(?:\n[ \t]*)?ADD\s+CONSTRAINT\b[^;]*;/m.freeze

    def wrap_add_constraint_in_do_block(sql)
      sql.gsub(ADD_CONSTRAINT_RE) do |stmt|
        <<~SQL.chomp
          DO $exwiw$ BEGIN
            #{stmt.strip}
          EXCEPTION WHEN duplicate_object THEN NULL;
          END $exwiw$;
        SQL
      end
    end

    # pg_dump --table includes triggers but not the referenced function
    # definitions, causing UndefinedFunction errors on the target DB.
    def strip_triggers(sql)
      sql.gsub(/^CREATE TRIGGER\b.*?;\n?/mi, "")
    end

    # Generate idempotent CREATE TYPE ... AS ENUM statements.
    # +enum_types+ is an Array of Hashes with keys :schema, :name, :labels.
    def create_type_enum_statements(enum_types)
      return "" if enum_types.empty?

      stmts = enum_types.map do |t|
        qualified_name = "\"#{t[:schema]}\".\"#{t[:name]}\""
        labels_sql = t[:labels].map { |l| "'#{l.gsub("'", "''")}'" }.join(', ')
        <<~SQL.chomp
          DO $exwiw$ BEGIN
            CREATE TYPE #{qualified_name} AS ENUM (#{labels_sql});
          EXCEPTION WHEN duplicate_object THEN NULL;
          END $exwiw$;
        SQL
      end

      stmts.join("\n\n") + "\n\n"
    end
  end
end
