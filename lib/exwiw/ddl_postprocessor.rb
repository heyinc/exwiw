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

    # A user@host pair as mysqldump writes it. Each side is independently a
    # backtick-quoted identifier (doubled backticks escape), a single- or
    # double-quoted string, or a bare word (`root@localhost`). A definer may
    # also be CURRENT_USER / CURRENT_USER(), which has no @host.
    DEFINER_ACCOUNT_PART =
      /(?:`(?:[^`]|``)*`|'(?:[^']|'')*'|"(?:[^"]|"")*"|[A-Za-z0-9_$.%\-]+)/.freeze

    DEFINER_CLAUSE =
      /DEFINER[ \t]*=[ \t]*
       (?:CURRENT_USER(?:[ \t]*\([ \t]*\))?
         |#{DEFINER_ACCOUNT_PART}(?:@#{DEFINER_ACCOUNT_PART})?)/xi.freeze

    # mysqldump wraps every view/trigger/routine/event DEFINER in a versioned
    # comment, e.g. `/*!50013 DEFINER=`u`@`h` SQL SECURITY DEFINER */` or the
    # trigger form `/*!50017 DEFINER=`u`@`h`*/`. From MySQL 8.2, creating a
    # stored object owned by another account needs SET_ANY_DEFINER, which
    # managed MySQL (RDS / Cloud SQL) does not grant, and a nonexistent
    # definer leaves an orphan object that later breaks CREATE USER / DROP
    # USER. Omitting the clause defaults the definer to CURRENT_USER (the
    # restoring account), sidestepping both.
    #
    # Anchoring on the versioned comment, rather than gsubbing DEFINER=
    # anywhere, keeps this from touching a literal "DEFINER=" inside a
    # trigger body string or a column COMMENT. SQL SECURITY DEFINER|INVOKER
    # is preserved — it governs runtime privileges, not who the definer is.
    DEFINER_COMMENT_RE =
      %r{/\*!(?<ver>\d{5})[ \t]+#{DEFINER_CLAUSE}[ \t]*
         (?<rest>(?:(?!\*/).)*?)[ \t]*\*/(?<trail>[ \t]*)}xi.freeze

    def strip_definer_clauses(sql)
      sql.gsub(DEFINER_COMMENT_RE) do
        m = Regexp.last_match
        # Drop the comment whole if DEFINER was its only content (trigger
        # form); otherwise keep the surviving content (e.g. SQL SECURITY).
        m[:rest].empty? ? "" : "/*!#{m[:ver]} #{m[:rest]} */#{m[:trail]}"
      end
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
    # each in a DO block that catches only the "cannot provide it here" cases and
    # re-raises them as a WARNING so the skip surfaces in the restore logs:
    #   - feature_not_supported (0A000, binaries absent)
    #   - invalid_schema_name (3F000, required schema absent)
    #   - internal_error (XX000): an extension that must be preloaded via
    #     shared_preload_libraries raises a bare `elog(ERROR, "<name> is not in
    #     shared_preload_libraries")` (default SQLSTATE XX000) when it is not
    #     preloaded on the target — e.g. pglogical restored into a plain RDS. Like
    #     the other two, this is the target being unable to provide the extension,
    #     not a broken dump, so the restore should skip it rather than abort.
    # insufficient_privilege (42501) is deliberately NOT caught: a restore role
    # lacking CREATE privilege is a misconfiguration to fix, not to skip silently.
    CREATE_EXTENSION_RE = /^[ \t]*CREATE\s+EXTENSION\b(?:\s+IF\s+NOT\s+EXISTS)?\s+(?<name>"[^"]+"|[^\s;]+)[^;]*;/i.freeze

    def wrap_create_extension_in_do_block(sql)
      sql.gsub(CREATE_EXTENSION_RE) do
        stmt = Regexp.last_match(0).strip
        extname = Regexp.last_match(:name).delete('"')
        warning = "exwiw: skipped CREATE EXTENSION #{extname} (SQLSTATE %): %"
        warning_literal = "'#{warning.gsub("'", "''")}'"
        "DO $$ BEGIN #{stmt} " \
          "EXCEPTION WHEN feature_not_supported OR invalid_schema_name OR internal_error THEN " \
          "RAISE WARNING #{warning_literal}, SQLSTATE, SQLERRM; END $$;"
      end
    end

    # pg_dump emits `COMMENT ON EXTENSION <name> IS '...';` right after the
    # matching CREATE EXTENSION. When the CREATE was skipped (its DO block caught
    # feature_not_supported because the target cannot provide the extension —
    # e.g. AlloyDB's google_vacuum_mgmt restored into vanilla PostgreSQL), this
    # bare COMMENT then aborts the whole restore with `undefined_object` (42704,
    # "extension ... does not exist"). Wrap each COMMENT in a DO block that
    # swallows undefined_object, so it applies when the extension exists and is a
    # no-op when it was skipped. The IS clause is matched as a whole single-quoted
    # string (doubled quotes escaped) or NULL, so an embedded `;` does not end the
    # match early.
    COMMENT_ON_EXTENSION_RE =
      /^[ \t]*COMMENT\s+ON\s+EXTENSION\s+(?:"[^"]+"|[^\s]+)\s+IS\s+(?:'(?:[^']|'')*'|NULL)\s*;/i.freeze

    def wrap_comment_on_extension_in_do_block(sql)
      sql.gsub(COMMENT_ON_EXTENSION_RE) do
        stmt = Regexp.last_match(0).strip
        "DO $exwiw$ BEGIN #{stmt} EXCEPTION WHEN undefined_object THEN NULL; END $exwiw$;"
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
