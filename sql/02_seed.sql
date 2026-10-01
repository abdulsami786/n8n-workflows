-- =====================================================================
-- LeadOps · settings, team and routing rules (EDIT ME)
-- Run with:  psql -v tz="Asia/Dubai" -v school="Your School" -f 02_seed.sql
-- Safe to re-run: existing rows are kept (edit them in the table later).
-- =====================================================================
\if :{?tz}
\else
  \set tz 'Asia/Dubai'
\endif
\if :{?school}
\else
  \set school 'Palm Crescent International School'
\endif

INSERT INTO leadops.settings (key, value, note) VALUES
  ('timezone',            :'tz',     'IANA timezone used for routing and reporting'),
  ('school_name',         :'school', 'Shown in notifications, lead page and dashboard'),
  ('dedupe_window_hours', '24',      'Same family again inside this window = merged into the open inquiry, no new alert')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value
  WHERE leadops.settings.key IN ('timezone', 'school_name');

-- Team. Put real Telegram chat IDs / emails here (see docs/SETUP.md, step 6).
INSERT INTO leadops.agents (code, name, role, languages, telegram_chat_id, email) VALUES
  ('sara', 'Sara Haddad',  'admissions', '{en,ar}', NULL, 'sara@example.com'),
  ('omar', 'Omar Khalil',  'admissions', '{ar,en}', NULL, 'omar@example.com'),
  ('lina', 'Lina Mansour', 'duty',       '{en,ar}', NULL, 'lina@example.com'),
  ('head', 'Nadia Farouk', 'manager',    '{en,ar}', NULL, 'head@example.com')
ON CONFLICT (code) DO NOTHING;

-- Routing rules. Lower priority number wins. days: ISO 1=Mon ... 7=Sun.
-- UAE private schools work Mon-Fri; for KSA/Qatar use {7,1,2,3,4} (Sun-Thu).
INSERT INTO leadops.routing_rules
  (name, priority, days, start_time, end_time, language, agent_ids,
   sla_minutes, reminder_every_minutes, max_reminders, escalate_to_agent_id, is_after_hours)
VALUES
  ('School hours - Arabic', 10, '{1,2,3,4,5}', '07:30', '15:30', 'ar',
     ARRAY(SELECT id FROM leadops.agents WHERE code IN ('omar','sara') ORDER BY code = 'sara'),
     10, 5, 2, (SELECT id FROM leadops.agents WHERE code = 'head'), false),
  ('School hours', 20, '{1,2,3,4,5}', '07:30', '15:30', NULL,
     ARRAY(SELECT id FROM leadops.agents WHERE code IN ('sara','omar')),
     10, 5, 2, (SELECT id FROM leadops.agents WHERE code = 'head'), false),
  ('Evening duty', 30, '{1,2,3,4,5}', '15:30', '21:00', NULL,
     ARRAY(SELECT id FROM leadops.agents WHERE code = 'lina'),
     20, 10, 2, (SELECT id FROM leadops.agents WHERE code = 'head'), false),
  ('Weekend duty', 40, '{6,7}', '09:00', '18:00', NULL,
     ARRAY(SELECT id FROM leadops.agents WHERE code = 'lina'),
     30, 15, 1, (SELECT id FROM leadops.agents WHERE code = 'head'), false),
  ('After hours', 90, '{1,2,3,4,5,6,7}', '00:00', '00:00', NULL,
     ARRAY(SELECT id FROM leadops.agents WHERE code = 'lina'),
     720, 120, 0, NULL, true)
ON CONFLICT (name) DO NOTHING;
