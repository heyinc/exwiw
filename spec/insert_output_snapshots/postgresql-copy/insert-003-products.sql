SET session_replication_role = 'replica';
COPY products (id, name, price, shop_id, updated_at, created_at) FROM stdin;
1	Product 1	10.00	1	2025-01-01 00:00:00	2025-01-01 00:00:00
2	Product 2	20.00	1	2025-01-01 00:00:00	2025-01-01 00:00:00
3	Product 3	30.00	1	2025-01-01 00:00:00	2025-01-01 00:00:00
\.
SELECT pg_catalog.setval('public.products_id_seq', 15, true);
SET session_replication_role = 'DEFAULT';
