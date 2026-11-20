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
        allow(Adapter).to receive(:build).with(adapter.connection_config, anything).and_return(adapter)
        io = options.delete(:io) || StringIO.new
        summary = MaskUpdateRunner.new(
          connection_config: adapter.connection_config, schema_dir: schema_dir, logger: logger, io: io,
          dump_target: DumpTarget.new(table_name: table_name, ids: values, recursive: false, ids_by: :primary_key, **target), **options,
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
        expect { build(adapter, tables, [nil]) }.to raise_error(MaskUpdateRunner::Error, /must be an Integer or a String/)
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

      it "needs ids_by to say the ids are primary keys, and has no scope_column ids yet" do
        tables = [table(columns: masked_columns)]

        expect { build(adapter, tables, [1], target: { ids_by: nil }) }
          .to raise_error(MaskUpdateRunner::Error, /ids_by is required.*--ids-by=primary-key/)
        expect { build(adapter, tables, [1], target: { ids_by: :scope_column }) }
          .to raise_error(MaskUpdateRunner::Error, /ids_by: :scope_column is not supported/)
      end

      it "rejects a recursive target, which is not supported yet" do
        expect { build(adapter, [table(columns: masked_columns)], [1], target: { recursive: true }) }
          .to raise_error(MaskUpdateRunner::Error, /recursion is not supported yet.*--no-recursive/)
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

      it "always needs an allowance, since MongoDB has no NULL or random mask" do
        expect { build(adapter, [tokens], [1], table_name: "mask_update_credential_spec") }
          .to raise_error(MaskUpdateRunner::Error, /mask_update_credential_spec\.api_token look like credentials/)

        plan = build(adapter, [tokens], [1], table_name: "mask_update_credential_spec",
                                             allow_constant_columns: ["mask_update_credential_spec.api_token"])
        expect(plan.summary.allowed_constant_columns).to eq(["mask_update_credential_spec.api_token"])
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
            missing_primary_key_values: [404], allowed_constant_columns: [],
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
          .to raise_error(MaskUpdateRunner::Error, /was masked to #<Object/)
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
        table(columns: [{ name: "id" }, { name: "email", replace_with: "masked{id}" }] + extra)
      end

      it "accepts one masked to NULL" do
        plan = build(adapter, [accounts(password_digest: { raw_sql: "NULL" })])
        db.execute_batch(plan.script)

        expect(db.execute("SELECT password_digest FROM accounts")).to eq([[nil]])
        expect(plan.summary.allowed_constant_columns).to eq([])
      end

      {
        "a constant" => { replace_with: "KNOWN-DIGEST" },
        "an id-derived value" => { replace_with: "masked-{id}" },
        "a fake value" => { replace_with_fake_data: { seed: "id", type: "phone_number" } },
        "a raw_sql expression" => { raw_sql: "CASE WHEN accounts.api_token IS NULL THEN NULL ELSE 'KNOWN' END" },
        "a map" => { map: "->(r) { 'KNOWN' }" },
      }.each do |label, mask|
        it "rejects #{label}" do
          expect { build(adapter, [accounts(api_token: mask)]) }
            .to raise_error(MaskUpdateRunner::Error, /accounts\.api_token look like credentials/)
        end
      end

      it "applies hex(randomblob(16)) as a different 32-char hex value per row" do
        db.execute("INSERT INTO accounts VALUES (2, 'b@x', 'd2', 'real-token-2', 'osaka')")
        plan = build(adapter, [accounts(api_token: { raw_sql: "hex(randomblob(16))" })], [1, 2])
        db.execute_batch(plan.script)

        values = db.execute("SELECT api_token FROM accounts ORDER BY id").flatten
        expect(values).to all(match(/\A[0-9A-F]{32}\z/))
        expect(values).not_to include("real-token", "real-token-2")
        expect(values.uniq.size).to eq(2)
        expect(plan.summary.allowed_constant_columns).to eq([])
      end

      it "rejects an allowance for a column masked by a random expression" do
        expect { build(adapter, [accounts(api_token: { raw_sql: "hex(randomblob(16))" })], allow_constant_columns: ["accounts.api_token"]) }
          .to raise_error(MaskUpdateRunner::Error, /allow_constant_columns names accounts\.api_token/)
      end

      it "writes the mask to a column the caller allows, and reports it" do
        plan = build(adapter, [accounts(api_token: { replace_with: "KNOWN" })], allow_constant_columns: ["accounts.api_token"])
        db.execute_batch(plan.script)

        expect(db.execute("SELECT api_token FROM accounts")).to eq([["KNOWN"]])
        expect(plan.summary.allowed_constant_columns).to eq(["accounts.api_token"])
      end

      it "rejects an allowance that guards nothing" do
        tables = [accounts(password_digest: { raw_sql: "NULL" })]
        expect { build(adapter, tables, allow_constant_columns: ["accounts.password_digest", "accounts.city"]) }
          .to raise_error(MaskUpdateRunner::Error, /allow_constant_columns names accounts\.password_digest, accounts\.city/)
      end

      it "treats passcode, api_key and access_key names as credentials too" do
        %i[shop_passcode google_api_key access_key_url].each do |name|
          expect { build(adapter, [accounts(name => { replace_with: "x" })]) }
            .to raise_error(MaskUpdateRunner::Error, /accounts\.#{name} look like credentials/)
        end
      end

      it "leaves columns whose names do not look like credentials alone" do
        plan = build(adapter, [accounts(city: { replace_with: "x" })])
        expect(plan.summary.columns).to include("city")
      end

      it "rejects a map returning a value an UPDATE cannot hold" do
        ["->(r) { true }", "->(r) { :sym }", "->(r) { {} }", "->(r) { 1.0 / 0 }"].each do |code|
          expect { build(adapter, [accounts(city: { map: code })]) }
            .to raise_error(MaskUpdateRunner::Error, /can be written into an UPDATE/)
        end
      end
    end

    describe "MongoDB credential-looking paths" do
      it "judges the whole dotted path and needs an allowance since MongoDB has no NULL mask" do
        collection = MongodbCollectionConfig.from_symbol_keys(
          name: "users", primary_key: "_id", belongs_tos: [], fields: [{ name: "services.password.bcrypt", replace_with: "x" }],
        )
        mongo = Adapter.build(connection_config(:mongodb), logger)

        expect { build(mongo, [collection], table_name: "users") }
          .to raise_error(MaskUpdateRunner::Error, /users\.services\.password\.bcrypt look like credentials/)
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
          expect(plan.script.lines.map(&:strip)).to match([
            /\AUPDATE users SET name = .*, email = .* WHERE users\.id = 1;\z/,
            /\AUPDATE users SET name = .*, email = .* WHERE users\.id = 2;\z/,
          ])
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
        expect(plan.script).to match(/\Adb\.getCollection\("users"\)\.bulkWrite\(\[\n  \{ updateOne: \{ filter: \{ "_id": ObjectId\("#{ids[0]}"\) \}/)
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

    describe "MongoDB values a mongosh script cannot express" do
      let(:adapter) { Adapter.build(connection_config(:mongodb), logger) }

      it "rejects them with a clear error instead of emitting a wrong literal" do
        [Time.utc(2026, 1, 1), BSON::Decimal128.new("1.5"), BSON::Binary.new("x"), 1.0 / 0, { "a" => 1 }].each do |value|
          expect { adapter.send(:js_literal, value) }.to raise_error(MaskUpdateRunner::Error, /cannot express/)
        end
      end
    end

    describe "random expressions for credential-looking columns" do
      let(:logger) { Logger.new(nil) }

      def guard(adapter_name, raw_sql)
        adapter = Adapter.build(connection_config(adapter_name), logger)
        columns = [{ name: "id" }, { name: "api_token", raw_sql: raw_sql }]
        build(adapter, [table(columns: columns)])
      end

      {
        postgresql: [
          "gen_random_uuid()::text", "replace(gen_random_uuid()::text, '-', '')", "encode(gen_random_bytes(16), 'hex')",
          "encode(gen_random_bytes(1024), 'hex')", "GEN_RANDOM_UUID ( ) :: TEXT", "  encode( gen_random_bytes( 32 ) , 'HEX' )  ",
          "REPLACE(gen_random_uuid()::text,'-','')",
        ],
        mysql: ["HEX(RANDOM_BYTES(16))", "LOWER(HEX(RANDOM_BYTES(16)))", "hex(random_bytes(1024))", "lower( hex( random_bytes( 32 ) ) )"],
        sqlite: ["hex(randomblob(16))", "lower(hex(randomblob(16)))", "HEX(RANDOMBLOB(1024))", "Lower( Hex( randomblob( 32 ) ) )"],
      }.each do |adapter_name, expressions|
        expressions.each do |expression|
          it "accepts #{expression.inspect} on #{adapter_name}" do
            adapter = Adapter.build(connection_config(adapter_name), logger)
            column = TableColumn.from_symbol_keys(name: "api_token", raw_sql: expression)

            expect(adapter.send(:safe_for_credential?, column)).to be(true)
          end
        end
      end

      {
        postgresql: [
          "random()", "gen_random_uuid()", "gen_random_uuid()::text || 'x'", "'k' || gen_random_uuid()::text",
          "CASE WHEN true THEN gen_random_uuid()::text ELSE 'KNOWN' END", "encode(gen_random_bytes(15), 'hex')",
          "encode(gen_random_bytes(1025), 'hex')", "encode(gen_random_bytes(016), 'hex')", "hex(randomblob(16))", "HEX(RANDOM_BYTES(16))",
          "'KNOWN'",
        ],
        mysql: [
          "RAND()", "UUID()", "HEX(RANDOM_BYTES(15))", "HEX(RANDOM_BYTES(1025))", "CONCAT('k', HEX(RANDOM_BYTES(16)))",
          "CASE WHEN 1 THEN HEX(RANDOM_BYTES(16)) ELSE 'KNOWN' END", "gen_random_uuid()::text", "hex(randomblob(16))", "'KNOWN'",
        ],
        sqlite: [
          "random()", "hex(randomblob(15))", "hex(randomblob(1025))", "'k' || hex(randomblob(16))",
          "CASE WHEN 1 THEN hex(randomblob(16)) ELSE 'KNOWN' END", "gen_random_uuid()::text", "HEX(RANDOM_BYTES(16))", "'KNOWN'",
        ],
      }.each do |adapter_name, expressions|
        expressions.each do |expression|
          it "rejects #{expression.inspect} on #{adapter_name}" do
            expect { guard(adapter_name, expression) }
              .to raise_error(MaskUpdateRunner::Error, /accounts\.api_token look like credentials.*gen_random_uuid\(\)::text.*HEX\(RANDOM_BYTES\(16\)\).*hex\(randomblob\(16\)\)/)
          end
        end
      end

      it "rejects replace_with, map and fake data without reaching the database" do
        masks = [{ replace_with: "KNOWN" }, { map: "->(r) { 'KNOWN' }" }, { replace_with_fake_data: { seed: "id", type: "phone_number" } }]
        masks.each do |mask|
          adapter = Adapter.build(connection_config(:postgresql), logger)
          columns = [{ name: "id" }, { name: "api_token" }.merge(mask)]
          expect { build(adapter, [table(columns: columns)]) }.to raise_error(MaskUpdateRunner::Error, /accounts\.api_token look like credentials/)
        end
      end
    end
  end
end
