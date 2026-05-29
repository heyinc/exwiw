INSERT INTO system_announcements (id, title, content, updated_at, created_at) VALUES
('1', 'Announcement 1', 'This is the content of announcement 1.', '2025-01-01 00:00:00', '2025-01-01 00:00:00'),
('2', 'Announcement 2', 'This is the content of announcement 2.', '2025-01-01 00:00:00', '2025-01-01 00:00:00'),
('3', 'Announcement 3', 'This is the content of announcement 3.', '2025-01-01 00:00:00', '2025-01-01 00:00:00');
SELECT pg_catalog.setval('public.system_announcements_id_seq', 3, true);
