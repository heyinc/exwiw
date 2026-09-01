# frozen_string_literal: true

require "set"

module Exwiw
  module Adapter
    # Conditional identifier quoting shared by the SQL adapters (mysql /
    # postgresql / sqlite).
    #
    # Table and column names are emitted bare unless they NEED quoting — a
    # reserved word for that database, or characters outside the safe
    # bare-identifier set (e.g. a column named `from`, which is a syntax error
    # unquoted in every dialect's INSERT column list and in sqlite even when
    # table-qualified). Quoting conditionally rather than always (Rails-style)
    # keeps the generated SQL byte-identical to previous exwiw releases for
    # ordinary names, so existing dump snapshots and diffs stay stable.
    # Known exception to that byte-identity promise: mysql-only exotic names —
    # digit-leading (`2fa_codes`) — are valid bare in mysql but fall outside
    # BARE_IDENTIFIER_PATTERN and are now backtick-quoted (still valid SQL,
    # cosmetic difference only).
    #
    # Table names get dot-aware handling (#quote_table_name): a Rails
    # multi-schema app sets `self.table_name = "billing.invoices"` and the
    # schema generator copies it verbatim into the config, so the name must be
    # emitted as two identifiers (`billing."order"`), never quoted whole
    # (`"billing.invoices"` names a nonexistent relation). An identifier with
    # a literal dot in it cannot be expressed — but its bare form was already
    # misparsed as schema.table before quoting existed, so nothing regresses.
    #
    # Each adapter includes its dialect submodule (Mysql / Postgresql /
    # Sqlite below), which bundles the quote character with the matching
    # reserved-word set. `Base` includes the bare module so shared helpers
    # (Base#null_preserving) can rely on #qualified_name existing; the hooks
    # raise NotImplementedError until a dialect submodule provides them.
    #
    # The word sets may over-approximate what strictly needs quoting in a
    # given position (e.g. mysql accepts a reserved word unquoted right after
    # a `.`): quoting a word that did not need it is still valid SQL and — for
    # the lowercase names these lists contain — refers to the same identifier,
    # while missing one is a syntax error. Reservedness is checked
    # case-insensitively but the identifier is quoted with its exact spelling
    # preserved, matching the catalog-exact names exwiw configs carry.
    #
    # spec/adapter/identifier_quoting_spec.rb keeps the lists honest: it
    # probes every sqlite keyword in every emission context and asserts the
    # live mysql / postgresql servers' own reserved-word catalogs are covered.
    module IdentifierQuoting
      # A name every supported dialect accepts bare: leading letter or
      # underscore, then letters, digits, `_` or `$` (`$` verified bare-valid
      # on mysql, postgresql and sqlite — and postgresql resolves such names
      # by case-folding, so quoting them would break configs that spell a
      # folded name in mixed case).
      BARE_IDENTIFIER_PATTERN = /\A[A-Za-z_][A-Za-z0-9_$]*\z/

      # Quote a single identifier (column name, or one part of a table name)
      # only when the bare form would not parse (reserved word or unsafe
      # characters).
      def quote_identifier(name)
        name = name.to_s
        if name.match?(BARE_IDENTIFIER_PATTERN) && !reserved_words.include?(name.downcase)
          name
        else
          force_quote_identifier(name)
        end
      end

      # Always-quoted form of a single identifier (embedded quote chars
      # doubled). Used where the adapter's output format has historically
      # always quoted (mysql INSERT headers) and must stay byte-identical.
      def force_quote_identifier(name)
        quote_char = identifier_quote_char
        "#{quote_char}#{name.to_s.gsub(quote_char) { quote_char * 2 }}#{quote_char}"
      end

      # Table-name form: dot-aware. `billing.invoices` is a schema-qualified
      # name (two identifiers), so each dot-separated part is quoted
      # independently — `billing."order"`, not `"billing.order"`.
      def quote_table_name(name)
        name.to_s.split(".", -1).map { |part| quote_identifier(part) }.join(".")
      end

      # Always-quoted, dot-aware table name (mysql INSERT headers). Splitting
      # changes PR #83's output only for dotted names, whose whole-name quoting
      # (`` `billing.invoices` ``) named a nonexistent table anyway.
      def force_quote_table_name(name)
        name.to_s.split(".", -1).map { |part| force_quote_identifier(part) }.join(".")
      end

      # `<table>.<column>` with the table part dot-aware and every identifier
      # quoted as needed.
      def qualified_name(table_name, column_name)
        "#{quote_table_name(table_name)}.#{quote_identifier(column_name)}"
      end

      private def identifier_quote_char
        raise NotImplementedError, "#{self.class} must provide #identifier_quote_char (include an IdentifierQuoting dialect submodule)"
      end

      private def reserved_words
        raise NotImplementedError, "#{self.class} must provide #reserved_words (include an IdentifierQuoting dialect submodule)"
      end

      # MySQL reserved words: the 8.4 manual's "(R)" entries
      # (https://dev.mysql.com/doc/refman/8.4/en/keywords.html), plus the
      # 9.x additions (verified against a live 9.7 server's
      # INFORMATION_SCHEMA.KEYWORDS by the identifier_quoting spec), plus the
      # MariaDB-specific reserved words (https://mariadb.com/kb/en/reserved-words/
      # — exwiw supports MariaDB servers, see MysqlAdapter#mariadb_mysqldump?).
      # Words reserved in only one engine are still safe to quote in the
      # other: backticks are always valid, and names in either engine's list
      # were a syntax error there before, so no previously working output
      # changes on the engine that reserves them.
      MYSQL_RESERVED_WORDS = Set.new(%w[
        accessible add all alter analyze and as asc asensitive before between
        bigint binary blob both by call cascade case change char character
        check collate column condition constraint continue convert create
        cross cube cume_dist current_date current_time current_timestamp
        current_user cursor database databases day_hour day_microsecond
        day_minute day_second dec decimal declare default delayed delete
        dense_rank desc describe deterministic distinct distinctrow div double
        drop dual each else elseif empty enclosed escaped except exists exit
        explain external false fetch first_value float float4 float8 for force foreign
        from fulltext function generated get grant group grouping groups
        having high_priority hour_microsecond hour_minute hour_second if
        ignore in index infile inner inout insensitive insert int int1 int2
        int3 int4 int8 integer intersect interval into io_after_gtids
        io_before_gtids is iterate join json_table key keys kill lag
        last_value lateral lead leading leave left library like limit linear
        lines load localtime localtimestamp lock long longblob longtext loop
        low_priority master_bind master_ssl_verify_server_cert match maxvalue
        mediumblob mediumint mediumtext middleint minute_microsecond
        minute_second mod modifies natural not no_write_to_binlog nth_value
        ntile null numeric of on optimize optimizer_costs option optionally
        or order out outer outfile over partition percent_rank precision
        primary procedure purge qualify range rank read reads read_write real
        recursive references regexp release rename repeat replace require
        resignal restrict return revoke right rlike row rows row_number
        schema schemas second_microsecond select sensitive separator set show
        signal smallint spatial specific sql sqlexception sqlstate sqlwarning
        sql_big_result sql_calc_found_rows sql_small_result ssl starting
        stored straight_join system table tablesample terminated then tinyblob tinyint
        tinytext to trailing trigger true undo union unique unlock unsigned
        update usage use using utc_date utc_time utc_timestamp values
        varbinary varchar varcharacter varying virtual when where while
        window with write xor year_month zerofill
        conversion current_role delete_domain_id do_domain_ids general
        ignore_domain_ids ignore_server_ids master_heartbeat_period offset
        page_checksum parse_vcol_expr ref_system_id returning slow
        st_collect stats_auto_recalc stats_persistent stats_sample_pages
        to_date vector
      ]).freeze

      # PostgreSQL reserved key words (SQL Key Words appendix): the "reserved"
      # entries plus the "reserved (can be function or type name)" entries —
      # neither may appear as a bare table/column identifier.
      POSTGRESQL_RESERVED_WORDS = Set.new(%w[
        all analyse analyze and any array as asc asymmetric authorization
        binary both case cast check collate collation column concurrently
        constraint create cross current_catalog current_date current_role
        current_schema current_time current_timestamp current_user default
        deferrable desc distinct do else end except false fetch for foreign
        freeze from full grant group having ilike in initially inner intersect
        into is isnull join lateral leading left like limit localtime
        localtimestamp natural not notnull null offset on only or order outer
        overlaps placing primary references returning right select
        session_user similar some symmetric system_user table tablesample
        then to trailing true union unique user using variadic verbose when
        where window with
      ]).freeze

      # The subset of SQLite keywords (https://sqlite.org/lang_keywords.html)
      # that actually fail to parse as bare identifiers in the positions exwiw
      # emits (qualified column, INSERT column list, FROM/JOIN table name,
      # CASE masking, derived-table scope JOIN). SQLite's parser accepts
      # the other ~half of its keywords as identifiers via fallback (e.g.
      # `key`, `temp`, `row`), and those are deliberately NOT quoted so output
      # for such names stays byte-identical with previous releases — a name in
      # this list produced a syntax error before, so quoting it cannot change
      # any previously working output. Derived empirically; the probe is
      # checked in as spec/adapter/identifier_quoting_spec.rb, which re-runs
      # it against the bundled sqlite3 and asserts this exact set, so a new
      # SQLite reserved word (as RETURNING was in 3.35) or a drifted list
      # fails the suite instead of silently emitting broken SQL.
      SQLITE_RESERVED_WORDS = Set.new(%w[
        add all alter and as autoincrement between case cast check collate
        commit constraint create current_date current_time current_timestamp
        default deferrable delete distinct drop else escape except exists
        foreign from group having in index insert intersect into is isnull
        join limit not nothing notnull null on or order primary raise
        references returning select set table then to transaction union
        unique update using values when where
      ]).freeze

      # Dialect submodules: bundle the quote character with the matching
      # reserved-word set so an adapter opts in with a single include.
      module Mysql
        include IdentifierQuoting

        private def identifier_quote_char
          '`'
        end

        private def reserved_words
          MYSQL_RESERVED_WORDS
        end
      end

      module Postgresql
        include IdentifierQuoting

        private def identifier_quote_char
          '"'
        end

        private def reserved_words
          POSTGRESQL_RESERVED_WORDS
        end
      end

      module Sqlite
        include IdentifierQuoting

        private def identifier_quote_char
          '"'
        end

        private def reserved_words
          SQLITE_RESERVED_WORDS
        end
      end
    end
  end
end
