# frozen_string_literal: true

require "spec_helper"

require_relative "support/db_fixtures"

module Exwiw
  # Fixture tables covering the shapes the seed schema does not have: a view
  # (which must not be generated), a table with no primary key, a composite
  # primary key, a composite foreign key, and columns whose type/default/unique
  # index drive the masking decision. Created per adapter around the examples
  # and dropped afterwards, so the shared test database is left as it was.
  module DbIntrospectorFixtures
    PREFIX = "intro_fixture"

    MYSQL_DDL = <<~SQL
      CREATE TABLE #{PREFIX}_parents (
        id BIGINT NOT NULL AUTO_INCREMENT,
        label VARCHAR(255) NOT NULL,
        note TEXT,
        flag TINYINT(1) NOT NULL DEFAULT 1,
        amount DECIMAL(10,2) NOT NULL DEFAULT '0.00',
        kind VARCHAR(20) NOT NULL DEFAULT 'member',
        payload JSON,
        secret BLOB,
        created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (id),
        UNIQUE KEY #{PREFIX}_parents_label (label)
      );
      CREATE TABLE #{PREFIX}_composites (
        organization_id BIGINT NOT NULL,
        location_id BIGINT NOT NULL,
        name VARCHAR(255),
        PRIMARY KEY (organization_id, location_id)
      );
      CREATE TABLE #{PREFIX}_children (
        id BIGINT NOT NULL AUTO_INCREMENT,
        parent_id BIGINT NOT NULL,
        organization_id BIGINT NOT NULL,
        location_id BIGINT NOT NULL,
        PRIMARY KEY (id),
        CONSTRAINT #{PREFIX}_children_parent
          FOREIGN KEY (parent_id) REFERENCES #{PREFIX}_parents (id),
        CONSTRAINT #{PREFIX}_children_composite
          FOREIGN KEY (organization_id, location_id)
          REFERENCES #{PREFIX}_composites (organization_id, location_id)
      );
      CREATE TABLE #{PREFIX}_keyless (
        value VARCHAR(255)
      );
      CREATE VIEW #{PREFIX}_view AS SELECT id, label FROM #{PREFIX}_parents;
    SQL

    POSTGRESQL_DDL = <<~SQL
      CREATE TABLE #{PREFIX}_parents (
        id BIGSERIAL PRIMARY KEY,
        label CHARACTER VARYING(255) NOT NULL,
        note TEXT,
        flag BOOLEAN NOT NULL DEFAULT TRUE,
        amount NUMERIC(10,2) NOT NULL DEFAULT 0.00,
        kind CHARACTER VARYING(20) NOT NULL DEFAULT 'member',
        payload JSONB,
        tags TEXT[],
        secret BYTEA,
        created_at TIMESTAMP NOT NULL DEFAULT now()
      );
      CREATE UNIQUE INDEX #{PREFIX}_parents_label ON #{PREFIX}_parents (label);
      CREATE TABLE #{PREFIX}_composites (
        organization_id BIGINT NOT NULL,
        location_id BIGINT NOT NULL,
        name CHARACTER VARYING(255),
        PRIMARY KEY (organization_id, location_id)
      );
      CREATE TABLE #{PREFIX}_children (
        id BIGINT PRIMARY KEY,
        parent_id BIGINT NOT NULL REFERENCES #{PREFIX}_parents (id),
        organization_id BIGINT NOT NULL,
        location_id BIGINT NOT NULL,
        CONSTRAINT #{PREFIX}_children_composite
          FOREIGN KEY (organization_id, location_id)
          REFERENCES #{PREFIX}_composites (organization_id, location_id)
      );
      CREATE TABLE #{PREFIX}_keyless (
        value CHARACTER VARYING(255)
      );
      CREATE VIEW #{PREFIX}_view AS SELECT id, label FROM #{PREFIX}_parents;
    SQL

    DROP_SQL = <<~SQL
      DROP VIEW IF EXISTS #{PREFIX}_view;
      DROP TABLE IF EXISTS #{PREFIX}_children;
      DROP TABLE IF EXISTS #{PREFIX}_keyless;
      DROP TABLE IF EXISTS #{PREFIX}_composites;
      DROP TABLE IF EXISTS #{PREFIX}_parents;
    SQL

    module_function

    def setup!(adapter)
      DbFixtures.execute(adapter, DROP_SQL)
      DbFixtures.execute(adapter, adapter.to_s == "mysql" ? MYSQL_DDL : POSTGRESQL_DDL)
    end

    def teardown!(adapter)
      DbFixtures.execute(adapter, DROP_SQL)
    end
  end

  RSpec.describe DbIntrospector do
    # `introspector` is defined by each adapter's describe below; the shared
    # examples run against whichever one is in scope.
    def column(table_name, column_name)
      introspector.columns(table_name).find { |c| c.name == column_name }
    end

    describe ".build" do
      it "rejects an adapter whose schema cannot be read from the database" do
        config = ConnectionConfig.new(adapter: "sqlite", database_name: "tmp/test.sqlite3")

        expect { described_class.build(config) }
          .to raise_error(ArgumentError, /mysql \/ postgresql only/)
      end

      it "resolves a driver-flavored adapter alias" do
        config = DbFixtures.connection_config(:mysql)
        config.adapter = "mysql2"

        expect(described_class.build(config)).to be_a(DbIntrospector::MysqlIntrospector)
      end
    end

    # Everything both databases must report identically. Each adapter runs the
    # whole set against its own fixtures; what differs between them (array
    # columns, how a boolean is spelled) is covered per adapter below.
    shared_examples "a database introspector" do |adapter|
      prefix = DbIntrospectorFixtures::PREFIX

      before(:all) { DbIntrospectorFixtures.setup!(adapter) }
      after(:all) { DbIntrospectorFixtures.teardown!(adapter) }

      describe "#table_names" do
        it "lists the base tables, sorted" do
          expect(introspector.table_names).to eq(introspector.table_names.sort)
          expect(introspector.table_names).to include("users", "#{prefix}_parents", "#{prefix}_keyless")
        end

        it "excludes views, which hold no rows of their own" do
          expect(introspector.table_names).not_to include("#{prefix}_view")
        end
      end

      describe "#primary_key" do
        it "returns the single primary key column as a String" do
          expect(introspector.primary_key("#{prefix}_parents")).to eq("id")
        end

        it "returns every column of a composite primary key, in key order" do
          expect(introspector.primary_key("#{prefix}_composites")).to eq(%w[organization_id location_id])
        end

        it "returns nil for a table without a primary key" do
          expect(introspector.primary_key("#{prefix}_keyless")).to be_nil
        end
      end

      describe "#columns" do
        it "returns the columns in ordinal position order" do
          expect(introspector.columns("#{prefix}_children").map(&:name))
            .to eq(%w[id parent_id organization_id location_id])
        end

        it "maps database types onto the symbols the masking defaults understand" do
          types = introspector.columns("#{prefix}_parents").to_h { |c| [c.name, c.type] }

          expect(types).to include(
            "id" => :integer,
            "label" => :string,
            "note" => :text,
            "amount" => :decimal,
            "created_at" => :datetime,
          )
        end

        it "leaves a binary column unmapped so no text mask is put on it" do
          expect(column("#{prefix}_parents", "secret").type).to be_nil
        end

        it "reports the character limit of a text-ish column" do
          expect(column("#{prefix}_parents", "label").limit).to eq(255)
          expect(column("#{prefix}_parents", "id").limit).to be_nil
        end

        it "reads a plain literal default" do
          expect(column("#{prefix}_parents", "kind").default).to eq("member")
          expect(column("#{prefix}_parents", "amount").default).to eq(0.0)
        end

        it "reads a boolean default as a boolean" do
          expect(column("#{prefix}_parents", "flag").default).to be(true)
        end

        it "reports no default for a value the database computes per row" do
          expect(column("#{prefix}_parents", "created_at").default).to be_nil
        end

        it "reports no default for a column that has none" do
          expect(column("#{prefix}_parents", "note").default).to be_nil
        end
      end

      describe "#unique_column_names" do
        it "includes the columns of a unique index" do
          expect(introspector.unique_column_names("#{prefix}_parents")).to include("label")
        end

        it "includes the primary key" do
          expect(introspector.unique_column_names("#{prefix}_parents")).to include("id")
        end

        it "excludes a column with no unique index" do
          expect(introspector.unique_column_names("#{prefix}_parents")).not_to include("note")
        end

        it "returns nil when the catalog cannot be read, so nothing is masked with a constant" do
          allow(introspector).to receive(:rows).and_raise(RuntimeError, "catalog unavailable")

          result = nil
          expect { result = introspector.unique_column_names("#{prefix}_parents") }
            .to output(/treating every column as unique-indexed/).to_stderr
          expect(result).to be_nil
        end
      end

      describe "#foreign_keys" do
        it "returns single-column foreign keys as sorted belongs_to entries" do
          expect(introspector.foreign_keys("#{prefix}_children"))
            .to eq([{ table_name: "#{prefix}_parents", foreign_key: "parent_id" }])
        end

        it "skips a composite foreign key with a warning, since a belongs_to joins one column" do
          expect { introspector.foreign_keys("#{prefix}_children") }
            .to output(/skipping composite foreign key.*organization_id, location_id/m).to_stderr
        end

        it "returns nothing for a table with no foreign keys" do
          expect(introspector.foreign_keys("#{prefix}_keyless")).to eq([])
        end
      end
    end

    describe "against mysql" do
      include_examples "a database introspector", :mysql

      subject(:introspector) { described_class.build(DbFixtures.connection_config(:mysql)) }

      prefix = DbIntrospectorFixtures::PREFIX

      it "maps TINYINT(1) to :boolean, the only trace MySQL keeps of a boolean column" do
        expect(column("#{prefix}_parents", "flag").type).to eq(:boolean)
      end

      it "maps JSON to :json" do
        payload = column("#{prefix}_parents", "payload")
        expect(payload.type).to eq(:json)
        expect(payload.array).to be(false)
      end
    end

    describe "against postgresql" do
      include_examples "a database introspector", :postgresql

      subject(:introspector) { described_class.build(DbFixtures.connection_config(:postgresql)) }

      prefix = DbIntrospectorFixtures::PREFIX

      it "flags an ARRAY column, which no scalar mask fits" do
        tags = column("#{prefix}_parents", "tags")
        expect(tags.array).to be(true)
        expect(tags.type).to eq(:text)
      end

      it "maps JSONB to :jsonb" do
        payload = column("#{prefix}_parents", "payload")
        expect(payload.type).to eq(:jsonb)
        expect(payload.array).to be(false)
      end

      it "strips the cast PostgreSQL renders a literal default with" do
        expect(column("#{prefix}_parents", "kind").default).to eq("member")
      end

      it "reports no default for a sequence-backed column" do
        expect(column("#{prefix}_parents", "id").default).to be_nil
      end

      it "maps an enum column to no type, since its valid values are per column" do
        expect(column("users", "role").type).to be_nil
      end
    end
  end
end
