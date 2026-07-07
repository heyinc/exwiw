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
      sql.gsub(/^[ \t]*CREATE\s+(?:OR\s+REPLACE\s+)?(?:CONSTRAINT\s+)?TRIGGER\b[^;]*;\r?\n?/i, "")
    end

    # A bare `CREATE TYPE ... AS ENUM (...)` (as a full-database pg_dump emits,
    # unlike a `--table` dump, which omits enum types) is not idempotent: a
    # second restore raises `duplicate_object`. Wrap each in a DO block that
    # swallows that error, matching the form of #create_type_enum_statements.
    # Enum labels never contain a semicolon or an unescaped `)`, so the match
    # ends at the first `);` after `AS ENUM (`.
    CREATE_TYPE_ENUM_RE = /^[ \t]*CREATE\s+TYPE\b.+?\bAS\s+ENUM\s*\(.+?\)\s*;/mi.freeze

    def wrap_create_type_enum_in_do_block(sql)
      sql.gsub(CREATE_TYPE_ENUM_RE) do |stmt|
        <<~SQL.chomp
          DO $exwiw$ BEGIN
            #{stmt.strip}
          EXCEPTION WHEN duplicate_object THEN NULL;
          END $exwiw$;
        SQL
      end
    end

    # A bare `CREATE EXTENSION ...;` (as a full-database pg_dump emits, unlike a
    # `--table` dump, which omits extensions) has no graceful skip: a restore
    # target that cannot create the extension aborts the whole restore. Wrap
    # each in a DO block that catches only the two "cannot provide it here"
    # cases — feature_not_supported (0A000, binaries absent) and
    # invalid_schema_name (3F000, required schema absent) — and re-raises them
    # as a WARNING so the skip surfaces in the restore logs. insufficient_
    # privilege (42501) is deliberately NOT caught: a restore role lacking
    # CREATE privilege is a misconfiguration to fix, not to skip silently.
    CREATE_EXTENSION_RE = /^[ \t]*CREATE\s+EXTENSION\b(?:\s+IF\s+NOT\s+EXISTS)?\s+(?<name>"[^"]+"|[^\s;]+)[^;]*;/i.freeze

    def wrap_create_extension_in_do_block(sql)
      sql.gsub(CREATE_EXTENSION_RE) do
        stmt = Regexp.last_match(0).strip
        extname = Regexp.last_match(:name).delete('"')
        warning = "exwiw: skipped CREATE EXTENSION #{extname} (SQLSTATE %): %"
        warning_literal = "'#{warning.gsub("'", "''")}'"
        "DO $$ BEGIN #{stmt} " \
          "EXCEPTION WHEN feature_not_supported OR invalid_schema_name THEN " \
          "RAISE WARNING #{warning_literal}, SQLSTATE, SQLERRM; END $$;"
      end
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
