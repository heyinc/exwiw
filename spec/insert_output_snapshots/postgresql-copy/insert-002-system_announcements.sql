DO $exwiw$ BEGIN
  PERFORM set_config('session_replication_role', 'replica', false);
EXCEPTION WHEN insufficient_privilege THEN
  RAISE WARNING 'exwiw: could not disable triggers for the load (%): %', SQLSTATE, SQLERRM;
END $exwiw$;
COPY system_announcements (id, title, content, updated_at, created_at) FROM stdin;
1	Announcement 1	This is the content of announcement 1.	2025-01-01 00:00:00	2025-01-01 00:00:00
2	Announcement 2	This is the content of announcement 2.	2025-01-01 00:00:00	2025-01-01 00:00:00
3	Announcement 3	This is the content of announcement 3.	2025-01-01 00:00:00	2025-01-01 00:00:00
\.
SELECT pg_catalog.setval('public.system_announcements_id_seq', 3, true);
