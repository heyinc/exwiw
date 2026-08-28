require "active_record"

require_relative "./database_config"

adapter = ARGV.first

raise "Usage: ruby define_schema.rb <adapter>" unless adapter

config = database_config(adapter)

ActiveRecord::Base.establish_connection(config)

ActiveRecord::Schema.define do
  self.verbose = false

  create_table :shops, force: :cascade do |t|
    t.string :name, null: false
    t.timestamps
  end

  create_table :users, force: :cascade do |t|
    t.string :name, null: false
    t.string :email, null: false
    t.references :shop, null: false, foreign_key: true
    t.timestamps
  end

  create_table :products, force: :cascade do |t|
    t.string :name, null: false
    t.decimal :price, precision: 10, scale: 2, null: false
    t.references :shop, null: false, foreign_key: true
    t.timestamps
  end

  create_table :orders, force: :cascade do |t|
    t.references :shop, null: false, foreign_key: true
    t.references :user, null: false, foreign_key: true
    t.timestamps
  end

  create_table :order_items, force: :cascade do |t|
    t.references :order, null: false, foreign_key: true
    t.references :product, null: false, foreign_key: true
    t.integer :quantity, null: false, default: 1
    t.timestamps
  end

  create_table :transactions, force: :cascade do |t|
    t.references :order, null: false, foreign_key: true
    t.string :type, null: false
    t.decimal :amount, precision: 10, scale: 2, null: false
    t.timestamps
  end

  create_table :reviews, force: :cascade do |t|
    t.references :reviewable, polymorphic: true, null: false
    t.references :user, null: false, foreign_key: true
    t.integer :rating, null: false
    t.text :content, null: false
    t.timestamps
  end

  create_table :system_announcements, force: :cascade do |t|
    t.string :title, null: false
    t.text :content, null: false
    t.timestamps
  end
end

if adapter == "postgresql"
  conn = ActiveRecord::Base.connection
  conn.execute("CREATE EXTENSION IF NOT EXISTS btree_gist;")
  conn.execute(<<~SQL)
    DO $$ BEGIN
      CREATE TYPE public.user_role AS ENUM ('admin', 'member');
    EXCEPTION WHEN duplicate_object THEN NULL;
    END $$;
  SQL
  conn.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS role public.user_role;")
  conn.execute("ALTER TABLE shops ADD COLUMN IF NOT EXISTS owner_role public.user_role;")

  # A trigger in the seed keeps the schema dump's trigger handling covered by the
  # scenario tests. It executes the built-in suppress_redundant_updates_trigger()
  # so the dump needs no CREATE FUNCTION of its own: pg_dump's bare
  # `CREATE FUNCTION` is not re-appliable, which would fail
  # e2e/test_with_postgresql.sh (it applies the schema to an already-seeded
  # target) for a reason unrelated to triggers. BEFORE UPDATE also keeps it from
  # firing during the insert-only restore.
  conn.execute("DROP TRIGGER IF EXISTS suppress_redundant_user_updates ON users;")
  conn.execute(<<~SQL)
    CREATE TRIGGER suppress_redundant_user_updates
      BEFORE UPDATE ON users FOR EACH ROW
      EXECUTE FUNCTION suppress_redundant_updates_trigger();
  SQL
end
