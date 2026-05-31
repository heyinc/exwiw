CREATE TABLE IF NOT EXISTS "shops" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "name" varchar NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL);
CREATE TABLE sqlite_sequence(name,seq);
CREATE TABLE IF NOT EXISTS "users" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "name" varchar NOT NULL, "email" varchar NOT NULL, "shop_id" integer NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_a622b365a2"
FOREIGN KEY ("shop_id")
  REFERENCES "shops" ("id")
);
CREATE INDEX "index_users_on_shop_id" ON "users" ("shop_id");
CREATE TABLE IF NOT EXISTS "products" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "name" varchar NOT NULL, "price" decimal(10,2) NOT NULL, "shop_id" integer NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_b169a26347"
FOREIGN KEY ("shop_id")
  REFERENCES "shops" ("id")
);
CREATE INDEX "index_products_on_shop_id" ON "products" ("shop_id");
CREATE TABLE IF NOT EXISTS "orders" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "shop_id" integer NOT NULL, "user_id" integer NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_7e761c2e1b"
FOREIGN KEY ("shop_id")
  REFERENCES "shops" ("id")
, CONSTRAINT "fk_rails_f868b47f6a"
FOREIGN KEY ("user_id")
  REFERENCES "users" ("id")
);
CREATE INDEX "index_orders_on_shop_id" ON "orders" ("shop_id");
CREATE INDEX "index_orders_on_user_id" ON "orders" ("user_id");
CREATE TABLE IF NOT EXISTS "order_items" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "order_id" integer NOT NULL, "product_id" integer NOT NULL, "quantity" integer DEFAULT 1 NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_e3cb28f071"
FOREIGN KEY ("order_id")
  REFERENCES "orders" ("id")
, CONSTRAINT "fk_rails_f1a29ddd47"
FOREIGN KEY ("product_id")
  REFERENCES "products" ("id")
);
CREATE INDEX "index_order_items_on_order_id" ON "order_items" ("order_id");
CREATE INDEX "index_order_items_on_product_id" ON "order_items" ("product_id");
CREATE TABLE IF NOT EXISTS "transactions" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "order_id" integer NOT NULL, "type" varchar NOT NULL, "amount" decimal(10,2) NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_59d791a33f"
FOREIGN KEY ("order_id")
  REFERENCES "orders" ("id")
);
CREATE INDEX "index_transactions_on_order_id" ON "transactions" ("order_id");
CREATE TABLE IF NOT EXISTS "reviews" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "reviewable_type" varchar NOT NULL, "reviewable_id" integer NOT NULL, "user_id" integer NOT NULL, "rating" integer NOT NULL, "content" text NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_74a66bd6c5"
FOREIGN KEY ("user_id")
  REFERENCES "users" ("id")
);
CREATE INDEX "index_reviews_on_reviewable" ON "reviews" ("reviewable_type", "reviewable_id");
CREATE INDEX "index_reviews_on_user_id" ON "reviews" ("user_id");
CREATE TABLE IF NOT EXISTS "system_announcements" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "title" varchar NOT NULL, "content" text NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL);
CREATE TABLE IF NOT EXISTS "schema_migrations" ("version" varchar NOT NULL PRIMARY KEY);
CREATE TABLE IF NOT EXISTS "ar_internal_metadata" ("key" varchar NOT NULL PRIMARY KEY, "value" varchar, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL);
