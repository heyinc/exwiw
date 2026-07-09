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

    describe '.strip_triggers' do
      it 'removes a single-line CREATE TRIGGER statement' do
        sql = <<~SQL
          CREATE TABLE IF NOT EXISTS public.users (id int);
          CREATE TRIGGER set_timestamp BEFORE UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION public.set_timestamp();
          CREATE INDEX IF NOT EXISTS idx_users ON public.users (id);
        SQL
        out = described_class.strip_triggers(sql)
        expect(out).not_to include('CREATE TRIGGER')
        expect(out).to include('CREATE TABLE')
        expect(out).to include('CREATE INDEX')
      end

      it 'removes CREATE CONSTRAINT TRIGGER' do
        sql = "CREATE CONSTRAINT TRIGGER check_balance AFTER INSERT ON public.orders FOR EACH ROW EXECUTE FUNCTION public.check_balance();\n"
        out = described_class.strip_triggers(sql)
        expect(out).not_to include('TRIGGER')
      end

      it 'removes CREATE OR REPLACE TRIGGER' do
        sql = "CREATE OR REPLACE TRIGGER set_timestamp BEFORE UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION public.set_timestamp();\n"
        out = described_class.strip_triggers(sql)
        expect(out).not_to include('TRIGGER')
      end

      it 'removes all triggers when multiple are present' do
        sql = <<~SQL
          CREATE TRIGGER trg_a BEFORE INSERT ON public.a FOR EACH ROW EXECUTE FUNCTION public.fn_a();
          CREATE TRIGGER trg_b AFTER UPDATE ON public.b FOR EACH ROW EXECUTE FUNCTION public.fn_b();
        SQL
        out = described_class.strip_triggers(sql)
        expect(out.scan(/CREATE TRIGGER/i).size).to eq(0)
      end

      it 'removes a trigger with leading whitespace' do
        sql = "  \tCREATE TRIGGER set_timestamp BEFORE UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION public.set_timestamp();\n"
        out = described_class.strip_triggers(sql)
        expect(out).not_to include('CREATE TRIGGER')
      end

      it 'preserves non-trigger SQL unchanged' do
        sql = <<~SQL
          CREATE TABLE IF NOT EXISTS public.users (id int);
          ALTER TABLE ONLY public.users ADD CONSTRAINT users_pkey PRIMARY KEY (id);
          CREATE INDEX IF NOT EXISTS idx_users ON public.users (id);
        SQL
        expect(described_class.strip_triggers(sql)).to eq(sql)
      end
    end

    describe '.wrap_create_type_enum_in_do_block' do
      it 'wraps a single-line CREATE TYPE ... AS ENUM in an idempotent DO block' do
        sql = "CREATE TYPE public.user_role AS ENUM ('admin', 'member');"
        out = described_class.wrap_create_type_enum_in_do_block(sql)
        expect(out).to include('DO $exwiw$ BEGIN')
        expect(out).to include("CREATE TYPE public.user_role AS ENUM ('admin', 'member');")
        expect(out).to include('EXCEPTION WHEN duplicate_object THEN NULL;')
        expect(out).to include('END $exwiw$;')
      end

      it 'wraps a multi-line CREATE TYPE ... AS ENUM (pg_dump layout)' do
        sql = <<~SQL
          CREATE TYPE public.user_role AS ENUM (
              'admin',
              'member'
          );
        SQL
        out = described_class.wrap_create_type_enum_in_do_block(sql)
        expect(out).to include('DO $exwiw$ BEGIN')
        expect(out).to include("'admin'")
        expect(out).to include("'member'")
        expect(out).to include('EXCEPTION WHEN duplicate_object THEN NULL;')
        expect(out.scan(/DO \$exwiw\$ BEGIN/).size).to eq(1)
      end

      it 'wraps each CREATE TYPE independently and leaves other DDL untouched' do
        sql = <<~SQL
          CREATE TYPE public.a AS ENUM ('x');
          CREATE TABLE IF NOT EXISTS public.t (id int);
          CREATE TYPE public.b AS ENUM ('y', 'z');
        SQL
        out = described_class.wrap_create_type_enum_in_do_block(sql)
        expect(out.scan(/DO \$exwiw\$ BEGIN/).size).to eq(2)
        expect(out).to include('CREATE TABLE IF NOT EXISTS public.t (id int);')
      end
    end

    describe '.wrap_create_extension_in_do_block' do
      it 'wraps CREATE EXTENSION in a DO block that warns-and-skips the graceful errors' do
        sql = 'CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA public;'
        out = described_class.wrap_create_extension_in_do_block(sql)
        expect(out).to include('DO $$ BEGIN CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA public;')
        expect(out).to match(/EXCEPTION WHEN feature_not_supported OR invalid_schema_name OR internal_error THEN RAISE WARNING '[^']*btree_gist[^']*', SQLSTATE, SQLERRM; END \$\$;/)
      end

      it 'catches internal_error (XX000), so an extension that must be preloaded (e.g. pglogical) is skipped, not fatal' do
        sql = 'CREATE EXTENSION IF NOT EXISTS pglogical WITH SCHEMA pglogical;'
        out = described_class.wrap_create_extension_in_do_block(sql)
        expect(out).to include('internal_error')
        expect(out).to include('skipped CREATE EXTENSION pglogical')
      end

      it 'does NOT catch insufficient_privilege' do
        sql = 'CREATE EXTENSION btree_gist;'
        out = described_class.wrap_create_extension_in_do_block(sql)
        expect(out).not_to include('insufficient_privilege')
      end

      it 'names each extension in its own WARNING' do
        sql = <<~SQL
          CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA public;
          CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;
        SQL
        out = described_class.wrap_create_extension_in_do_block(sql)
        expect(out).to include('skipped CREATE EXTENSION uuid-ossp')
        expect(out).to include('skipped CREATE EXTENSION pg_trgm')
        expect(out.scan(/DO \$\$ BEGIN CREATE EXTENSION/).size).to eq(2)
      end
    end

    describe '.wrap_comment_on_extension_in_do_block' do
      it 'wraps COMMENT ON EXTENSION in a DO block that swallows undefined_object' do
        sql = "COMMENT ON EXTENSION btree_gist IS 'support for indexing common datatypes in GiST';"
        out = described_class.wrap_comment_on_extension_in_do_block(sql)
        expect(out).to eq(
          "DO $exwiw$ BEGIN COMMENT ON EXTENSION btree_gist IS 'support for indexing common datatypes in GiST'; " \
          "EXCEPTION WHEN undefined_object THEN NULL; END $exwiw$;"
        )
      end

      it 'wraps a quoted extension name' do
        sql = %(COMMENT ON EXTENSION "uuid-ossp" IS 'gen uuids';)
        out = described_class.wrap_comment_on_extension_in_do_block(sql)
        expect(out).to include('DO $exwiw$ BEGIN COMMENT ON EXTENSION "uuid-ossp" IS \'gen uuids\';')
        expect(out).to include('EXCEPTION WHEN undefined_object THEN NULL; END $exwiw$;')
      end

      it 'does not end the match early on a semicolon inside the comment string' do
        sql = "COMMENT ON EXTENSION foo IS 'a; b; c';"
        out = described_class.wrap_comment_on_extension_in_do_block(sql)
        expect(out).to eq(
          "DO $exwiw$ BEGIN COMMENT ON EXTENSION foo IS 'a; b; c'; " \
          "EXCEPTION WHEN undefined_object THEN NULL; END $exwiw$;"
        )
      end

      it 'wraps each COMMENT ON EXTENSION independently and leaves other DDL untouched' do
        sql = <<~SQL
          COMMENT ON EXTENSION a IS 'x';
          CREATE TABLE IF NOT EXISTS public.t (id int);
          COMMENT ON EXTENSION b IS 'y';
        SQL
        out = described_class.wrap_comment_on_extension_in_do_block(sql)
        expect(out.scan(/DO \$exwiw\$ BEGIN COMMENT ON EXTENSION/).size).to eq(2)
        expect(out).to include('CREATE TABLE IF NOT EXISTS public.t (id int);')
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
        expect(out).to include("CREATE TYPE \"public\".\"admin_role\" AS ENUM ('developer', 'cs_viewer');")
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
        expect(out).to include("CREATE TYPE \"public\".\"role_type\" AS ENUM ('admin', 'user');")
        expect(out).to include("CREATE TYPE \"public\".\"status\" AS ENUM ('active', 'inactive', 'pending');")
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
