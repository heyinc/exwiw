DO $exwiw$ BEGIN
  PERFORM set_config('session_replication_role', 'replica', false);
EXCEPTION WHEN insufficient_privilege THEN
  RAISE WARNING 'exwiw: could not disable triggers for the load (%): %', SQLSTATE, SQLERRM;
END $exwiw$;
COPY products (id, name, price, shop_id, updated_at, created_at) FROM stdin;
1	product-1-masked	10.00	1	2025-01-01 00:00:00	2025-01-01 00:00:00
2	product-2-masked	20.00	1	2025-01-01 00:00:00	2025-01-01 00:00:00
3	product-3-masked	30.00	1	2025-01-01 00:00:00	2025-01-01 00:00:00
\.
SELECT pg_catalog.setval('public.products_id_seq', 15, true);
