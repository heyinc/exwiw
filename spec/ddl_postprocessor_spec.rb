# frozen_string_literal: true

require 'spec_helper'

module Exwiw
  RSpec.describe DdlPostprocessor do
    describe '.add_if_not_exists_to_create_table' do
      it 'rewrites bare CREATE TABLE' do
        out = described_class.add_if_not_exists_to_create_table('CREATE TABLE users (id int);')
        expect(out).to eq('CREATE TABLE IF NOT EXISTS users (id int);')
      end

      it 'is a no-op when IF NOT EXISTS is already present' do
        sql = 'CREATE TABLE IF NOT EXISTS users (id int);'
        expect(described_class.add_if_not_exists_to_create_table(sql)).to eq(sql)
      end

      it 'rewrites every occurrence' do
        sql = "CREATE TABLE a();\nCREATE TABLE b();"
        out = described_class.add_if_not_exists_to_create_table(sql)
        expect(out).to eq("CREATE TABLE IF NOT EXISTS a();\nCREATE TABLE IF NOT EXISTS b();")
      end
    end

    describe '.add_if_not_exists_to_create_index' do
      it 'rewrites CREATE INDEX and CREATE UNIQUE INDEX' do
        sql = "CREATE INDEX foo ON t(c);\nCREATE UNIQUE INDEX bar ON t(c);"
        out = described_class.add_if_not_exists_to_create_index(sql)
        expect(out).to include('CREATE INDEX IF NOT EXISTS foo')
        expect(out).to include('CREATE UNIQUE INDEX IF NOT EXISTS bar')
      end
    end

    describe '.wrap_add_constraint_in_do_block' do
      it 'wraps ALTER TABLE ... ADD CONSTRAINT in a DO block' do
        sql = <<~SQL
          ALTER TABLE ONLY public.users
              ADD CONSTRAINT users_pkey PRIMARY KEY (id);
        SQL
        out = described_class.wrap_add_constraint_in_do_block(sql)
        expect(out).to include('DO $exwiw$ BEGIN')
        expect(out).to include('ADD CONSTRAINT users_pkey PRIMARY KEY (id);')
        expect(out).to include('EXCEPTION WHEN duplicate_object THEN NULL;')
        expect(out).to include('END $exwiw$;')
      end

      it 'does NOT wrap ALTER TABLE statements without ADD CONSTRAINT' do
        sql = <<~SQL
          ALTER TABLE ONLY public.shops ALTER COLUMN id SET DEFAULT nextval('public.shops_id_seq'::regclass);

          ALTER TABLE ONLY public.users
              ADD CONSTRAINT users_pkey PRIMARY KEY (id);
        SQL
        out = described_class.wrap_add_constraint_in_do_block(sql)
        # The ALTER COLUMN statement must be untouched
        expect(out).to include("ALTER TABLE ONLY public.shops ALTER COLUMN id SET DEFAULT nextval('public.shops_id_seq'::regclass);")
        expect(out.scan(/DO \$exwiw\$/).size).to eq(1)
      end

      it 'wraps each ADD CONSTRAINT statement independently' do
        sql = <<~SQL
          ALTER TABLE ONLY public.a
              ADD CONSTRAINT a_pkey PRIMARY KEY (id);
          ALTER TABLE ONLY public.b
              ADD CONSTRAINT b_pkey PRIMARY KEY (id);
        SQL
        out = described_class.wrap_add_constraint_in_do_block(sql)
        expect(out.scan(/DO \$exwiw\$ BEGIN/).size).to eq(2)
        expect(out.scan(/END \$exwiw\$;/).size).to eq(2)
      end
    end

    describe '.create_type_enum_statements' do
      it 'returns empty string for empty input' do
        expect(described_class.create_type_enum_statements([])).to eq("")
      end

      it 'generates an idempotent DO block for one enum' do
        enums = [{ schema: 'public', name: 'admin_role', labels: %w[developer cs_viewer] }]
        out = described_class.create_type_enum_statements(enums)
        expect(out).to include('DO $exwiw$ BEGIN')
        expect(out).to include("CREATE TYPE public.admin_role AS ENUM ('developer', 'cs_viewer');")
        expect(out).to include('EXCEPTION WHEN duplicate_object THEN NULL;')
        expect(out).to include('END $exwiw$;')
      end

      it 'generates multiple DO blocks for multiple enums' do
        enums = [
          { schema: 'public', name: 'role_type', labels: %w[admin user] },
          { schema: 'public', name: 'status', labels: %w[active inactive pending] },
        ]
        out = described_class.create_type_enum_statements(enums)
        expect(out.scan('DO $exwiw$ BEGIN').size).to eq(2)
        expect(out).to include("CREATE TYPE public.role_type AS ENUM ('admin', 'user');")
        expect(out).to include("CREATE TYPE public.status AS ENUM ('active', 'inactive', 'pending');")
      end

      it 'escapes single quotes in labels' do
        enums = [{ schema: 'public', name: 'quirky', labels: ["it's", "they're"] }]
        out = described_class.create_type_enum_statements(enums)
        expect(out).to include("'it''s'")
        expect(out).to include("'they''re'")
      end
    end
  end
end
