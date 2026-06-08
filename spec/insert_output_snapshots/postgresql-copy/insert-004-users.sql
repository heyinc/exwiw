SET session_replication_role = 'replica';
COPY users (id, name, email, shop_id, updated_at, created_at, role) FROM stdin;
1	masked1	masked1@example.com	1	2025-01-01 00:00:00	2025-01-01 00:00:00	\N
2	masked2	masked2@example.com	1	2025-01-01 00:00:00	2025-01-01 00:00:00	\N
\.
SELECT pg_catalog.setval('public.users_id_seq', 10, true);
RESET session_replication_role;
