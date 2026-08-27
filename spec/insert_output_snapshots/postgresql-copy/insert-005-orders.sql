DO $exwiw$ BEGIN
  PERFORM set_config('session_replication_role', 'replica', false);
EXCEPTION WHEN insufficient_privilege THEN
  RAISE WARNING 'exwiw: could not disable triggers for the load (%): %', SQLSTATE, SQLERRM;
END $exwiw$;
COPY orders (id, shop_id, user_id, updated_at, created_at) FROM stdin;
3	1	1	2025-01-01 00:00:00	2025-01-01 00:00:00
4	1	2	2025-01-01 00:00:00	2025-01-01 00:00:00
5	1	2	2025-01-01 00:00:00	2025-01-01 00:00:00
6	1	2	2025-01-01 00:00:00	2025-01-01 00:00:00
\.
SELECT pg_catalog.setval('public.orders_id_seq', 30, true);
