SET session_replication_role = 'replica';
COPY shops (id, name, updated_at, created_at) FROM stdin;
1	Shop 1	2025-01-01 00:00:00	2025-01-01 00:00:00
\.
SELECT pg_catalog.setval('public.shops_id_seq', 5, true);
RESET session_replication_role;
