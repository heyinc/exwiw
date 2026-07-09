# frozen_string_literal: true

require "sqlite3"
require "mysql2"
require "pg"

module Exwiw
  module Adapter
    RSpec.describe IdentifierQuoting do
      let(:logger) { Logger.new(nil) }
      let(:sqlite_adapter) do
        SqliteAdapter.new(ConnectionConfig.new(adapter: 'sqlite', database_name: 'tmp/test.sqlite3', host: nil, port: nil, user: nil, password: nil), logger)
      end
      let(:mysql_adapter) do
        MysqlAdapter.new(ConnectionConfig.new(adapter: 'mysql', database_name: 'exwiw_test', host: '127.0.0.1', port: 3306, user: 'root', password: 'rootpassword'), logger)
      end
      let(:postgresql_adapter) do
        PostgresqlAdapter.new(ConnectionConfig.new(adapter: 'postgresql', database_name: 'exwiw_test', host: '127.0.0.1', port: 5432, user: 'postgres', password: 'test_password'), logger)
      end
      let(:all_adapters) { [sqlite_adapter, mysql_adapter, postgresql_adapter] }

      describe "#quote_identifier" do
        context "with a safe name" do
          it "returns the name bare on every adapter" do
            all_adapters.each do |adapter|
              expect(adapter.quote_identifier("users")).to eq("users")
            end
          end
        end

        context "with a $-containing name (bare-valid on all three dialects, and postgresql resolves it by case-folding)" do
          it "returns the name bare on every adapter" do
            all_adapters.each do |adapter|
              expect(adapter.quote_identifier("foo$bar")).to eq("foo$bar")
              expect(adapter.quote_identifier("Foo$bar")).to eq("Foo$bar")
            end
          end
        end

        context "with a reserved word in mixed case" do
          it "quotes it preserving the exact spelling" do
            expect(postgresql_adapter.quote_identifier("Order")).to eq(%("Order"))
            expect(mysql_adapter.quote_identifier("Order")).to eq("`Order`")
          end
        end

        context "with an embedded quote character" do
          it "doubles the quote character" do
            expect(mysql_adapter.force_quote_identifier("a`b")).to eq("`a``b`")
            expect(postgresql_adapter.quote_identifier(%(a"b))).to eq(%("a""b"))
          end
        end
      end

      describe "#quote_table_name (dot-aware)" do
        context "with a safe schema-qualified name" do
          it "leaves every part bare (byte-identical with pre-quoting output)" do
            all_adapters.each do |adapter|
              expect(adapter.quote_table_name("billing.invoices")).to eq("billing.invoices")
            end
          end
        end

        context "with a schema-qualified name whose table part is reserved" do
          it "quotes only the reserved part" do
            expect(postgresql_adapter.quote_table_name("billing.order")).to eq(%(billing."order"))
            expect(mysql_adapter.quote_table_name("billing.order")).to eq("billing.`order`")
          end
        end

        context "when force-quoting a dotted name (mysql INSERT header)" do
          it "quotes each part independently" do
            expect(mysql_adapter.force_quote_table_name("billing.invoices")).to eq("`billing`.`invoices`")
          end
        end
      end

      describe "schema-qualified table names through the compilers" do
        # A Rails multi-schema app sets `self.table_name = "billing.invoices"`
        # and the schema generator copies it verbatim, so the compiled SQL
        # must keep the dots as qualification — never quote the whole name.
        let(:dotted_table) do
          Exwiw::TableConfig.from_symbol_keys(
            name: "billing.invoices",
            primary_key: "id",
            belongs_tos: [],
            columns: [{ name: "id" }, { name: "from" }],
          )
        end
        let(:dotted_ast) do
          QueryAst::Select.new.tap do |ast|
            ast.from(dotted_table.name)
            ast.select(dotted_table.columns)
            ast.where(QueryAst::WhereClause.new(column_name: "id", operator: :eq, value: [1]))
          end
        end

        context "select query on the schema-qualified table (sqlite / postgresql)" do
          it "keeps the safe qualified name byte-identical while quoting the reserved column" do
            [sqlite_adapter, postgresql_adapter].each do |adapter|
              expect(adapter.compile_ast(dotted_ast)).to eq(
                %(SELECT billing.invoices.id, billing.invoices."from" FROM billing.invoices WHERE billing.invoices.id = 1)
              )
            end
          end
        end

        context "select query on the schema-qualified table (mysql)" do
          let(:sql) { mysql_adapter.compile_ast(dotted_ast) }

          it "keeps the safe qualified name bare while quoting the reserved column" do
            expect(sql).to eq(
              "SELECT billing.invoices.id, billing.invoices.`from` FROM billing.invoices WHERE billing.invoices.id = 1"
            )
          end
        end

        context "bulk insert into the schema-qualified table (mysql)" do
          let(:bulk_insert_sql) { mysql_adapter.to_bulk_insert([[1, 1]], dotted_table) }

          it "quotes each part of the name in the INSERT header" do
            expect(bulk_insert_sql).to start_with(
              "INSERT INTO `billing`.`invoices` (`id`, `from`) VALUES"
            )
          end
        end

        context "bulk insert into the schema-qualified table (postgresql)" do
          let(:bulk_insert_sql) { postgresql_adapter.to_bulk_insert([[1, 1]], dotted_table) }

          it "keeps the safe qualified name bare in the INSERT header" do
            expect(bulk_insert_sql).to start_with(
              %(INSERT INTO billing.invoices (id, "from") VALUES)
            )
          end
        end
      end

      describe "contract enforcement" do
        context "when a class includes the module without a dialect submodule" do
          let(:bare_includer) { Class.new { include Exwiw::Adapter::IdentifierQuoting }.new }

          it "raises NotImplementedError on first use" do
            expect { bare_includer.quote_identifier("users") }.to raise_error(NotImplementedError, /identifier_quote_char|reserved_words/)
          end
        end
      end

      # The reserved-word lists must track the engines the suite itself runs
      # against. These probes fail the build when a server upgrade introduces
      # a reserved word the lists do not cover (as mysql 9 did with LIBRARY),
      # instead of exwiw silently emitting broken SQL for it.
      describe "list coverage against live engines" do
        context "against the running mysql server" do
          let(:server_reserved) do
            client = Mysql2::Client.new(host: '127.0.0.1', port: 3306, username: 'root', password: 'rootpassword')
            words = client.query(
              "SELECT LOWER(WORD) AS w FROM INFORMATION_SCHEMA.KEYWORDS WHERE RESERVED = 1", as: :array
            ).to_a.flatten
            client.close
            words
          end

          it "covers every reserved word the server reports" do
            expect(server_reserved - IdentifierQuoting::MYSQL_RESERVED_WORDS.to_a).to eq([])
          end
        end

        context "against the running postgresql server" do
          let(:server_reserved) do
            connection = PG.connect(host: '127.0.0.1', port: 5432, user: 'postgres', password: 'test_password', dbname: 'exwiw_test')
            # catcode R = reserved, T = reserved (can be function or type
            # name); neither may appear as a bare table/column identifier.
            words = connection.exec(
              "SELECT word FROM pg_get_keywords() WHERE catcode IN ('R', 'T')"
            ).values.flatten
            connection.close
            words
          end

          it "covers every fully reserved key word the server reports" do
            expect(server_reserved - IdentifierQuoting::POSTGRESQL_RESERVED_WORDS.to_a).to eq([])
          end
        end
      end

      # SQLITE_RESERVED_WORDS is defined as "the sqlite keywords that fail to
      # parse bare in the positions exwiw emits". This probe re-derives that
      # set from the full keyword list against the bundled sqlite3 and asserts
      # exact equality, so both drift directions fail: a new reserved word
      # (as RETURNING was in 3.35) and a stale entry that would quote — and
      # thus churn — a name that works bare.
      describe "SQLITE_RESERVED_WORDS empirical derivation" do
        # The complete keyword list from https://sqlite.org/lang_keywords.html.
        ALL_SQLITE_KEYWORDS = %w[
          abort action add after all alter always analyze and as asc attach
          autoincrement before begin between by cascade case cast check collate
          column commit conflict constraint create cross current current_date
          current_time current_timestamp database default deferrable deferred
          delete desc detach distinct do drop each else end escape except
          exclude exclusive exists explain fail filter first following for
          foreign from full generated glob group groups having if ignore
          immediate in index indexed initially inner insert instead intersect
          into is isnull join key last left like limit match materialized
          natural no not nothing notnull null nulls of offset on or order
          others outer over partition plan pragma preceding primary query raise
          range recursive references regexp reindex release rename replace
          restrict returning right rollback row rows savepoint select set
          table temp temporary then ties to transaction trigger unbounded union
          unique update using vacuum values view virtual when where window
          with without
        ].freeze

        # Every SQL shape exwiw emits, with the keyword in each identifier
        # position (qualified column, masking CASE, WHERE key, INSERT column
        # list, FROM/qualified-star/DELETE/JOIN table name, scope-join
        # derived table, flat IN subquery).
        def keyword_parses_bare?(keyword)
          db = ::SQLite3::Database.new(":memory:")
          db.execute(%(CREATE TABLE t (id INTEGER PRIMARY KEY, "#{keyword}" TEXT)))
          db.execute(%(CREATE TABLE "#{keyword}" (id INTEGER PRIMARY KEY, val TEXT)))
          [
            "SELECT t.#{keyword} FROM t",
            "SELECT CASE WHEN t.#{keyword} IS NOT NULL THEN ('m-' || t.#{keyword}) ELSE NULL END FROM t",
            "SELECT id FROM t WHERE t.#{keyword} = 'x'",
            "INSERT INTO t (id, #{keyword}) VALUES (1, 'x')",
            "SELECT id FROM #{keyword}",
            "SELECT #{keyword}.* FROM #{keyword}",
            "DELETE FROM #{keyword}",
            "SELECT t.id FROM t JOIN #{keyword} ON t.id = #{keyword}.id",
            "SELECT t.id FROM t JOIN (SELECT DISTINCT s.#{keyword} AS x FROM (SELECT t.#{keyword} FROM t) AS s) AS ids ON t.id = ids.x",
            "SELECT t.id FROM t WHERE t.id IN (SELECT #{keyword}.id FROM #{keyword} WHERE #{keyword}.id IN (1))",
          ].each { |sql| db.execute(sql) }
          true
        rescue ::SQLite3::SQLException
          false
        ensure
          db&.close
        end

        context "probing every keyword in every emission position" do
          let(:derived) { ALL_SQLITE_KEYWORDS.reject { |keyword| keyword_parses_bare?(keyword) } }

          it "matches the checked-in set exactly" do
            expect(Set.new(derived)).to eq(IdentifierQuoting::SQLITE_RESERVED_WORDS)
          end
        end
      end
    end
  end
end
