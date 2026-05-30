PRAGMA foreign_keys=OFF;
BEGIN TRANSACTION;
CREATE TABLE IF NOT EXISTS "shops" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "name" varchar NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL);
INSERT INTO shops VALUES(1,'Shop 1','2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO shops VALUES(2,'Shop 2','2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO shops VALUES(3,'Shop 3','2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO shops VALUES(4,'Shop 4','2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO shops VALUES(5,'Shop 5','2025-01-01 00:00:00','2025-01-01 00:00:00');
CREATE TABLE IF NOT EXISTS "users" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "name" varchar NOT NULL, "email" varchar NOT NULL, "shop_id" integer NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_a622b365a2"
FOREIGN KEY ("shop_id")
  REFERENCES "shops" ("id")
);
INSERT INTO users VALUES(1,'User 1','user1@example.com',1,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO users VALUES(2,'User 2','user2@example.com',1,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO users VALUES(3,'User 1','user1@example.com',2,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO users VALUES(4,'User 2','user2@example.com',2,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO users VALUES(5,'User 1','user1@example.com',3,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO users VALUES(6,'User 2','user2@example.com',3,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO users VALUES(7,'User 1','user1@example.com',4,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO users VALUES(8,'User 2','user2@example.com',4,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO users VALUES(9,'User 1','user1@example.com',5,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO users VALUES(10,'User 2','user2@example.com',5,'2025-01-01 00:00:00','2025-01-01 00:00:00');
CREATE TABLE IF NOT EXISTS "products" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "name" varchar NOT NULL, "price" decimal(10,2) NOT NULL, "shop_id" integer NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_b169a26347"
FOREIGN KEY ("shop_id")
  REFERENCES "shops" ("id")
);
INSERT INTO products VALUES(1,'Product 1',10,1,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO products VALUES(2,'Product 2',20,1,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO products VALUES(3,'Product 3',30,1,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO products VALUES(4,'Product 1',10,2,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO products VALUES(5,'Product 2',20,2,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO products VALUES(6,'Product 3',30,2,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO products VALUES(7,'Product 1',10,3,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO products VALUES(8,'Product 2',20,3,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO products VALUES(9,'Product 3',30,3,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO products VALUES(10,'Product 1',10,4,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO products VALUES(11,'Product 2',20,4,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO products VALUES(12,'Product 3',30,4,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO products VALUES(13,'Product 1',10,5,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO products VALUES(14,'Product 2',20,5,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO products VALUES(15,'Product 3',30,5,'2025-01-01 00:00:00','2025-01-01 00:00:00');
CREATE TABLE IF NOT EXISTS "orders" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "shop_id" integer NOT NULL, "user_id" integer NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_7e761c2e1b"
FOREIGN KEY ("shop_id")
  REFERENCES "shops" ("id")
, CONSTRAINT "fk_rails_f868b47f6a"
FOREIGN KEY ("user_id")
  REFERENCES "users" ("id")
);
INSERT INTO orders VALUES(1,1,1,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO orders VALUES(2,1,1,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO orders VALUES(3,1,1,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO orders VALUES(4,1,2,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO orders VALUES(5,1,2,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO orders VALUES(6,1,2,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO orders VALUES(7,2,3,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO orders VALUES(8,2,3,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO orders VALUES(9,2,3,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO orders VALUES(10,2,4,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO orders VALUES(11,2,4,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO orders VALUES(12,2,4,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO orders VALUES(13,3,5,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO orders VALUES(14,3,5,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO orders VALUES(15,3,5,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO orders VALUES(16,3,6,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO orders VALUES(17,3,6,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO orders VALUES(18,3,6,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO orders VALUES(19,4,7,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO orders VALUES(20,4,7,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO orders VALUES(21,4,7,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO orders VALUES(22,4,8,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO orders VALUES(23,4,8,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO orders VALUES(24,4,8,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO orders VALUES(25,5,9,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO orders VALUES(26,5,9,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO orders VALUES(27,5,9,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO orders VALUES(28,5,10,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO orders VALUES(29,5,10,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO orders VALUES(30,5,10,'2025-01-01 00:00:00','2025-01-01 00:00:00');
CREATE TABLE IF NOT EXISTS "order_items" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "order_id" integer NOT NULL, "product_id" integer NOT NULL, "quantity" integer DEFAULT 1 NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_e3cb28f071"
FOREIGN KEY ("order_id")
  REFERENCES "orders" ("id")
, CONSTRAINT "fk_rails_f1a29ddd47"
FOREIGN KEY ("product_id")
  REFERENCES "products" ("id")
);
INSERT INTO order_items VALUES(1,1,1,1,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO order_items VALUES(2,2,2,1,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO order_items VALUES(3,3,3,1,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO order_items VALUES(4,4,1,1,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO order_items VALUES(5,5,2,1,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO order_items VALUES(6,6,3,1,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO order_items VALUES(7,7,4,1,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO order_items VALUES(8,8,5,1,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO order_items VALUES(9,9,6,1,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO order_items VALUES(10,10,4,1,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO order_items VALUES(11,11,5,1,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO order_items VALUES(12,12,6,1,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO order_items VALUES(13,13,7,1,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO order_items VALUES(14,14,8,1,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO order_items VALUES(15,15,9,1,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO order_items VALUES(16,16,7,1,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO order_items VALUES(17,17,8,1,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO order_items VALUES(18,18,9,1,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO order_items VALUES(19,19,10,1,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO order_items VALUES(20,20,11,1,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO order_items VALUES(21,21,12,1,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO order_items VALUES(22,22,10,1,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO order_items VALUES(23,23,11,1,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO order_items VALUES(24,24,12,1,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO order_items VALUES(25,25,13,1,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO order_items VALUES(26,26,14,1,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO order_items VALUES(27,27,15,1,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO order_items VALUES(28,28,13,1,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO order_items VALUES(29,29,14,1,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO order_items VALUES(30,30,15,1,'2025-01-01 00:00:00','2025-01-01 00:00:00');
CREATE TABLE IF NOT EXISTS "transactions" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "order_id" integer NOT NULL, "type" varchar NOT NULL, "amount" decimal(10,2) NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_59d791a33f"
FOREIGN KEY ("order_id")
  REFERENCES "orders" ("id")
);
INSERT INTO transactions VALUES(1,1,'PaymentTransaction',10,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO transactions VALUES(2,2,'PaymentTransaction',20,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO transactions VALUES(3,3,'PaymentTransaction',30,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO transactions VALUES(4,4,'PaymentTransaction',10,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO transactions VALUES(5,5,'PaymentTransaction',20,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO transactions VALUES(6,6,'PaymentTransaction',30,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO transactions VALUES(7,7,'PaymentTransaction',10,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO transactions VALUES(8,8,'PaymentTransaction',20,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO transactions VALUES(9,9,'PaymentTransaction',30,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO transactions VALUES(10,10,'PaymentTransaction',10,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO transactions VALUES(11,11,'PaymentTransaction',20,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO transactions VALUES(12,12,'PaymentTransaction',30,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO transactions VALUES(13,13,'PaymentTransaction',10,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO transactions VALUES(14,14,'PaymentTransaction',20,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO transactions VALUES(15,15,'PaymentTransaction',30,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO transactions VALUES(16,16,'PaymentTransaction',10,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO transactions VALUES(17,17,'PaymentTransaction',20,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO transactions VALUES(18,18,'PaymentTransaction',30,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO transactions VALUES(19,19,'PaymentTransaction',10,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO transactions VALUES(20,20,'PaymentTransaction',20,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO transactions VALUES(21,21,'PaymentTransaction',30,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO transactions VALUES(22,22,'PaymentTransaction',10,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO transactions VALUES(23,23,'PaymentTransaction',20,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO transactions VALUES(24,24,'PaymentTransaction',30,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO transactions VALUES(25,25,'PaymentTransaction',10,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO transactions VALUES(26,26,'PaymentTransaction',20,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO transactions VALUES(27,27,'PaymentTransaction',30,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO transactions VALUES(28,28,'PaymentTransaction',10,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO transactions VALUES(29,29,'PaymentTransaction',20,'2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO transactions VALUES(30,30,'PaymentTransaction',30,'2025-01-01 00:00:00','2025-01-01 00:00:00');
CREATE TABLE IF NOT EXISTS "reviews" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "reviewable_type" varchar NOT NULL, "reviewable_id" integer NOT NULL, "user_id" integer NOT NULL, "rating" integer NOT NULL, "content" text NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL, CONSTRAINT "fk_rails_74a66bd6c5"
FOREIGN KEY ("user_id")
  REFERENCES "users" ("id")
);
INSERT INTO reviews VALUES(1,'Product',1,1,5,'Great product','2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO reviews VALUES(2,'Product',2,2,4,'Good product','2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO reviews VALUES(3,'Product',3,1,3,'Ok product','2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO reviews VALUES(4,'Product',4,3,5,'Other shop product','2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO reviews VALUES(5,'Shop',1,1,5,'A shop review, not a product','2025-01-01 00:00:00','2025-01-01 00:00:00');
CREATE TABLE IF NOT EXISTS "system_announcements" ("id" integer PRIMARY KEY AUTOINCREMENT NOT NULL, "title" varchar NOT NULL, "content" text NOT NULL, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL);
INSERT INTO system_announcements VALUES(1,'Announcement 1','This is the content of announcement 1.','2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO system_announcements VALUES(2,'Announcement 2','This is the content of announcement 2.','2025-01-01 00:00:00','2025-01-01 00:00:00');
INSERT INTO system_announcements VALUES(3,'Announcement 3','This is the content of announcement 3.','2025-01-01 00:00:00','2025-01-01 00:00:00');
CREATE TABLE IF NOT EXISTS "schema_migrations" ("version" varchar NOT NULL PRIMARY KEY);
CREATE TABLE IF NOT EXISTS "ar_internal_metadata" ("key" varchar NOT NULL PRIMARY KEY, "value" varchar, "created_at" datetime(6) NOT NULL, "updated_at" datetime(6) NOT NULL);
INSERT INTO ar_internal_metadata VALUES('environment','default_env','2025-02-11 05:56:22.715550','2025-02-11 05:56:22.715553');
DELETE FROM sqlite_sequence;
INSERT INTO sqlite_sequence VALUES('shops',5);
INSERT INTO sqlite_sequence VALUES('users',10);
INSERT INTO sqlite_sequence VALUES('products',15);
INSERT INTO sqlite_sequence VALUES('orders',30);
INSERT INTO sqlite_sequence VALUES('order_items',30);
INSERT INTO sqlite_sequence VALUES('transactions',30);
INSERT INTO sqlite_sequence VALUES('system_announcements',3);
INSERT INTO sqlite_sequence VALUES('reviews',5);
CREATE INDEX "index_users_on_shop_id" ON "users" ("shop_id");
CREATE INDEX "index_products_on_shop_id" ON "products" ("shop_id");
CREATE INDEX "index_orders_on_shop_id" ON "orders" ("shop_id");
CREATE INDEX "index_orders_on_user_id" ON "orders" ("user_id");
CREATE INDEX "index_order_items_on_order_id" ON "order_items" ("order_id");
CREATE INDEX "index_order_items_on_product_id" ON "order_items" ("product_id");
CREATE INDEX "index_transactions_on_order_id" ON "transactions" ("order_id");
CREATE INDEX "index_reviews_on_reviewable" ON "reviews" ("reviewable_type", "reviewable_id");
CREATE INDEX "index_reviews_on_user_id" ON "reviews" ("user_id");
COMMIT;
