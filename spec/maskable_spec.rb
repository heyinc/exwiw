# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "active_record"
require "mongoid"

module Exwiw
  module MaskableSpecModels
    class << self
      # The schema directory of the running example, which every spec model reports as its exwiw_schema_dir.
      attr_accessor :schema_dir
    end

    %w[Sqlite Postgresql Mysql2 Trilogy].each do |name|
      const_set("#{name}Record", Class.new(::ActiveRecord::Base) { self.abstract_class = true })
    end

    def self.account_class(base)
      Class.new(base) do
        self.table_name = "maskable_spec_accounts"
        include Exwiw::Maskable::ActiveRecordModel

        def self.name = "MaskableSpecAccount"
        def self.exwiw_schema_dir = MaskableSpecModels.schema_dir
      end
    end

    class MongoidUser
      include ::Mongoid::Document
      include Exwiw::Maskable::MongoidDocument

      def self.exwiw_schema_dir = MaskableSpecModels.schema_dir

      store_in collection: "maskable_spec_users", client: "maskable_spec"
      field :name, type: String
      field :email, type: String
      field :token, type: String
      field :updated_at, type: Time
    end

    class MongoidSoftUser
      include ::Mongoid::Document
      include Exwiw::Maskable::MongoidDocument

      def self.exwiw_schema_dir = MaskableSpecModels.schema_dir

      store_in collection: "maskable_spec_users", client: "maskable_spec"
      field :name, type: String
      field :email, type: String
      field :token, type: String
      field :updated_at, type: Time
      default_scope -> { where(:name.ne => nil) }
    end

    class MongoidOrder
      include ::Mongoid::Document
      include Exwiw::Maskable::MongoidDocument

      def self.exwiw_schema_dir = MaskableSpecModels.schema_dir

      store_in collection: "maskable_spec_orders", client: "maskable_spec"
      field :_id, type: String
      field :note, type: String
      embeds_many :lines, class_name: "Exwiw::MaskableSpecModels::MongoidOrderLine"
    end

    class MongoidOrderLine
      include ::Mongoid::Document
      include Exwiw::Maskable::MongoidDocument

      def self.exwiw_schema_dir = MaskableSpecModels.schema_dir

      embedded_in :order, class_name: "Exwiw::MaskableSpecModels::MongoidOrder"
      field :sku, type: String
    end
  end

  RSpec.describe Maskable do
    around do |example|
      Dir.mktmpdir do |dir|
        @schema_dir = dir
        MaskableSpecModels.schema_dir = dir
        example.run
      end
    end

    def write_schema(config)
      File.write(File.join(@schema_dir, "#{config[:name]}.json"), JSON.dump(config))
    end

    describe Maskable::ActiveRecordModel do
      # The masked `born_at` checks that values are read as the CLI reads them, whatever types the model's connection decodes.
      born_at_sql = {
        sqlite: "'2000-01-01 00:00:00'",
        postgresql: "TIMESTAMP '2000-01-01 00:00:00'",
        mysql2: "TIMESTAMP '2000-01-01 00:00:00'",
        trilogy: "TIMESTAMP '2000-01-01 00:00:00'",
      }
      connection_configs = {
        sqlite: -> { { adapter: "sqlite3", database: File.join(Dir.tmpdir, "exwiw_maskable_spec.sqlite3") } },
        postgresql: -> { database_config(:postgresql) },
        mysql2: -> { database_config(:mysql) },
        trilogy: -> { database_config(:mysql).merge(adapter: "trilogy") },
      }

      connection_configs.each do |name, config|
        context "on #{name}" do
          let(:base) { MaskableSpecModels.const_get("#{name.to_s.capitalize}Record") }
          let(:account) { MaskableSpecModels.account_class(base) }
          let(:connection) { base.connection }

          before do
            base.establish_connection(config.call)
            connection.drop_table(:maskable_spec_accounts, if_exists: true)
            connection.create_table(:maskable_spec_accounts) do |t|
              t.string :email
              t.string :city
              t.datetime :born_at
              t.datetime :updated_at
            end
            write_schema(
              name: "maskable_spec_accounts", primary_key: "id",
              columns: [
                { name: "id" },
                { name: "email", replace_with: "masked{id}@example.com" },
                { name: "city" },
                { name: "born_at", raw_sql: born_at_sql.fetch(name) },
                { name: "updated_at" },
              ],
            )
          end

          after do
            connection.drop_table(:maskable_spec_accounts, if_exists: true)
            base.remove_connection
          end

          let(:long_ago) { Time.utc(2001, 2, 3) }

          def create_account(email, city)
            account.create!(email: email, city: city, born_at: Time.utc(1990, 5, 1), updated_at: long_ago)
          end

          it "masks the rows of the relation in place and touches updated_at" do
            a = create_account("a@x", "tokyo")
            b = create_account("b@x", "osaka")

            result = account.where(city: "tokyo").mask_with_exwiw!

            expect(result.summary).to have_attributes(target_count: 1, columns: %w[email born_at], missing_primary_key_values: [])
            expect(result.statements).to contain_exactly(a_string_matching(/\AUPDATE .*updated_at.* = '\d{4}-\d\d-\d\d [\d:.]+'/))
            a.reload
            expect(a).to have_attributes(email: "masked#{a.id}@example.com", city: "tokyo")
            expect(a.born_at.year).to eq(2000)
            expect(a.updated_at).to be > long_ago
            expect(b.reload).to have_attributes(email: "b@x", updated_at: long_ago)
          end

          it "leaves updated_at alone with touch: false" do
            a = create_account("a@x", "tokyo")

            result = account.where(id: a.id).mask_with_exwiw!(touch: false)

            expect(result.statements.join).not_to include("updated_at")
            expect(a.reload).to have_attributes(email: "masked#{a.id}@example.com", updated_at: long_ago)
          end

          it "only returns the statements with dry_run: true" do
            a = create_account("a@x", "tokyo")

            result = account.where(id: a.id).mask_with_exwiw!(dry_run: true)

            expect(result.summary.target_count).to eq(1)
            expect(result.statements).to contain_exactly(a_string_starting_with("UPDATE "))
            expect(a.reload.email).to eq("a@x")
          end

          it "masks a record's row and reloads it, or only returns the statement with dry_run: true" do
            a = create_account("a@x", "tokyo")
            b = create_account("b@x", "osaka")

            expect(b.mask_with_exwiw!(dry_run: true).statements.sole).to start_with("UPDATE ")
            expect(b.email).to eq("b@x")

            result = a.mask_with_exwiw!

            expect(result.summary.target_count).to eq(1)
            expect(a.email).to eq("masked#{a.id}@example.com")
            expect(b.reload.email).to eq("b@x")
            expect { account.new.mask_with_exwiw! }.to raise_error(MaskUpdateRunner::Error, /not persisted/)
          end

          it "refuses a relation with no condition of its own, default scope or not" do
            create_account("a@x", "tokyo")
            soft = Class.new(account) { default_scope { where.not(city: nil) } }

            [account, account.all, account.unscoped, soft, soft.all].each do |relation|
              expect { relation.mask_with_exwiw! }
                .to raise_error(MaskUpdateRunner::Error, /no condition narrowing the rows/)
            end
            expect(account.pluck(:email)).to eq(["a@x"])
            expect(soft.where(city: "tokyo").mask_with_exwiw!.summary.target_count).to eq(1)
          end

          it "masks a large relation batch by batch" do
            accounts = Array.new(3) { |i| create_account("#{i}@x", "tokyo") }

            account.where(city: "tokyo").in_batches(of: 2) { |batch| batch.mask_with_exwiw! }

            expect(account.order(:id).pluck(:email)).to eq(accounts.map { |a| "masked#{a.id}@example.com" })
          end

          it "masks nothing for an empty relation" do
            create_account("a@x", "tokyo")

            result = account.where(city: "nowhere").mask_with_exwiw!

            expect(result).to have_attributes(statements: [])
            expect(result.summary.target_count).to eq(0)
          end

          it "reads and writes within the caller's transaction" do
            account.transaction do
              a = create_account("a@x", "tokyo")
              account.where(id: a.id).mask_with_exwiw!
              expect(a.reload.email).to eq("masked#{a.id}@example.com")
              raise ::ActiveRecord::Rollback
            end

            expect(account.count).to eq(0)
          end

          it "updates no row when a later row cannot be masked as declared" do
            a = create_account("a@x", "tokyo")
            b = create_account("b@x", "osaka")
            write_schema(
              name: "maskable_spec_accounts", primary_key: "id",
              columns: [{ name: "id" }, { name: "email", map: "->(r) { r['id'].to_s == '#{b.id}' ? Object.new : 'x' }" }],
            )

            expect { account.where(id: [a.id, b.id]).mask_with_exwiw! }
              .to raise_error(MaskUpdateRunner::Error, /cannot be masked to this value/)
            expect(account.order(:id).pluck(:email)).to eq(["a@x", "b@x"])
            expect(a.reload.updated_at).to eq(long_ago)
          end
        end
      end

      context "masking again" do
        let(:base) { MaskableSpecModels::SqliteRecord }
        let(:account) { MaskableSpecModels.account_class(base) }

        before do
          base.establish_connection(adapter: "sqlite3", database: ":memory:")
          base.connection.create_table(:maskable_spec_accounts) { |t| t.string :email }
          write_schema(name: "maskable_spec_accounts", primary_key: "id", columns: [{ name: "id" }, { name: "email", replace_with: "a{id}" }])
        end

        after { base.remove_connection }

        it "loads the schema once, and again when the cached one is older than the TTL" do
          a = account.create!(email: "a@x")
          allow(Schema).to receive(:load).and_call_original
          clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { clock }

          a.mask_with_exwiw!
          path = File.join(@schema_dir, "maskable_spec_accounts.json")
          File.write(path, File.read(path).sub("a{id}", "b{id}"))
          clock += SchemaCache::DEFAULT_TTL - 1
          a.mask_with_exwiw!
          expect(Schema).to have_received(:load).once
          expect(a.email).to eq("a#{a.id}")

          clock += 2
          a.mask_with_exwiw!

          expect(Schema).to have_received(:load).twice
          expect(a.email).to eq("b#{a.id}")
        end
      end

      context "with exwiw_config_path" do
        let(:base) { MaskableSpecModels::SqliteRecord }

        before do
          base.establish_connection(adapter: "sqlite3", database: ":memory:")
          base.connection.create_table(:maskable_spec_accounts) { |t| t.string :email }
          config_dir = File.join(@schema_dir, "conf")
          FileUtils.mkdir_p(File.join(config_dir, "schema"))
          File.write(File.join(config_dir, "exwiw.yml"), "schema_dir: schema\n")
          File.write(
            File.join(config_dir, "schema", "maskable_spec_accounts.json"),
            JSON.dump(name: "maskable_spec_accounts", primary_key: "id", columns: [{ name: "id" }, { name: "email", replace_with: "c{id}" }]),
          )
        end

        after { base.remove_connection }

        let(:config_path) { File.join(@schema_dir, "conf", "exwiw.yml") }

        it "reads the schema_dir of that config file, relative to it" do
          path = config_path
          model = Class.new(MaskableSpecModels.account_class(base)) do
            define_singleton_method(:exwiw_config_path) { path }
            def self.exwiw_schema_dir = nil
          end
          record = model.create!(email: "a@x")

          record.mask_with_exwiw!

          expect(record.email).to eq("c#{record.id}")
        end

        it "reads the schema directory next to the config file when the config does not name one" do
          File.write(config_path, "profiles: []\n")
          path = config_path
          model = Class.new(MaskableSpecModels.account_class(base)) do
            define_singleton_method(:exwiw_config_path) { path }
            def self.exwiw_schema_dir = nil
          end
          record = model.create!(email: "a@x")

          record.mask_with_exwiw!

          expect(record.email).to eq("c#{record.id}")
        end

        it "takes it from a concern's class_methods, which the module's own methods do not shadow" do
          path = config_path
          concern = Module.new do
            extend ActiveSupport::Concern
            included { include Exwiw::Maskable::ActiveRecordModel }
            class_methods { define_method(:exwiw_config_path) { path } }
          end
          model = Class.new(base) do
            self.table_name = "maskable_spec_accounts"
            include concern
          end
          record = model.create!(email: "a@x")

          record.mask_with_exwiw!

          expect(record.email).to eq("c#{record.id}")
        end

        it "takes the schema_dir from exwiw_schema_dir, which may depend on the model's connection" do
          FileUtils.mkdir_p(File.join(@schema_dir, "per_db", "primary"))
          FileUtils.cp(
            File.join(@schema_dir, "conf", "schema", "maskable_spec_accounts.json"), File.join(@schema_dir, "per_db", "primary"),
          )
          root = File.join(@schema_dir, "per_db")
          model = Class.new(MaskableSpecModels.account_class(base)) do
            define_singleton_method(:exwiw_schema_dir) { File.join(root, connection_db_config.name) }
          end
          record = model.create!(email: "a@x")

          record.mask_with_exwiw!

          expect(record.email).to eq("c#{record.id}")
        end

        it "refuses a schema directory with no config" do
          empty = File.join(@schema_dir, "empty")
          FileUtils.mkdir_p(empty)
          model = Class.new(MaskableSpecModels.account_class(base)) { define_singleton_method(:exwiw_schema_dir) { empty } }
          record = model.create!(email: "a@x")

          expect { record.mask_with_exwiw! }.to raise_error(ArgumentError, /no schema config in #{Regexp.escape(empty)}/)
        end

        it "refuses a config file that does not exist" do
          model = Class.new(MaskableSpecModels.account_class(base)) { def self.exwiw_config_path = "/nonexistent/exwiw.yml" }
          record = model.create!(email: "a@x")

          expect { record.mask_with_exwiw! }.to raise_error(ArgumentError, %r{exwiw config file not found: /nonexistent/exwiw.yml})
        end
      end

      it "adds nothing to a model that does not include it" do
        expect(::ActiveRecord::Base).not_to respond_to(:mask_with_exwiw!)
        expect(::ActiveRecord::Base.instance_methods).not_to include(:mask_with_exwiw!)
      end
    end

    describe Maskable::MongoidDocument do
      let(:model) { MaskableSpecModels::MongoidUser }
      let(:long_ago) { Time.utc(2001, 2, 3) }

      before do
        mongo = database_config(:mongodb)
        ::Mongo::Logger.logger.level = ::Logger::WARN
        ::Mongoid::Config.clients[:maskable_spec] = {
          hosts: ["#{mongo.fetch(:host)}:#{mongo.fetch(:port)}"], database: "exwiw_maskable_spec",
        }
        model.delete_all
        write_schema(users_schema)
      end

      let(:users_schema) do
        {
          name: "maskable_spec_users", primary_key: "_id", belongs_tos: [],
          fields: [
            { name: "_id" },
            { name: "name" },
            { name: "email", replace_with: "masked{_id}@example.com" },
            { name: "token", replace_with: "fixed", allow_guessable_mask: true },
            { name: "updated_at" },
          ],
        }
      end

      after { model.delete_all }

      def create_user(name)
        model.create!(name: name, email: "#{name}@x", token: "t", updated_at: long_ago)
      end

      it "masks the documents of the criteria through the model's collection and touches updated_at" do
        a = create_user("a")
        b = create_user("b")

        result = model.where(name: "a").mask_with_exwiw!

        expect(result.summary).to have_attributes(target_count: 1, columns: %w[email token])
        expect(result.statements.sole).to have_attributes(
          collection_name: "maskable_spec_users",
          operations: [{ "updateOne" => { "filter" => { "_id" => a._id }, "update" => { "$set" => hash_including("updated_at") } } }],
        )
        a.reload
        expect(a).to have_attributes(name: "a", email: "masked#{a._id}@example.com", token: "fixed")
        expect(a.updated_at).to be > long_ago
        expect(b.reload).to have_attributes(email: "b@x", updated_at: long_ago)
      end

      it "leaves updated_at alone with touch: false" do
        a = create_user("a")

        model.where(name: "a").mask_with_exwiw!(touch: false)

        expect(a.reload).to have_attributes(email: "masked#{a._id}@example.com", updated_at: long_ago)
      end

      it "only returns the bulk writes with dry_run: true" do
        a = create_user("a")

        result = model.where(name: "a").mask_with_exwiw!(dry_run: true)

        expect(result.statements.size).to eq(1)
        expect(BSON::ExtJSON.parse(result.statements.sole.to_extended_json).first).to eq("maskable_spec_users")
        expect(a.reload.email).to eq("a@x")
      end

      it "masks a document and reloads it" do
        a = create_user("a")
        b = create_user("b")

        expect(a.mask_with_exwiw!.summary.target_count).to eq(1)
        expect(a.email).to eq("masked#{a._id}@example.com")
        expect(b.reload.email).to eq("b@x")
      end

      it "refuses a criteria with no condition of its own, default scope or not" do
        create_user("a")
        soft = MaskableSpecModels::MongoidSoftUser

        [model, model.all, model.unscoped, soft, soft.all, soft.unscoped].each do |criteria|
          expect { criteria.mask_with_exwiw! }.to raise_error(MaskUpdateRunner::Error, /no condition narrowing the documents/)
        end
        expect(model.pluck(:email)).to eq(["a@x"])
        expect(soft.where(name: "a").mask_with_exwiw!.summary.target_count).to eq(1)
      end

      context "with a String _id that reads as a number" do
        let(:orders) { MaskableSpecModels::MongoidOrder }

        before do
          orders.delete_all
          write_schema(
            name: "maskable_spec_orders", primary_key: "_id", belongs_tos: [],
            fields: [{ name: "_id" }, { name: "note", replace_with: "masked{_id}" }],
          )
        end

        after { orders.delete_all }

        it "masks the document under its stored String _id, leading zeros and all" do
          order = orders.create!(_id: "0000012345", note: "secret")

          result = orders.where(_id: "0000012345").mask_with_exwiw!

          expect(result.summary).to have_attributes(target_count: 1, missing_primary_key_values: [])
          expect(order.reload.note).to eq("masked0000012345")
        end

        it "refuses an embedded document, whose masks apply through its parent" do
          order = orders.create!(_id: "1", note: "n", lines: [{ sku: "x" }])

          expect { order.lines.first.mask_with_exwiw! }.to raise_error(MaskUpdateRunner::Error, /embedded/)
          expect { MaskableSpecModels::MongoidOrderLine.where(sku: "x").mask_with_exwiw! }
            .to raise_error(MaskUpdateRunner::Error, /embedded/)
        end
      end

      it "reads and writes in the caller's session, so a transaction's would include them" do
        a = create_user("a")
        lsids = []
        subscriber = Object.new
        subscriber.define_singleton_method(:started) do |event|
          lsids << [event.command_name, event.command["lsid"]] if %w[find update].include?(event.command_name)
        end
        %i[succeeded failed].each { |m| subscriber.define_singleton_method(m) { |_| } }
        model.mongo_client.subscribe(Mongo::Monitoring::COMMAND, subscriber)

        session_id = model.with_session do |session|
          model.where(name: "a").mask_with_exwiw!
          session.session_id
        end

        expect(lsids.map(&:first)).to include("find", "update")
        expect(lsids.map(&:last)).to all(eq(session_id))
        expect(a.reload.email).to eq("masked#{a._id}@example.com")
      ensure
        model.mongo_client.unsubscribe(Mongo::Monitoring::COMMAND, subscriber) if subscriber
      end

      it "writes nothing when a document cannot be masked as declared" do
        write_schema(users_schema.merge(fields: users_schema[:fields].map { |f| f.except(:allow_guessable_mask) }))
        a = create_user("a")

        expect { model.where(name: "a").mask_with_exwiw! }.to raise_error(MaskUpdateRunner::Error, /look like credentials/)
        expect(a.reload.email).to eq("a@x")
      end
    end
  end
end
