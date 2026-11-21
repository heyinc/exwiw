# frozen_string_literal: true

require "tmpdir"
require "sqlite3"

module Exwiw
  RSpec.describe MaskUpdateRunner do
    let(:logger) { Logger.new(nil) }

    def connection_config(adapter, database_name: "exwiw_test")
      config = database_config(adapter)
      ConnectionConfig.new(
        adapter: adapter.to_s, host: config[:host], port: config[:port], user: config[:username],
        password: config[:password], database_name: adapter.to_s == "sqlite" ? config[:database] : database_name,
      )
    end

    def table(**attributes)
      TableConfig.from_symbol_keys({ name: "accounts", primary_key: "id", columns: [{ name: "id" }] }.merge(attributes))
    end

    Result = Struct.new(:script, :summary)

    # Runs the runner against a schema directory written from `tables`, reading through `adapter`.
    def build(adapter, tables, values = [1], table_name: "accounts", target: {}, **options)
      Dir.mktmpdir do |schema_dir|
        tables.each { |t| File.write(File.join(schema_dir, "#{t.name}.json"), JSON.dump(t.to_hash)) }
        allow(Adapter).to receive(:build).and_call_original
        allow(Adapter).to receive(:build).with(adapter.connection_config, anything, connection: nil, session: nil).and_return(adapter)
        io = options.delete(:io) || StringIO.new
        summary = MaskUpdateRunner.new(
          **runner_inputs(connection_config: adapter.connection_config, schema_dir: schema_dir), logger: logger, io: io,
          dump_target: DumpTarget.new(table_name: table_name, ids: values, recursive: false, mode: :primary_key, **target), **options,
        ).run
        Result.new(io.string.delete_suffix("\n"), summary)
      end
    end

    describe "errors" do
      let(:adapter) { Adapter.build(connection_config(:sqlite), logger) }
      let(:masked_columns) { [{ name: "id" }, { name: "email", replace_with: "x{id}" }] }

      it "rejects a table missing from the declaration" do
        expect { build(adapter, [table(columns: masked_columns)], table_name: "orders") }
          .to raise_error(MaskUpdateRunner::Error, /table 'orders' is not declared/)
      end

      it "rejects an ignore: true table" do
        expect { build(adapter, [table(columns: masked_columns, ignore: true)]) }
          .to raise_error(MaskUpdateRunner::Error, /'accounts' is declared ignore: true/)
      end

      it "rejects a composite primary key table" do
        composite = table(primary_key: nil, ignore: true, type: TableConfig::UNSUPPORTED_COMPOSITE_PRIMARY_KEY)
        expect { build(adapter, [composite]) }.to raise_error(MaskUpdateRunner::Error, /composite primary key/)
      end

      it "rejects a table without a primary key when the schema is loaded" do
        keyless = TableConfig.from_symbol_keys(name: "accounts", primary_key: "id", columns: masked_columns)
        keyless.primary_key = nil
        expect { build(adapter, [keyless]) }.to raise_error(ArgumentError, /requires primary_key/)
      end

      it "rejects empty primary key values" do
        tables = [table(columns: masked_columns)]
        expect { build(adapter, tables, []) }.to raise_error(MaskUpdateRunner::Error, /no primary key values/)
        expect { build(adapter, tables, [1, ""]) }.to raise_error(MaskUpdateRunner::Error, /empty value/)
        expect { build(adapter, tables, [nil]) }.to raise_error(MaskUpdateRunner::Error, /must be an Integer, a String or a BSON::ObjectId/)
      end

      it "rejects a table with no masked column, ignoring ignored columns and needs_mask_decision" do
        columns = [{ name: "id" }, { name: "email", needs_mask_decision: true }, { name: "note", ignore: true, replace_with: "x" }]
        expect { build(adapter, [table(columns: columns)]) }
          .to raise_error(MaskUpdateRunner::Error, /declares no mask/)
      end

      it "rejects a masked primary key" do
        columns = [{ name: "id", replace_with: 0 }, { name: "email", replace_with: "x" }]
        expect { build(adapter, [table(columns: columns)]) }
          .to raise_error(MaskUpdateRunner::Error, /masks its primary key 'id'/)
      end

      it "rejects an embedded collection" do
        embedded = MongodbCollectionConfig.from_symbol_keys(
          name: "addresses", primary_key: "_id", belongs_tos: [], fields: [{ name: "street", replace_with: "x" }],
          embedded_in: { collection_name: "accounts", path: "addresses" },
        )
        mongo = Adapter.build(connection_config(:mongodb), logger)
        expect { build(mongo, [embedded], table_name: "addresses") }
          .to raise_error(MaskUpdateRunner::Error, /embedded in 'accounts'/)
      end

      it "needs mode to say the ids are primary keys, and has no scope_column ids yet" do
        tables = [table(columns: masked_columns)]

        expect { build(adapter, tables, [1], target: { mode: nil }) }
          .to raise_error(MaskUpdateRunner::Error, /mode is required.*--mode=primary-key/)
        expect { build(adapter, tables, [1], target: { mode: :scope_column }) }
          .to raise_error(MaskUpdateRunner::Error, /mode: :scope_column is not supported/)
      end

      it "rejects a recursive target, given or not, which is not supported yet" do
        [true, nil].each do |recursive|
          expect { build(adapter, [table(columns: masked_columns)], [1], target: { recursive: recursive }) }
            .to raise_error(MaskUpdateRunner::Error, /recursion is not supported yet.*--no-recursive/)
        end
      end

      it "rejects ids_field, scope_column and another ID space" do
        tables = [table(columns: masked_columns)]

        expect { build(adapter, tables, [1], target: { ids_field: "email" }) }
          .to raise_error(MaskUpdateRunner::Error, /ids_field is not supported/)
        expect { build(adapter, tables, [1], target: { scope_column: "tenant_id" }) }
          .to raise_error(MaskUpdateRunner::Error, /scope_column is not supported/)
        expect { build(adapter, tables, { "default" => [1], "other" => [2] }) }
          .to raise_error(MaskUpdateRunner::Error, /ID spaces other than default \(other\)/)
      end
    end

    describe "MongoDB credential-looking fields" do
      let(:adapter) { Adapter.build(connection_config(:mongodb), logger) }
      let(:collection) { adapter.send(:db)["mask_update_credential_spec"] }

      before { collection.insert_one("_id" => 1, "api_token" => "real-token", "name" => "n") }
      after { collection.drop }

      let(:tokens) do
        MongodbCollectionConfig.from_symbol_keys(
          name: "mask_update_credential_spec", primary_key: "_id", belongs_tos: [],
          fields: [{ name: "_id" }, { name: "api_token", replace_with: "KNOWN" }],
        )
      end
      it "writes a guessable mask as declared" do
        plan = build(adapter, [tokens], [1], table_name: "mask_update_credential_spec")
        expect(plan.summary.columns).to eq(%w[api_token])
      end

      it "unsets an unset field, sets a random one, and leaves an absent or null value as it is" do
        collection.insert_one("_id" => 2, "name" => "m", "secret" => nil)
        config = MongodbCollectionConfig.from_symbol_keys(
          name: "mask_update_credential_spec", primary_key: "_id", belongs_tos: [],
          fields: [{ name: "_id" }, { name: "api_token", replace_with_random: "hex:16" }, { name: "secret", unset: true },
                   { name: "name", unset: true }],
        )
        plan = build(adapter, [config], [1, 2], table_name: "mask_update_credential_spec")
        _, operations = BSON::ExtJSON.parse_obj(JSON.parse(plan.script))
        updates = operations.to_h { |op| [op["updateOne"]["filter"]["_id"], op["updateOne"]["update"]] }

        expect(updates[1]).to match("$set" => { "api_token" => a_string_matching(/\A[0-9a-f]{32}\z/) }, "$unset" => { "name" => "" })
        expect(updates[2]).to eq("$unset" => { "secret" => "", "name" => "" })

        collection.bulk_write(operations.map { |op| { update_one: op["updateOne"].transform_keys(&:to_sym) } })
        expect(collection.find.sort("_id" => 1).to_a).to match([
          { "_id" => 1, "api_token" => a_string_matching(/\A[0-9a-f]{32}\z/) },
          { "_id" => 2 },
        ])
      end
    end

    describe "against a SQLite database" do
      let(:dir) { Dir.mktmpdir }
      let(:path) { File.join(dir, "mask.sqlite3") }
      let(:adapter) { Adapter.build(ConnectionConfig.new(adapter: "sqlite", database_name: path), logger) }
      let(:columns) do
        [
          { name: "id" },
          { name: "email", replace_with: "masked{id}@example.com" },
          { name: "code", raw_sql: "('c' || accounts.id)" },
          { name: "phone", replace_with_fake_data: { seed: "id", type: "phone_number" } },
          { name: "label", map: "->(r) { r['city'].to_s.upcase }" },
          { name: "city" },
        ]
      end
      let(:tables) { [table(columns: columns)] }
      let(:db) { SQLite3::Database.new(path) }

      before do
        db.execute("CREATE TABLE accounts (id INTEGER PRIMARY KEY, email TEXT, code TEXT, phone TEXT, label TEXT, city TEXT)")
        db.execute("INSERT INTO accounts VALUES (1, 'a@x', 'old', '1', 'old', 'tokyo')")
        db.execute("INSERT INTO accounts VALUES (2, NULL, 'old', NULL, 'old', 'osaka')")
        db.execute("INSERT INTO accounts VALUES (3, 'c@x', 'old', '3', 'old', 'kyoto')")
      end

      after { FileUtils.remove_entry(dir) }

      it "generates one literal UPDATE per row covering every masked column, and reports what it did" do
        plan = build(adapter, tables, [1, 2, 404])

        expect(plan.script.lines.map(&:strip)).to match([
          a_string_matching(
            /\AUPDATE accounts SET email = 'masked1@example.com', code = 'c1', phone = '[^']+', label = 'TOKYO' WHERE accounts.id = 1;\z/
          ),
          "UPDATE accounts SET email = NULL, code = 'c2', phone = NULL, label = 'OSAKA' WHERE accounts.id = 2;",
        ])
        expect(plan.summary).to eq(
          MaskUpdateRunner::Summary.new(
            table_name: "accounts", target_count: 2, columns: %w[email code phone label],
            missing_primary_key_values: [404],
          )
        )
      end

      it "does not apply the table's filter to the rows it selects" do
        filtered = [table(columns: columns, filter: "accounts.city = 'tokyo'")]
        issued = []
        connection = adapter.send(:connection)
        allow(connection).to receive(:execute).and_wrap_original { |m, sql, *rest| issued << sql; m.call(sql, *rest) }
        allow(connection).to receive(:prepare).and_wrap_original { |m, sql| issued << sql; m.call(sql) }

        plan = build(adapter, filtered, [1, 2])

        expect(plan.summary.target_count).to eq(2)
        expect(issued.join).not_to include("tokyo")
      end

      it "emits no header or transaction control" do
        expect(build(adapter, tables, [1]).script).not_to match(/\A\s*(BEGIN|COMMIT|SET|PRAGMA|--)|\bBEGIN\b|\bCOMMIT\b/i)
      end

      it "reports every key as missing and emits nothing when no row exists" do
        plan = build(adapter, tables, [404])
        expect(plan.script).to eq("")
        expect(plan.summary).to have_attributes(target_count: 0, missing_primary_key_values: [404])
      end

      it "issues only SELECT statements and leaves the data as it was" do
        before_rows = db.execute("SELECT * FROM accounts")
        issued = []
        connection = adapter.send(:connection)
        allow(connection).to receive(:execute).and_wrap_original { |m, sql, *rest| issued << sql; m.call(sql, *rest) }
        allow(connection).to receive(:prepare).and_wrap_original { |m, sql| issued << sql; m.call(sql) }

        build(adapter, tables, [1, 2])

        expect(issued).not_to be_empty
        expect(issued).to all(match(%r{\A(/\*.*?\*/ )?SELECT }))
        expect(db.execute("SELECT * FROM accounts")).to eq(before_rows)
      end

      it "masks only the given rows and declared columns when applied" do
        db.execute_batch(build(adapter, tables, [1, 2]).script)

        expect(db.execute("SELECT id, email, code, label, city FROM accounts ORDER BY id")).to eq([
          [1, "masked1@example.com", "c1", "TOKYO", "tokyo"],
          [2, nil, "c2", "OSAKA", "osaka"],
          [3, "c@x", "old", "old", "kyoto"],
        ])
      end

      it "does not update an ignore: true column" do
        columns << { name: "code", ignore: true, raw_sql: "'x'" }
        columns.delete_at(2)
        plan = build(adapter, tables, [1])
        expect(plan.summary.columns).not_to include("code")
      end
    end

    describe "against a table that references itself or declares a scope_column" do
      let(:dir) { Dir.mktmpdir }
      let(:path) { File.join(dir, "mask.sqlite3") }
      let(:adapter) { Adapter.build(ConnectionConfig.new(adapter: "sqlite", database_name: path), logger) }
      let(:db) { SQLite3::Database.new(path) }

      before do
        db.execute("CREATE TABLE accounts (id INTEGER PRIMARY KEY, parent_id INTEGER, org_id INTEGER, email TEXT)")
        db.execute("INSERT INTO accounts VALUES (1, NULL, 10, 'root@x'), (2, 1, 10, 'child@x'), (3, 2, 10, 'leaf@x')")
      end

      after { FileUtils.remove_entry(dir) }

      def tree_table(**attributes)
        table(
          belongs_tos: [{ table_name: "accounts", foreign_key: "parent_id", references: "id" }],
          columns: [{ name: "id" }, { name: "parent_id" }, { name: "org_id" }, { name: "email", replace_with: "masked-{id}" }],
          **attributes,
        )
      end

      it "masks only the given rows, not the ancestors export keeps for them" do
        plan = build(adapter, [tree_table], [3])
        db.execute_batch(plan.script)

        expect(plan.summary).to have_attributes(target_count: 1, missing_primary_key_values: [])
        expect(db.execute("SELECT id, email FROM accounts ORDER BY id")).to eq([[1, "root@x"], [2, "child@x"], [3, "masked-3"]])
      end

      it "writes nothing when a later row cannot be masked, so no script masks only some rows" do
        columns = [{ name: "id" }, { name: "email", map: "->(r) { r['id'] == 2 ? Object.new : 'x' }" }]
        io = StringIO.new

        expect { build(adapter, [table(columns: columns)], [1, 2], io: io) }
          .to raise_error(MaskUpdateRunner::Error, /'accounts.email' cannot be masked to this value: cannot write #<Object/)
        expect(io.string).to be_empty
      end

      it "reads the given values as primary keys even when the table declares a scope_column" do
        plan = build(adapter, [tree_table(scope_column: "org_id")], [3])
        db.execute_batch(plan.script)

        expect(plan.summary).to have_attributes(target_count: 1, missing_primary_key_values: [])
        expect(db.execute("SELECT id, email FROM accounts ORDER BY id")).to eq([[1, "root@x"], [2, "child@x"], [3, "masked-3"]])
      end
    end

    describe "against a case-insensitive text primary key" do
      let(:dir) { Dir.mktmpdir }
      let(:path) { File.join(dir, "mask.sqlite3") }
      let(:adapter) { Adapter.build(ConnectionConfig.new(adapter: "sqlite", database_name: path), logger) }
      let(:db) { SQLite3::Database.new(path) }
      let(:columns) do
        [
          { name: "id" },
          { name: "email", replace_with: "masked-{id}" },
          { name: "label", map: "->(r) { r['city'].to_s.upcase }" },
          { name: "city" },
        ]
      end

      before do
        db.execute("CREATE TABLE accounts (id TEXT PRIMARY KEY COLLATE NOCASE, email TEXT, label TEXT, city TEXT)")
        db.execute("INSERT INTO accounts VALUES ('abc', 'a@x', 'old', 'tokyo')")
      end

      after { FileUtils.remove_entry(dir) }

      it "masks both the SQL-expression and map columns of a row found under another spelling" do
        plan = build(adapter, [table(columns: columns)], ["ABC"])
        db.execute_batch(plan.script)

        expect(db.execute("SELECT email, label FROM accounts")).to eq([["masked-abc", "TOKYO"]])
        expect(plan.summary).to have_attributes(target_count: 1, missing_primary_key_values: [])
      end
    end

    describe "against a case-sensitive text primary key with keys differing only in case" do
      let(:dir) { Dir.mktmpdir }
      let(:path) { File.join(dir, "mask.sqlite3") }
      let(:adapter) { Adapter.build(ConnectionConfig.new(adapter: "sqlite", database_name: path), logger) }
      let(:db) { SQLite3::Database.new(path) }
      let(:columns) do
        [
          { name: "id" },
          { name: "email", replace_with: "masked-{id}" },
          { name: "label", map: "->(r) { r['city'].to_s.upcase }" },
          { name: "city" },
        ]
      end

      before do
        db.execute("CREATE TABLE accounts (id TEXT PRIMARY KEY, email TEXT, label TEXT, city TEXT)")
        db.execute("INSERT INTO accounts VALUES ('A', 'a@x', 'old', 'tokyo')")
        db.execute("INSERT INTO accounts VALUES ('a', 'b@x', 'old', 'osaka')")
      end

      after { FileUtils.remove_entry(dir) }

      it "masks each row once and leaves none unmasked" do
        plan = build(adapter, [table(columns: columns)], %w[A a])
        db.execute_batch(plan.script)

        expect(db.execute("SELECT id, email, label FROM accounts ORDER BY id")).to eq(
          [["A", "masked-A", "TOKYO"], ["a", "masked-a", "OSAKA"]]
        )
        expect(plan.summary).to have_attributes(target_count: 2, missing_primary_key_values: [])
      end
    end

    describe "many or repeated primary key values" do
      let(:dir) { Dir.mktmpdir }
      let(:path) { File.join(dir, "mask.sqlite3") }
      let(:adapter) { Adapter.build(ConnectionConfig.new(adapter: "sqlite", database_name: path), logger) }
      let(:db) { SQLite3::Database.new(path) }
      let(:tables) do
        [table(columns: [{ name: "id" }, { name: "email", replace_with: "masked{id}" }, { name: "label", map: "->(r) { 'L' }" }])]
      end

      before do
        db.execute("CREATE TABLE accounts (id INTEGER PRIMARY KEY, email TEXT, label TEXT)")
        db.transaction { (1..1001).each { |id| db.execute("INSERT INTO accounts VALUES (?, 'old', 'old')", id) } }
      end

      after { FileUtils.remove_entry(dir) }

      it "splits the SELECT at CHUNK_SIZE ids and still masks every row" do
        selects = []
        connection = adapter.send(:connection)
        allow(connection).to receive(:execute).and_wrap_original { |m, sql, *rest| selects << sql; m.call(sql, *rest) }
        allow(connection).to receive(:prepare).and_wrap_original { |m, sql| selects << sql; m.call(sql) }

        plan = build(adapter, tables, (1..1001).to_a)

        expect(selects.grep(/FROM .?accounts/).uniq.size).to eq(2)
        expect(plan.script.lines.size).to eq(1001)
        db.execute_batch(plan.script)
        expect(db.execute("SELECT COUNT(*) FROM accounts WHERE email LIKE 'masked%' AND label = 'L'")).to eq([[1001]])
        expect(plan.summary).to have_attributes(target_count: 1001, missing_primary_key_values: [])
      end

      it "treats the same key given as an Integer and as a String as one row" do
        plan = build(adapter, tables, [1, "1", 2])

        expect(plan.summary).to have_attributes(target_count: 2, missing_primary_key_values: [])
        expect(plan.script.lines.grep(/label = 'L' WHERE accounts\.id = '?1'?;/).size).to eq(1)
      end
    end

    describe "credential-looking columns" do
      let(:dir) { Dir.mktmpdir }
      let(:path) { File.join(dir, "mask.sqlite3") }
      let(:adapter) { Adapter.build(ConnectionConfig.new(adapter: "sqlite", database_name: path), logger) }
      let(:db) { SQLite3::Database.new(path) }

      before do
        db.execute("CREATE TABLE accounts (id INTEGER PRIMARY KEY, email TEXT, password_digest TEXT, api_token TEXT, city TEXT)")
        db.execute("INSERT INTO accounts VALUES (1, 'a@x', 'real-digest', 'real-token', 'tokyo')")
      end

      after { FileUtils.remove_entry(dir) }

      def accounts(**masks)
        extra = masks.map { |name, mask| { name: name.to_s }.merge(mask) }
        extra << { name: "city" } unless masks.key?(:city)
        table(columns: [{ name: "id" }, { name: "email", replace_with: "masked{id}" }] + extra)
      end

      it "sets an unset column to NULL" do
        plan = build(adapter, [accounts(password_digest: { unset: true })])
        db.execute_batch(plan.script)

        expect(db.execute("SELECT password_digest FROM accounts")).to eq([[nil]])
      end

      it "writes a guessable mask as declared, with or without allow_guessable_credential" do
        plan = build(adapter, [accounts(api_token: { replace_with: "KNOWN" }, password_digest: { replace_with: "D", allow_guessable_credential: true })])
        db.execute_batch(plan.script)

        expect(db.execute("SELECT api_token, password_digest FROM accounts")).to eq([%w[KNOWN D]])
      end

      it "applies replace_with_random as a different hex value per row, and keeps NULL" do
        db.execute("INSERT INTO accounts VALUES (2, 'b@x', 'd2', 'real-token-2', 'osaka')")
        db.execute("INSERT INTO accounts VALUES (3, 'c@x', 'd3', NULL, 'kyoto')")
        plan = build(adapter, [accounts(api_token: { replace_with_random: "hex:16" })], [1, 2, 3])
        db.execute_batch(plan.script)

        values = db.execute("SELECT api_token FROM accounts ORDER BY id").flatten
        expect(values.first(2)).to all(match(/\A[0-9a-f]{32}\z/))
        expect(values.first(2).uniq.size).to eq(2)
        expect(values.last).to be_nil
      end

      it "rejects a map returning a value an UPDATE cannot hold" do
        ["->(r) { :sym }", "->(r) { {} }", "->(r) { 1.0 / 0 }"].each do |code|
          expect { build(adapter, [accounts(city: { map: code })]) }
            .to raise_error(MaskUpdateRunner::Error, /'accounts.city' cannot be masked to this value: cannot write/)
        end
      end
    end

    describe "read-only generation on the shared test databases" do
      def recorded_statements(adapter, target)
        issued = []
        case adapter
        when Adapter::PostgresqlAdapter
          allow(target).to receive(:exec).and_wrap_original { |m, sql, *r| issued << sql; m.call(sql, *r) }
          allow(target).to receive(:exec_params).and_wrap_original { |m, sql, *r| issued << sql; m.call(sql, *r) }
          allow(target).to receive(:send_query).and_wrap_original { |m, sql, *r| issued << sql; m.call(sql, *r) }
        when Adapter::MysqlAdapter
          allow(target).to receive(:query).and_wrap_original { |m, sql, *r| issued << sql; m.call(sql, *r) }
          allow(target).to receive(:stream_rows).and_wrap_original { |m, sql, *r, &b| issued << sql; m.call(sql, *r, &b) }
        end
        issued
      end

      %i[postgresql mysql].each do |name|
        it "issues only SELECT statements for #{name}" do
          adapter = Adapter.build(connection_config(name), logger)
          issued = recorded_statements(adapter, adapter.send(:connection))

          plan = build(adapter, [users_table(name)], [1, 2, 987_654], table_name: "users")

          expect(issued).not_to be_empty
          expect(issued).to all(match(/\A(\/\*.*?\*\/ )?SELECT /m))
          expect(plan.summary).to have_attributes(
            target_count: 2, columns: %w[name email], missing_primary_key_values: [987_654]
          )
          expect(plan.script.lines.map(&:strip)).to match([/\AUPDATE users AS t .*'masked1'.*'masked2'.* t\.id = v\.id.*;\z/])
        end
      end

      it "issues only find commands for mongodb and masks a copy of each document" do
        adapter = Adapter.build(connection_config(:mongodb), logger)
        commands = []
        subscriber = Object.new
        subscriber.define_singleton_method(:started) { |event| commands << event.command_name }
        %i[succeeded failed].each { |m| subscriber.define_singleton_method(m) { |_| } }
        adapter.send(:db).subscribe(Mongo::Monitoring::COMMAND, subscriber)

        ids = File.readlines("seed/mongodb/users.jsonl").first(2).map { |l| BSON::ExtJSON.parse(l)["_id"].to_s }
        plan = build(adapter, [users_table(:mongodb)], ids + ["a0ffffffffffffffffffffff"], table_name: "users")

        expect(commands).to include("find")
        expect(commands.map(&:downcase) & %w[insert update delete findandmodify drop create createindexes aggregate]).to be_empty
        expect(plan.summary).to have_attributes(
          target_count: 2, columns: %w[name email], missing_primary_key_values: ["a0ffffffffffffffffffffff"]
        )
        collection, operations = BSON::ExtJSON.parse_obj(JSON.parse(plan.script))
        expect(collection).to eq("users")
        expect(operations.first).to match(
          "updateOne" => { "filter" => { "_id" => BSON::ObjectId.from_string(ids[0]) }, "update" => { "$set" => hash_including("name", "email") } }
        )
      end
    end

    describe "a primary key value the database converts to another key" do
      let(:accounts) { table(columns: [{ name: "id" }, { name: "email", replace_with: "masked{id}" }]) }

      it "refuses to mask the row MySQL matches after converting the value" do
        adapter = Adapter.build(connection_config(:mysql), logger)
        connection = adapter.send(:connection)
        connection.query("CREATE TEMPORARY TABLE accounts (id int PRIMARY KEY, email varchar(64))")
        connection.query("INSERT INTO accounts VALUES (7, 'c@x'), (10, 'a@x'), (12, 'b@x')")

        ["12x", " 12", "1e1", "007"].each do |given|
          expect { build(adapter, [accounts], [given]) }
            .to raise_error(MaskUpdateRunner::Error, /matched none of the given values exactly/)
        end
        expect(build(adapter, [accounts], [12]).summary).to have_attributes(target_count: 1, missing_primary_key_values: [])
      end

      it "reports the value as missing where the database does not convert it" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "mask.sqlite3")
          SQLite3::Database.new(path).execute_batch(
            "CREATE TABLE accounts (id INTEGER PRIMARY KEY, email TEXT); INSERT INTO accounts VALUES (12, 'b@x');"
          )
          adapter = Adapter.build(ConnectionConfig.new(adapter: "sqlite", database_name: path), logger)

          plan = build(adapter, [accounts], ["12x"])

          expect(plan.script).to eq("")
          expect(plan.summary).to have_attributes(target_count: 0, missing_primary_key_values: ["12x"])
        end
      end
    end

    describe "MongoDB output" do
      let(:adapter) { Adapter.build(connection_config(:mongodb), logger) }

      it "is one line of canonical Extended JSON per collection that keeps the BSON type of the key" do
        collection = MongodbCollectionConfig.from_symbol_keys(
          name: "mask_update_ejson_spec", primary_key: "_id", belongs_tos: [], fields: [{ name: "name", replace_with: "x" }],
        )
        coll = adapter.send(:db)["mask_update_ejson_spec"]
        coll.drop
        coll.insert_one({ "_id" => 7, "name" => "a" })

        plan = build(adapter, [collection], ["7"], table_name: "mask_update_ejson_spec")

        expect(plan.script.lines.size).to eq(1)
        expect(JSON.parse(plan.script)).to eq(
          ["mask_update_ejson_spec", [{ "updateOne" => { "filter" => { "_id" => { "$numberInt" => "7" } }, "update" => { "$set" => { "name" => "x" } } } }]]
        )
      ensure
        coll&.drop
      end

      it "can be applied from Ruby by renaming the operations the way the driver's bulk_write wants" do
        collection = MongodbCollectionConfig.from_symbol_keys(
          name: "mask_update_ruby_apply_spec", primary_key: "_id", belongs_tos: [], fields: [{ name: "name", replace_with: "x" }],
        )
        coll = adapter.send(:db)["mask_update_ruby_apply_spec"]
        coll.drop
        coll.insert_one({ "_id" => 7, "name" => "a", "keep" => 1.5 })
        plan = build(adapter, [collection], ["7"], table_name: "mask_update_ruby_apply_spec")

        name, operations = BSON::ExtJSON.parse_obj(JSON.parse(plan.script))
        driver_operations = operations.map do |op|
          { update_one: { filter: op["updateOne"]["filter"], update: op["updateOne"]["update"] } }
        end
        adapter.send(:db)[name].bulk_write(driver_operations)

        expect(coll.find.first).to eq({ "_id" => 7, "name" => "x", "keep" => 1.5 })
      ensure
        coll&.drop
      end
    end

    describe "masks that leave nothing to guess" do
      it "counts only unset and replace_with_random" do
        safe = { unset: true, replace_with_random: "hex:16" }.map { |key, value| TableColumn.from_symbol_keys(name: "t", key => value) }
        guessable = [{ raw_sql: "NULL" }, { raw_sql: "hex(randomblob(16))" }, { replace_with: "x" }, { map: "proc { nil }" }]
                    .map { |mask| TableColumn.from_symbol_keys(name: "t", **mask) }

        expect(safe.map { |c| Adapter::SqliteAdapter.safe_for_credential?(c) }).to eq([true, true])
        expect(guessable.map { |c| Adapter::SqliteAdapter.safe_for_credential?(c) }).to eq([false] * 4)
      end
    end

    describe "#apply through a given connection" do
      let(:accounts) do
        table(columns: [{ name: "id" }, { name: "email", replace_with: "masked{id}" }, { name: "updated_at" }])
      end

      def apply(source, tables, values, **options)
        Dir.mktmpdir do |schema_dir|
          tables.each { |t| File.write(File.join(schema_dir, "#{t.name}.json"), JSON.dump(t.to_hash)) }
          schema = Schema.load(dir: schema_dir, config_class: source.adapter_class.table_config_class)
          statements = []
          summary = MaskUpdateRunner.new(
            source: source, schema: schema, logger: logger, **options,
            dump_target: DumpTarget.new(table_name: tables.first.name, ids: values, recursive: false, mode: :primary_key),
          ).apply { |statement| statements << statement }
          [summary, statements]
        end
      end

      it "yields the statements once all are built, and reads only the rows the given SQLite database holds" do
        db = SQLite3::Database.new(":memory:")
        db.execute("CREATE TABLE accounts (id INTEGER PRIMARY KEY, email TEXT, updated_at TEXT)")
        db.execute("INSERT INTO accounts VALUES (1, 'a@x', 'old'), (2, 'b@x', 'old')")

        summary, statements = apply(DataSource.given("sqlite", db), [accounts], [1, 404], extra_assignments: { updated_at: "now" })

        expect(summary).to have_attributes(target_count: 1, missing_primary_key_values: [404])
        expect(statements).to eq(["UPDATE accounts SET email = 'masked1', updated_at = 'now' WHERE accounts.id = 1;"])
        expect(db.execute("SELECT email FROM accounts ORDER BY id")).to eq([["a@x"], ["b@x"]])
      end

      it "writes a Time in extra_assignments in its own zone, without an offset" do
        db = SQLite3::Database.new(":memory:")
        db.execute("CREATE TABLE accounts (id INTEGER PRIMARY KEY, email TEXT, updated_at TEXT)")
        db.execute("INSERT INTO accounts VALUES (1, 'a@x', 'old')")

        _, statements = apply(
          DataSource.given("sqlite", db), [accounts], [1], extra_assignments: { "updated_at" => Time.utc(2026, 1, 2, 3, 4, 5, 678_901) },
        )

        expect(statements).to eq(["UPDATE accounts SET email = 'masked1', updated_at = '2026-01-02 03:04:05.678901' WHERE accounts.id = 1;"])
      end

      it "keeps the time of a DateTime and writes a Date as a date in extra_assignments" do
        db = SQLite3::Database.new(":memory:")
        db.execute("CREATE TABLE accounts (id INTEGER PRIMARY KEY, email TEXT, updated_at TEXT, born_on TEXT)")
        db.execute("INSERT INTO accounts VALUES (1, 'a@x', 'old', 'old')")

        _, statements = apply(
          DataSource.given("sqlite", db), [accounts], [1],
          extra_assignments: { "updated_at" => DateTime.new(2026, 1, 2, 3, 4, 5), "born_on" => Date.new(2000, 1, 2) },
        )

        expect(statements).to eq(
          ["UPDATE accounts SET email = 'masked1', updated_at = '2026-01-02 03:04:05.000000', born_on = '2000-01-02' WHERE accounts.id = 1;"]
        )
      end

      it "refuses a MongoDB connection that is not a Mongo::Client" do
        config = database_config(:mongodb)
        client = Mongo::Client.new(["#{config[:host]}:#{config[:port]}"], database: "exwiw_mask_update_given_spec")

        expect { DataSource.given("mongodb", client.database).build_adapter(logger) }
          .to raise_error(ArgumentError, /reads through a Mongo::Client, got Mongo::Database/)
      ensure
        client&.close
      end

      it "leaves a column with a declared mask to the mask, not to extra_assignments" do
        db = SQLite3::Database.new(":memory:")
        db.execute("CREATE TABLE accounts (id INTEGER PRIMARY KEY, email TEXT, updated_at TEXT)")
        db.execute("INSERT INTO accounts VALUES (1, 'a@x', 'old')")

        _, statements = apply(DataSource.given("sqlite", db), [accounts], [1], extra_assignments: { "email" => "x" })

        expect(statements).to eq(["UPDATE accounts SET email = 'masked1' WHERE accounts.id = 1;"])
      end

      it "reads a given PostgreSQL connection as text, even when a type map decodes its results" do
        config = database_config(:postgresql)
        conn = PG.connect(host: config[:host], port: config[:port], user: config[:username], password: config[:password], dbname: "exwiw_test")
        conn.type_map_for_results = PG::BasicTypeMapForResults.new(conn)
        conn.exec("CREATE TEMPORARY TABLE accounts (id int PRIMARY KEY, email text, updated_at timestamp)")
        conn.exec("INSERT INTO accounts VALUES (1, 'a@x', NULL)")
        columns = [{ name: "id" }, { name: "email" }, { name: "updated_at", raw_sql: "TIMESTAMP '2000-01-02 03:04:05'" }]

        _, statements = apply(DataSource.given("postgresql", conn), [table(columns: columns)], [1])

        expect(statements).to eq([
          "UPDATE accounts AS t SET updated_at = v.updated_at FROM (VALUES ((NULL::accounts).id, (NULL::accounts).updated_at), " \
          "('1', '2000-01-02 03:04:05')) AS v(id, updated_at) WHERE t.id = v.id;",
        ])
        conn.exec(statements.sole)
        expect(conn.exec("SELECT updated_at::text FROM accounts").values).to eq([["2000-01-02 03:04:05"]])
      ensure
        conn&.close
      end

      connectors = {
        sqlite: lambda { |_config|
          db = SQLite3::Database.new(":memory:")
          [db, ->(sql) { db.execute(sql).map { |row| row.map { |v| v&.to_s } } }]
        },
        postgresql: lambda { |config|
          conn = PG.connect(host: config[:host], port: config[:port], user: config[:username], password: config[:password], dbname: "exwiw_test")
          [conn, ->(sql) { conn.exec(sql).values }]
        },
        mysql: lambda { |config|
          client = Mysql2::Client.new(host: config[:host], port: config[:port].to_i, username: config[:username], password: config[:password], database: "exwiw_test")
          [client, ->(sql) { client.query(sql, as: :array).to_a.map { |row| row.map { |v| v.nil? ? nil : v.to_s } } }]
        },
      }

      connectors.each do |name, connect|
        it "masks each of #{MaskUpdateRunner::CHUNK_SIZE + 100} rows with its own values across chunks on #{name}" do
          conn, query = connect.call(name == :sqlite ? nil : database_config(name))
          ids = (1..MaskUpdateRunner::CHUNK_SIZE + 100).to_a
          query.("CREATE TEMPORARY TABLE accounts (id int PRIMARY KEY, email varchar(32), n int, label varchar(32), updated_at varchar(32))")
          query.("INSERT INTO accounts VALUES #{ids.map { |id| "(#{id}, 'old', 0, 'old', 'old')" }.join(', ')}")
          columns = [
            { name: "id" }, { name: "email", replace_with: "e{id}" }, { name: "n", raw_sql: "id * 3" },
            { name: "label", map: "->(r) { \"L\#{r['id'].to_i * 7}\" }" }, { name: "updated_at" },
          ]

          summary, statements = apply(
            DataSource.given(name.to_s, conn), [table(columns: columns)], ids.reverse, extra_assignments: { "updated_at" => "now" },
          )
          statements.each { |sql| query.(sql) }

          expect(statements.size).to eq(name == :sqlite ? ids.size : 2)
          expect(summary).to have_attributes(target_count: ids.size, missing_primary_key_values: [])
          expect(query.("SELECT id, email, n, label, updated_at FROM accounts ORDER BY id"))
            .to eq(ids.map { |id| [id.to_s, "e#{id}", (id * 3).to_s, "L#{id * 7}", "now"] })
        ensure
          conn&.close
        end
      end

      connectors.slice(:postgresql, :mysql).each do |name, connect|
        it "writes values of any column type through the one UPDATE of a chunk on #{name}" do
          conn, query = connect.call(database_config(name))
          query.("CREATE TEMPORARY TABLE accounts (id varchar(8) PRIMARY KEY, n int, born date, ok boolean, note varchar(8))")
          query.("INSERT INTO accounts VALUES ('k1', 1, '1990-01-01', false, 'a'), ('k2', 2, '1990-01-01', false, 'b')")
          columns = [
            { name: "id" }, { name: "n", raw_sql: "42" }, { name: "born", replace_with: "2000-01-02" },
            { name: "ok", raw_sql: "true" }, { name: "note", raw_sql: "NULL" },
          ]

          _, statements = apply(DataSource.given(name.to_s, conn), [table(columns: columns)], %w[k1 k2])
          statements.each { |sql| query.(sql) }

          expect(statements.size).to eq(1)
          ok = name == :postgresql ? "t" : "1"
          expect(query.("SELECT id, n, born, ok, note FROM accounts ORDER BY id"))
            .to eq(%w[k1 k2].map { |id| [id, "42", "2000-01-02", ok, nil] })
        ensure
          conn&.close
        end
      end

      %i[mysql2 trilogy].each do |driver|
        it "reads through a given #{driver} client" do
          config = database_config(:mysql)
          options = { host: config[:host], port: config[:port].to_i, username: config[:username], password: config[:password], database: "exwiw_test" }
          require driver.to_s
          client = driver == :mysql2 ? Mysql2::Client.new(**options) : Trilogy.new(**options)
          client.query("CREATE TEMPORARY TABLE accounts (id int PRIMARY KEY, email varchar(64), updated_at datetime)")
          client.query("INSERT INTO accounts VALUES (1, 'a@x', NULL)")

          _, statements = apply(DataSource.given("mysql", client), [accounts], [1])

          expect(statements).to eq(
            ["UPDATE accounts AS t JOIN (SELECT 1 AS id, 'masked1' AS email) AS v ON t.id = v.id SET t.email = v.email;"]
          )
          client.query(statements.sole)
          expect(client.query("SELECT email FROM accounts").to_a.map { |row| row.is_a?(Hash) ? row["email"] : row.first }).to eq(["masked1"])
        ensure
          client&.close
        end
      end

      it "reads in a given MongoDB session, and builds bulk writes the Ruby driver can run" do
        config = database_config(:mongodb)
        client = Mongo::Client.new(["#{config[:host]}:#{config[:port]}"], database: "exwiw_mask_update_given_spec")
        collection = client[:accounts]
        collection.drop
        collection.insert_many([{ _id: "0012", email: "a@x" }, { _id: 12, email: "b@x" }, { _id: "bare" }])
        lsids = []
        subscriber = Object.new
        subscriber.define_singleton_method(:started) { |event| lsids << event.command["lsid"] if event.command_name == "find" }
        %i[succeeded failed].each { |m| subscriber.define_singleton_method(m) { |_| } }
        client.subscribe(Mongo::Monitoring::COMMAND, subscriber)
        session = client.start_session
        config_hash = { name: "accounts", primary_key: "_id", belongs_tos: [], fields: [{ name: "_id" }, { name: "email", replace_with: "masked{_id}" }] }

        summary, bulk_writes = apply(
          DataSource.given("mongodb", client, session: session), [MongodbCollectionConfig.from_symbol_keys(config_hash)],
          ["0012", "bare"], extra_assignments: { "touched" => true },
        )
        expect(bulk_writes.size).to eq(1)
        collection.bulk_write(bulk_writes.first.driver_operations)

        expect(lsids).to all(eq(session.session_id)).and(be_any)
        expect(summary.target_count).to eq(3)
        expect(collection.find.map { |d| [d["_id"], d["email"], d["touched"]] })
          .to contain_exactly(["0012", "masked0012", true], [12, "masked12", true], ["bare", nil, true])
      ensure
        session&.end_session
        collection&.drop
        client&.close
      end
    end
  end
end
