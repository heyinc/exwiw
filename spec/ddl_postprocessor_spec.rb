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

    describe '.strip_definer_clauses' do
      it 'drops the whole comment when it held only the trigger DEFINER' do
        sql = <<~SQL
          DELIMITER ;;
          /*!50003 CREATE*/ /*!50017 DEFINER=`root`@`localhost`*/ /*!50003 TRIGGER `t_bi` BEFORE INSERT ON `t` FOR EACH ROW BEGIN SET NEW.x = 1; END */;;
          DELIMITER ;
        SQL
        out = described_class.strip_definer_clauses(sql)
        expect(out).not_to include('DEFINER=')
        expect(out).not_to include('/*!50017')
        expect(out).to include('/*!50003 CREATE*/ /*!50003 TRIGGER `t_bi` BEFORE INSERT ON `t`')
      end

      it 'keeps the comment (and its version gate) when SQL SECURITY survives' do
        sql = "/*!50013 DEFINER=`root`@`localhost` SQL SECURITY DEFINER */\n"
        expect(described_class.strip_definer_clauses(sql)).to eq("/*!50013 SQL SECURITY DEFINER */\n")
      end

      it 'leaves no trailing whitespace on the rewritten view comment' do
        sql = <<~SQL
          /*!50001 CREATE ALGORITHM=UNDEFINED */
          /*!50013 DEFINER=`root`@`localhost` SQL SECURITY DEFINER */
          /*!50001 VIEW `v` AS select 1 AS `id` */;
        SQL
        out = described_class.strip_definer_clauses(sql)
        expect(out).not_to match(/[ \t]+$/)
        expect(out).to include('/*!50013 SQL SECURITY DEFINER */')
      end

      it 'preserves SQL SECURITY INVOKER' do
        sql = "/*!50013 DEFINER=CURRENT_USER() SQL SECURITY INVOKER */\n"
        expect(described_class.strip_definer_clauses(sql)).to eq("/*!50013 SQL SECURITY INVOKER */\n")
      end

      it 'strips a single-quoted account with a wildcard host' do
        sql = "/*!50017 DEFINER='app'@'10.0.%'*/\n"
        out = described_class.strip_definer_clauses(sql)
        expect(out).not_to include('DEFINER=')
        expect(out).not_to include('/*!50017')
      end

      it 'strips an unquoted account' do
        sql = "/*!50017 DEFINER=root@localhost*/\n"
        out = described_class.strip_definer_clauses(sql)
        expect(out).not_to include('DEFINER=')
      end

      it 'strips a backtick-escaped identifier' do
        sql = "/*!50017 DEFINER=`weird``user`@`10.0.%`*/\n"
        out = described_class.strip_definer_clauses(sql)
        expect(out).not_to include('DEFINER=')
      end

      it 'strips CURRENT_USER without parens' do
        sql = "/*!50017 DEFINER=CURRENT_USER*/\n"
        out = described_class.strip_definer_clauses(sql)
        expect(out).not_to include('DEFINER=')
      end

      it 'strips a routine DEFINER (/*!50020 ...*/)' do
        sql = "/*!50020 DEFINER=`root`@`localhost`*/\n"
        out = described_class.strip_definer_clauses(sql)
        expect(out).not_to include('DEFINER=')
        expect(out).not_to include('/*!50020')
      end

      it 'does NOT touch a literal DEFINER= inside a column COMMENT' do
        sql = "CREATE TABLE `t` (`c` int COMMENT 'DEFINER=`x`@`y` note') ENGINE=InnoDB;\n"
        expect(described_class.strip_definer_clauses(sql)).to eq(sql)
      end

      it 'does NOT touch a literal DEFINER= inside a trigger body string' do
        sql = "/*!50003 TRIGGER `t` BEFORE INSERT ON `t` FOR EACH ROW BEGIN SET NEW.note = 'DEFINER=`a`@`b`'; END */;;\n"
        expect(described_class.strip_definer_clauses(sql)).to eq(sql)
      end

      it 'is a no-op on a dump with no stored objects' do
        sql = "CREATE TABLE IF NOT EXISTS `t` (`id` int NOT NULL) ENGINE=InnoDB;\n"
        expect(described_class.strip_definer_clauses(sql)).to eq(sql)
      end

      it 'is idempotent' do
        sql = <<~SQL
          /*!50003 CREATE*/ /*!50017 DEFINER=`root`@`localhost`*/ /*!50003 TRIGGER `t_bi` BEFORE INSERT ON `t` FOR EACH ROW BEGIN SET NEW.x = 1; END */;;
          /*!50013 DEFINER=`root`@`localhost` SQL SECURITY DEFINER */
        SQL
        once = described_class.strip_definer_clauses(sql)
        twice = described_class.strip_definer_clauses(once)
        expect(twice).to eq(once)
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

    describe '.extension_names' do
      it 'lists every installed extension in dump order' do
        sql = <<~SQL
          CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA public;
          CREATE EXTENSION IF NOT EXISTS google_vacuum_mgmt WITH SCHEMA google_vacuum_mgmt;
          CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA public;
        SQL

        expect(described_class.extension_names(sql)).to eq(%w[btree_gist google_vacuum_mgmt uuid-ossp])
      end

      it 'returns an empty list for a dump that installs no extension' do
        expect(described_class.extension_names('CREATE TABLE public.t (id int);')).to eq([])
      end
    end

    describe '.strip_extensions' do
      # pg_dump's real layout for the objects an extension contributes: a 3-line
      # `-- Name:` header before each of CREATE EXTENSION and COMMENT ON EXTENSION.
      let(:dump) do
        <<~SQL
          SET row_security = off;

          --
          -- Name: btree_gist; Type: EXTENSION; Schema: -; Owner: -
          --

          CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA public;


          --
          -- Name: EXTENSION btree_gist; Type: COMMENT; Schema: -; Owner: -
          --

          COMMENT ON EXTENSION btree_gist IS 'support for indexing common datatypes in GiST';


          --
          -- Name: google_vacuum_mgmt; Type: EXTENSION; Schema: -; Owner: -
          --

          CREATE EXTENSION IF NOT EXISTS google_vacuum_mgmt WITH SCHEMA google_vacuum_mgmt;


          --
          -- Name: EXTENSION google_vacuum_mgmt; Type: COMMENT; Schema: -; Owner: -
          --

          COMMENT ON EXTENSION google_vacuum_mgmt IS 'extension for assistive operational tooling';


          --
          -- Name: shops; Type: TABLE; Schema: public; Owner: -
          --

          CREATE TABLE public.shops (
              id bigint NOT NULL
          );
        SQL
      end

      it 'removes the CREATE, the COMMENT and both pg_dump headers of a named extension' do
        out = described_class.strip_extensions(dump, %w[google_vacuum_mgmt])

        # Covers the statements and both `-- Name:` headers at once: not one
        # mention of the extension survives anywhere in the dump.
        expect(out).not_to include('google_vacuum_mgmt')
        expect(out).to include('CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA public;')
        expect(out).to include("COMMENT ON EXTENSION btree_gist IS 'support for indexing common datatypes in GiST';")
        expect(out).to include('CREATE TABLE public.shops (')
      end

      it 'keeps pg_dump spacing around the removal instead of leaving a gap' do
        out = described_class.strip_extensions(dump, %w[google_vacuum_mgmt])

        expect(out).not_to match(/\n{4,}/)
      end

      it 'removes every named extension and only those' do
        sql = <<~SQL
          CREATE EXTENSION IF NOT EXISTS google_columnar_engine WITH SCHEMA public;
          CREATE EXTENSION IF NOT EXISTS google_db_advisor WITH SCHEMA public;
          CREATE EXTENSION IF NOT EXISTS hypopg WITH SCHEMA public;
        SQL

        out = described_class.strip_extensions(sql, %w[google_columnar_engine google_db_advisor])

        expect(described_class.extension_names(out)).to eq(['hypopg'])
      end

      # Whole names only: an application is free to own an object whose name merely
      # starts with or contains a vendor one (a `google_calendar` integration), and
      # a vendor's own next version may extend the name.
      it 'leaves an extension whose name merely contains a listed one' do
        sql = <<~SQL
          CREATE EXTENSION IF NOT EXISTS not_google_vacuum_mgmt WITH SCHEMA public;
          CREATE EXTENSION IF NOT EXISTS google_vacuum_mgmt_v2 WITH SCHEMA public;
        SQL

        expect(described_class.strip_extensions(sql, %w[google_vacuum_mgmt])).to eq(sql)
      end

      it 'removes a quoted extension name' do
        sql = %(CREATE EXTENSION IF NOT EXISTS "google_vacuum_mgmt" WITH SCHEMA google_vacuum_mgmt;\n)

        expect(described_class.strip_extensions(sql, %w[google_vacuum_mgmt])).to eq('')
      end

      it 'returns the dump untouched when no name is given' do
        expect(described_class.strip_extensions(dump, [])).to eq(dump)
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
