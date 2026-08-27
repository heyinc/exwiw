DO $exwiw$ BEGIN
  PERFORM set_config('session_replication_role', 'replica', false);
EXCEPTION WHEN insufficient_privilege THEN
  RAISE WARNING 'exwiw: could not disable triggers for the load (%): %', SQLSTATE, SQLERRM;
END $exwiw$;
INSERT INTO shops (id, name, updated_at, created_at) VALUES
('1', 'Shop 1', '2025-01-01 00:00:00', '2025-01-01 00:00:00');
SELECT pg_catalog.setval('public.shops_id_seq', 5, true);
