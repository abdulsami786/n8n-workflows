-- =====================================================================
-- LeadOps · Phase 1 · database schema
-- Postgres 14+ (tested on 16). Idempotent: safe to re-run on upgrades.
--
-- Design notes
--  * inbox      = every raw inbound event, stored BEFORE we answer the
--                 sender (Meta / website). Nothing is ever lost, and every
--                 event can be replayed.
--  * leads      = one row per real family (identity = phone OR email).
--  * inquiries  = one row per inquiry (a family can inquire many times).
--  * Identity resolution, routing and SLA bookkeeping live here in SQL
--    because they must be atomic: Meta delivers the same lead twice in
--    parallel more often than you would think.
-- =====================================================================
CREATE SCHEMA IF NOT EXISTS leadops;

-- ---------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS leadops.settings (
  key   text PRIMARY KEY,
  value text NOT NULL,
  note  text
);

CREATE OR REPLACE FUNCTION leadops.setting(p_key text, p_default text DEFAULT NULL)
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT coalesce((SELECT value FROM leadops.settings WHERE key = p_key), p_default)
$$;

CREATE TABLE IF NOT EXISTS leadops.agents (
  id               serial PRIMARY KEY,
  code             text NOT NULL UNIQUE,            -- short handle used in links, e.g. 'sara'
  name             text NOT NULL,
  role             text NOT NULL DEFAULT 'admissions'
                   CHECK (role IN ('admissions','duty','manager')),
  languages        text[] NOT NULL DEFAULT '{en}',
  telegram_chat_id text,
  email            text,
  phone            text,
  active           boolean NOT NULL DEFAULT true,
  created_at       timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS leadops.routing_rules (
  id                     serial PRIMARY KEY,
  name                   text NOT NULL UNIQUE,
  priority               int  NOT NULL DEFAULT 100,   -- lower number wins
  days                   int[] NOT NULL,               -- ISO weekday 1=Mon ... 7=Sun
  start_time             time NOT NULL,
  end_time               time NOT NULL,                -- end < start: crosses midnight; end = start: all day
  language               text,                         -- NULL = any language
  channel                text,                         -- NULL = any channel
  agent_ids              int[] NOT NULL,               -- pool; least-loaded active agent is picked
  sla_minutes            int  NOT NULL DEFAULT 15,
  reminder_every_minutes int  NOT NULL DEFAULT 10,
  max_reminders          int  NOT NULL DEFAULT 2,
  escalate_to_agent_id   int REFERENCES leadops.agents(id),
  is_after_hours         boolean NOT NULL DEFAULT false,
  active                 boolean NOT NULL DEFAULT true
);

-- ---------------------------------------------------------------------
-- Durable inbox (at-least-once processing, replayable)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS leadops.inbox (
  id            bigserial PRIMARY KEY,
  source        text NOT NULL CHECK (source IN ('meta','web','whatsapp','manual')),
  event_key     text NOT NULL,                      -- idempotency key (leadgen_id / submission id)
  payload       jsonb NOT NULL,
  status        text NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending','processing','done','failed','dead')),
  attempts      int  NOT NULL DEFAULT 0,
  next_retry_at timestamptz,
  locked_at     timestamptz,
  last_error    text,
  inquiry_id    bigint,
  received_at   timestamptz NOT NULL DEFAULT now(),
  processed_at  timestamptz,
  CONSTRAINT inbox_source_event_uq UNIQUE (source, event_key)
);
CREATE INDEX IF NOT EXISTS inbox_retry_idx
  ON leadops.inbox (status, next_retry_at) WHERE status IN ('pending','processing','failed');

-- ---------------------------------------------------------------------
-- Families and inquiries
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS leadops.leads (
  id             bigserial PRIMARY KEY,
  full_name      text,
  first_name     text,
  last_name      text,
  phone_e164     text,
  email_norm     text,
  language       text,
  first_channel  text,
  first_campaign text,
  owner_agent_id int REFERENCES leadops.agents(id),
  crm_record_id  text,
  is_demo        boolean NOT NULL DEFAULT false,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS leads_phone_uq ON leadops.leads (phone_e164) WHERE phone_e164 IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS leads_email_uq ON leadops.leads (email_norm) WHERE email_norm IS NOT NULL;

CREATE TABLE IF NOT EXISTS leadops.inquiries (
  id                bigserial PRIMARY KEY,
  public_token      uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,   -- used in staff links
  lead_id           bigint NOT NULL REFERENCES leadops.leads(id) ON DELETE CASCADE,
  inbox_id          bigint UNIQUE REFERENCES leadops.inbox(id) ON DELETE SET NULL,
  channel           text NOT NULL,                   -- meta | web | whatsapp
  source_detail     text,
  campaign_id       text,
  campaign_name     text,
  adset_name        text,
  ad_name           text,
  form_id           text,
  form_name         text,
  platform          text,
  utm_source        text,
  utm_medium        text,
  utm_campaign      text,
  utm_content       text,
  utm_term          text,
  gclid             text,
  fbclid            text,
  page_url          text,
  language          text,
  message           text,
  answers           jsonb NOT NULL DEFAULT '{}'::jsonb,
  is_repeat         boolean NOT NULL DEFAULT false,  -- family seen before
  duplicate_of      bigint REFERENCES leadops.inquiries(id) ON DELETE SET NULL,
  status            text NOT NULL DEFAULT 'new'
                    CHECK (status IN ('new','notified','claimed','contacted','merged')),
  submitted_at      timestamptz NOT NULL DEFAULT now(),
  received_at       timestamptz NOT NULL DEFAULT now(),
  crm_synced_at     timestamptz,
  crm_record_id     text,
  routing_rule_id   int REFERENCES leadops.routing_rules(id),
  assigned_agent_id int REFERENCES leadops.agents(id),
  after_hours       boolean NOT NULL DEFAULT false,
  sla_due_at        timestamptz,
  notified_at       timestamptz,
  reminder_count    int NOT NULL DEFAULT 0,
  last_reminder_at  timestamptz,
  escalated_at      timestamptz,
  claimed_at        timestamptz,
  claimed_by        int REFERENCES leadops.agents(id),
  contacted_at      timestamptz,
  is_test           boolean NOT NULL DEFAULT false,
  is_demo           boolean NOT NULL DEFAULT false
);
CREATE INDEX IF NOT EXISTS inquiries_received_idx ON leadops.inquiries (received_at);
CREATE INDEX IF NOT EXISTS inquiries_open_idx ON leadops.inquiries (status) WHERE status IN ('new','notified');
CREATE INDEX IF NOT EXISTS inquiries_lead_idx ON leadops.inquiries (lead_id, received_at DESC);

CREATE TABLE IF NOT EXISTS leadops.events (
  id         bigserial PRIMARY KEY,
  inquiry_id bigint,
  lead_id    bigint,
  inbox_id   bigint,
  agent_id   int,
  type       text NOT NULL,
  detail     jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS events_inquiry_idx ON leadops.events (inquiry_id, created_at);

CREATE TABLE IF NOT EXISTS leadops.oauth_tokens (
  provider     text PRIMARY KEY,
  access_token text NOT NULL,
  expires_at   timestamptz NOT NULL,
  updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS leadops.alerts (
  id          bigserial PRIMARY KEY,
  fingerprint text NOT NULL,
  severity    text NOT NULL DEFAULT 'error',
  title       text NOT NULL,
  detail      text,
  suppressed  boolean NOT NULL DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS alerts_fp_idx ON leadops.alerts (fingerprint, created_at DESC);

-- Handy view with derived metrics (minutes, local time, SLA outcome)
CREATE OR REPLACE VIEW leadops.v_inquiries AS
SELECT i.*,
       (i.received_at AT TIME ZONE leadops.setting('timezone', 'Asia/Dubai')) AS local_ts,
       extract(epoch FROM (i.claimed_at   - i.received_at)) / 60.0 AS claim_min,
       extract(epoch FROM (i.contacted_at - i.received_at)) / 60.0 AS contact_min,
       (i.claimed_at IS NOT NULL AND i.sla_due_at IS NOT NULL AND i.claimed_at <= i.sla_due_at) AS in_sla,
       (i.sla_due_at IS NOT NULL AND (i.claimed_at IS NOT NULL OR i.sla_due_at < now())) AS sla_decided
FROM leadops.inquiries i;

-- =====================================================================
-- inquiry_json: everything a notification / page needs, in one object
-- =====================================================================
CREATE OR REPLACE FUNCTION leadops.inquiry_json(p_id bigint)
RETURNS jsonb LANGUAGE sql STABLE AS $$
SELECT jsonb_build_object(
  'inquiry_id', i.id, 'public_token', i.public_token, 'status', i.status, 'channel', i.channel,
  'source_detail', i.source_detail, 'campaign_name', i.campaign_name, 'adset_name', i.adset_name,
  'ad_name', i.ad_name, 'form_name', i.form_name, 'platform', i.platform,
  'utm_source', i.utm_source, 'utm_medium', i.utm_medium, 'utm_campaign', i.utm_campaign,
  'page_url', i.page_url, 'language', i.language, 'message', i.message, 'answers', i.answers,
  'is_repeat', i.is_repeat, 'duplicate_of', i.duplicate_of, 'is_test', i.is_test,
  'submitted_at', i.submitted_at, 'received_at', i.received_at, 'sla_due_at', i.sla_due_at,
  'notified_at', i.notified_at, 'reminder_count', i.reminder_count, 'escalated_at', i.escalated_at,
  'claimed_at', i.claimed_at, 'contacted_at', i.contacted_at, 'after_hours', i.after_hours,
  'crm_synced_at', i.crm_synced_at, 'crm_record_id', coalesce(i.crm_record_id, l.crm_record_id),
  'minutes_open', round((extract(epoch FROM (coalesce(i.claimed_at, now()) - i.received_at)) / 60.0)::numeric, 1),
  'lead', jsonb_build_object(
      'lead_id', l.id, 'full_name', l.full_name, 'first_name', l.first_name, 'last_name', l.last_name,
      'phone_e164', l.phone_e164, 'email', l.email_norm, 'language', l.language,
      'first_channel', l.first_channel, 'first_campaign', l.first_campaign,
      'crm_record_id', l.crm_record_id, 'owner_agent_id', l.owner_agent_id, 'created_at', l.created_at,
      'inquiry_count', (SELECT count(*) FROM leadops.inquiries x WHERE x.lead_id = l.id)),
  'history', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                 'inquiry_id', h.id, 'channel', h.channel, 'campaign_name', h.campaign_name,
                 'received_at', h.received_at, 'status', h.status) ORDER BY h.received_at DESC), '[]'::jsonb)
              FROM (SELECT * FROM leadops.inquiries hh
                     WHERE hh.lead_id = l.id AND hh.id <> i.id
                     ORDER BY hh.received_at DESC LIMIT 5) h),
  'assigned_agent', (SELECT jsonb_build_object('id', a.id, 'code', a.code, 'name', a.name, 'role', a.role,
                            'telegram_chat_id', a.telegram_chat_id, 'email', a.email)
                     FROM leadops.agents a WHERE a.id = i.assigned_agent_id),
  'claimed_by', (SELECT jsonb_build_object('id', a.id, 'code', a.code, 'name', a.name)
                 FROM leadops.agents a WHERE a.id = i.claimed_by),
  'rule', (SELECT jsonb_build_object('id', r.id, 'name', r.name, 'sla_minutes', r.sla_minutes,
                  'is_after_hours', r.is_after_hours, 'escalate_to_agent_id', r.escalate_to_agent_id)
           FROM leadops.routing_rules r WHERE r.id = i.routing_rule_id)
)
FROM leadops.inquiries i
JOIN leadops.leads l ON l.id = i.lead_id
WHERE i.id = p_id
$$;

-- =====================================================================
-- upsert_inquiry: identity resolution + dedupe + inquiry creation
-- Input: normalized lead JSON from the n8n "Normalize" node.
-- Idempotent per inbox event (safe to retry).
-- =====================================================================
CREATE OR REPLACE FUNCTION leadops.upsert_inquiry(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_inbox_id  bigint := nullif(p->>'inbox_id', '')::bigint;
  v_phone     text   := nullif(trim(p->>'phone_e164'), '');
  v_email     text   := nullif(lower(trim(p->>'email')), '');
  v_window    interval := make_interval(hours => coalesce(leadops.setting('dedupe_window_hours', '24')::int, 24));
  v_lead      leadops.leads%ROWTYPE;
  v_prev      leadops.inquiries%ROWTYPE;
  v_inq_id    bigint;
  v_new_lead  boolean := false;
BEGIN
  -- 0) Already created for this inbox event? (retry after a later step failed)
  IF v_inbox_id IS NOT NULL THEN
    SELECT id INTO v_inq_id FROM leadops.inquiries WHERE inbox_id = v_inbox_id;
    IF v_inq_id IS NOT NULL THEN
      RETURN leadops.inquiry_json(v_inq_id) || jsonb_build_object('replayed', true, 'is_new_lead', false);
    END IF;
  END IF;

  IF v_phone IS NULL AND v_email IS NULL THEN
    RAISE EXCEPTION 'Inquiry has neither a valid phone nor a valid email (inbox %)', v_inbox_id;
  END IF;

  -- 1) Serialize identity resolution (cheap at school volumes, removes all races)
  PERFORM pg_advisory_xact_lock(hashtext('leadops.identity'));

  -- 2) Match an existing family: phone first, then email
  IF v_phone IS NOT NULL THEN
    SELECT * INTO v_lead FROM leadops.leads WHERE phone_e164 = v_phone;
  END IF;
  IF v_lead.id IS NULL AND v_email IS NOT NULL THEN
    SELECT * INTO v_lead FROM leadops.leads WHERE email_norm = v_email;
  END IF;

  IF v_lead.id IS NULL THEN
    INSERT INTO leadops.leads (full_name, first_name, last_name, phone_e164, email_norm, language,
                               first_channel, first_campaign)
    VALUES (nullif(p->>'full_name',''), nullif(p->>'first_name',''), nullif(p->>'last_name',''),
            v_phone, v_email, nullif(p->>'language',''), p->>'channel', nullif(p->>'campaign_name',''))
    RETURNING * INTO v_lead;
    v_new_lead := true;
  ELSE
    -- Fill blanks only; never overwrite what staff may already have corrected.
    UPDATE leadops.leads SET
      phone_e164 = coalesce(phone_e164, CASE WHEN v_phone IS NOT NULL AND NOT EXISTS
                     (SELECT 1 FROM leadops.leads x WHERE x.phone_e164 = v_phone) THEN v_phone END),
      email_norm = coalesce(email_norm, CASE WHEN v_email IS NOT NULL AND NOT EXISTS
                     (SELECT 1 FROM leadops.leads x WHERE x.email_norm = v_email) THEN v_email END),
      full_name  = coalesce(full_name,  nullif(p->>'full_name','')),
      first_name = coalesce(first_name, nullif(p->>'first_name','')),
      last_name  = coalesce(last_name,  nullif(p->>'last_name','')),
      language   = coalesce(language,   nullif(p->>'language','')),
      updated_at = now()
    WHERE id = v_lead.id
    RETURNING * INTO v_lead;
  END IF;

  -- 3) Same family inquired again inside the dedupe window? -> merge (no new alert)
  SELECT * INTO v_prev FROM leadops.inquiries
   WHERE lead_id = v_lead.id AND duplicate_of IS NULL
     AND received_at > now() - v_window
   ORDER BY received_at DESC LIMIT 1;

  INSERT INTO leadops.inquiries (
      lead_id, inbox_id, channel, source_detail, campaign_id, campaign_name, adset_name, ad_name,
      form_id, form_name, platform, utm_source, utm_medium, utm_campaign, utm_content, utm_term,
      gclid, fbclid, page_url, language, message, answers, is_repeat, duplicate_of, status,
      submitted_at, is_test)
  VALUES (
      v_lead.id, v_inbox_id, coalesce(p->>'channel','web'), nullif(p->>'source_detail',''),
      nullif(p->>'campaign_id',''), nullif(p->>'campaign_name',''), nullif(p->>'adset_name',''),
      nullif(p->>'ad_name',''), nullif(p->>'form_id',''), nullif(p->>'form_name',''),
      nullif(p->>'platform',''), nullif(p->>'utm_source',''), nullif(p->>'utm_medium',''),
      nullif(p->>'utm_campaign',''), nullif(p->>'utm_content',''), nullif(p->>'utm_term',''),
      nullif(p->>'gclid',''), nullif(p->>'fbclid',''), nullif(p->>'page_url',''),
      coalesce(nullif(p->>'language',''), v_lead.language), nullif(p->>'message',''),
      coalesce(p->'answers', '{}'::jsonb), NOT v_new_lead, v_prev.id,
      CASE WHEN v_prev.id IS NOT NULL THEN 'merged' ELSE 'new' END,
      coalesce(nullif(p->>'submitted_at','')::timestamptz, now()),
      coalesce((p->>'is_test')::boolean, false))
  RETURNING id INTO v_inq_id;

  INSERT INTO leadops.events (inquiry_id, lead_id, inbox_id, type, detail)
  VALUES (v_inq_id, v_lead.id, v_inbox_id,
          CASE WHEN v_prev.id IS NOT NULL THEN 'merged_duplicate' ELSE 'received' END,
          jsonb_build_object('channel', p->>'channel', 'campaign', p->>'campaign_name',
                             'new_lead', v_new_lead, 'duplicate_of', v_prev.id));

  IF v_inbox_id IS NOT NULL THEN
    UPDATE leadops.inbox SET inquiry_id = v_inq_id WHERE id = v_inbox_id;
  END IF;

  RETURN leadops.inquiry_json(v_inq_id) || jsonb_build_object('replayed', false, 'is_new_lead', v_new_lead);
END $$;

-- =====================================================================
-- Routing: which rule applies at this local time, and which agent
-- =====================================================================
CREATE OR REPLACE FUNCTION leadops.rule_matches(r leadops.routing_rules, p_local timestamp,
                                                p_lang text, p_channel text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT r.active
     AND extract(isodow FROM p_local)::int = ANY (r.days)
     AND (   r.start_time = r.end_time
          OR (r.start_time < r.end_time AND p_local::time >= r.start_time AND p_local::time < r.end_time)
          OR (r.start_time > r.end_time AND (p_local::time >= r.start_time OR p_local::time < r.end_time)))
     AND (r.language IS NULL OR r.language = p_lang)
     AND (r.channel  IS NULL OR r.channel  = p_channel)
$$;

CREATE OR REPLACE FUNCTION leadops.route_inquiry(p_inquiry_id bigint)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_inq    leadops.inquiries%ROWTYPE;
  v_lead   leadops.leads%ROWTYPE;
  v_rule   leadops.routing_rules%ROWTYPE;
  v_local  timestamp;
  v_agent  int;
  v_sticky boolean := false;
BEGIN
  SELECT * INTO v_inq FROM leadops.inquiries WHERE id = p_inquiry_id FOR UPDATE;
  IF v_inq.id IS NULL THEN
    RAISE EXCEPTION 'Inquiry % not found', p_inquiry_id;
  END IF;
  -- Idempotent: already routed, or merged into another inquiry
  IF v_inq.assigned_agent_id IS NOT NULL OR v_inq.status = 'merged' THEN
    RETURN leadops.inquiry_json(p_inquiry_id);
  END IF;

  SELECT * INTO v_lead FROM leadops.leads WHERE id = v_inq.lead_id;
  v_local := v_inq.received_at AT TIME ZONE leadops.setting('timezone', 'Asia/Dubai');

  SELECT r.* INTO v_rule FROM leadops.routing_rules r
   WHERE leadops.rule_matches(r, v_local, v_inq.language, v_inq.channel)
   ORDER BY r.priority, r.id LIMIT 1;
  IF v_rule.id IS NULL THEN
    RAISE EXCEPTION 'No routing rule matches inquiry % (local time %, language %, channel %)',
      p_inquiry_id, v_local, v_inq.language, v_inq.channel;
  END IF;

  -- Returning family: keep them with the colleague who handled them before
  IF v_lead.owner_agent_id IS NOT NULL AND v_lead.owner_agent_id = ANY (v_rule.agent_ids)
     AND EXISTS (SELECT 1 FROM leadops.agents a WHERE a.id = v_lead.owner_agent_id AND a.active) THEN
    v_agent := v_lead.owner_agent_id;
    v_sticky := true;
  ELSE
    -- Least open work first, then whoever was notified least recently
    SELECT a.id INTO v_agent
      FROM leadops.agents a
     WHERE a.id = ANY (v_rule.agent_ids) AND a.active
     ORDER BY (SELECT count(*) FROM leadops.inquiries o
                WHERE o.assigned_agent_id = a.id AND o.status IN ('new','notified')),
              (SELECT max(o.notified_at) FROM leadops.inquiries o WHERE o.assigned_agent_id = a.id) NULLS FIRST,
              a.id
     LIMIT 1;
  END IF;
  IF v_agent IS NULL THEN
    RAISE EXCEPTION 'Routing rule "%" has no active agents', v_rule.name;
  END IF;

  UPDATE leadops.inquiries SET
    routing_rule_id   = v_rule.id,
    assigned_agent_id = v_agent,
    after_hours       = v_rule.is_after_hours,
    sla_due_at        = received_at + make_interval(mins => v_rule.sla_minutes)
  WHERE id = p_inquiry_id;

  INSERT INTO leadops.events (inquiry_id, lead_id, agent_id, type, detail)
  VALUES (p_inquiry_id, v_inq.lead_id, v_agent, 'routed',
          jsonb_build_object('rule', v_rule.name, 'sticky_owner', v_sticky, 'local_time', v_local));

  RETURN leadops.inquiry_json(p_inquiry_id);
END $$;

-- =====================================================================
-- Staff actions from the lead page (claim / contacted / view)
-- =====================================================================
CREATE OR REPLACE FUNCTION leadops.lead_action(p_token text, p_action text, p_agent_code text)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_inq    leadops.inquiries%ROWTYPE;
  v_agent  leadops.agents%ROWTYPE;
  v_result text := 'viewed';
BEGIN
  IF p_token IS NULL OR p_token !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    RETURN jsonb_build_object('found', false, 'result', 'invalid_link');
  END IF;

  SELECT * INTO v_inq FROM leadops.inquiries WHERE public_token = p_token::uuid FOR UPDATE;
  IF v_inq.id IS NULL THEN
    RETURN jsonb_build_object('found', false, 'result', 'not_found');
  END IF;
  -- A merged duplicate always points staff at the original inquiry
  IF v_inq.status = 'merged' AND v_inq.duplicate_of IS NOT NULL THEN
    SELECT * INTO v_inq FROM leadops.inquiries WHERE id = v_inq.duplicate_of FOR UPDATE;
  END IF;

  SELECT * INTO v_agent FROM leadops.agents WHERE code = lower(coalesce(p_agent_code, '')) AND active;

  IF p_action IN ('claim', 'contacted') AND v_inq.claimed_at IS NULL THEN
    UPDATE leadops.inquiries SET status = 'claimed', claimed_at = now(), claimed_by = v_agent.id
     WHERE id = v_inq.id;
    UPDATE leadops.leads SET owner_agent_id = coalesce(owner_agent_id, v_agent.id), updated_at = now()
     WHERE id = v_inq.lead_id;
    INSERT INTO leadops.events (inquiry_id, lead_id, agent_id, type, detail)
    VALUES (v_inq.id, v_inq.lead_id, v_agent.id, 'claimed',
            jsonb_build_object('minutes', round((extract(epoch FROM now() - v_inq.received_at) / 60.0)::numeric, 1)));
    v_result := 'claimed';
  ELSIF p_action = 'claim' THEN
    v_result := 'already_claimed';
  END IF;

  IF p_action = 'contacted' THEN
    IF v_inq.contacted_at IS NULL THEN
      UPDATE leadops.inquiries SET status = 'contacted', contacted_at = now() WHERE id = v_inq.id;
      INSERT INTO leadops.events (inquiry_id, lead_id, agent_id, type, detail)
      VALUES (v_inq.id, v_inq.lead_id, v_agent.id, 'contacted',
              jsonb_build_object('minutes', round((extract(epoch FROM now() - v_inq.received_at) / 60.0)::numeric, 1)));
      v_result := 'contacted';
    ELSE
      v_result := 'already_contacted';
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'found', true, 'result', v_result,
    'agent', CASE WHEN v_agent.id IS NULL THEN NULL
                  ELSE jsonb_build_object('id', v_agent.id, 'code', v_agent.code, 'name', v_agent.name) END,
    'inquiry', leadops.inquiry_json(v_inq.id),
    'school_name', leadops.setting('school_name', 'Admissions'),
    'timezone', leadops.setting('timezone', 'Asia/Dubai'));
END $$;

-- =====================================================================
-- SLA watchdog: reminders and escalations that are due right now.
-- Counters are bumped in the same statement (no double reminders when
-- two watchdog runs overlap).
-- =====================================================================
CREATE OR REPLACE FUNCTION leadops.due_followups()
RETURNS TABLE (inquiry_id bigint, kind text, target_agent_id int, minutes_open numeric)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
BEGIN
  RETURN QUERY
  WITH due AS (
    SELECT i.id,
           CASE WHEN i.escalated_at IS NULL AND r.escalate_to_agent_id IS NOT NULL AND now() >= i.sla_due_at
                THEN 'escalation' ELSE 'reminder' END AS act,
           r.escalate_to_agent_id AS esc_id
      FROM leadops.inquiries i
      JOIN leadops.routing_rules r ON r.id = i.routing_rule_id
     WHERE i.status = 'notified' AND i.claimed_at IS NULL AND NOT i.is_demo
       AND (   (i.escalated_at IS NULL AND r.escalate_to_agent_id IS NOT NULL AND now() >= i.sla_due_at)
            OR (i.reminder_count < r.max_reminders
                AND now() >= coalesce(i.last_reminder_at, i.notified_at)
                             + make_interval(mins => r.reminder_every_minutes)))
     FOR UPDATE OF i SKIP LOCKED
  ), upd AS (
    UPDATE leadops.inquiries i SET
      reminder_count   = i.reminder_count + CASE WHEN d.act = 'reminder' THEN 1 ELSE 0 END,
      last_reminder_at = CASE WHEN d.act = 'reminder' THEN now() ELSE i.last_reminder_at END,
      escalated_at     = CASE WHEN d.act = 'escalation' THEN now() ELSE i.escalated_at END
      FROM due d
     WHERE i.id = d.id
    RETURNING i.id AS iid, d.act AS act,
              CASE WHEN d.act = 'escalation' THEN d.esc_id ELSE i.assigned_agent_id END AS target,
              i.received_at AS rat
  )
  SELECT u.iid, u.act, u.target, round((extract(epoch FROM now() - u.rat) / 60.0)::numeric, 1)
    FROM upd u;
END $$;

-- =====================================================================
-- Retry bookkeeping for failed inbox events (exponential backoff)
-- 2, 4, 8, 16, 32, 60 minutes ... then "dead" (alert + manual replay)
-- =====================================================================
CREATE OR REPLACE FUNCTION leadops.mark_inbox_failed(p_inbox_id bigint, p_error text, p_max_attempts int DEFAULT 6)
RETURNS jsonb LANGUAGE sql AS $$
  UPDATE leadops.inbox SET
    status        = CASE WHEN attempts >= p_max_attempts THEN 'dead' ELSE 'failed' END,
    last_error    = left(coalesce(nullif(p_error, ''), 'unknown error'), 4000),
    next_retry_at = now() + make_interval(mins => least(60, (2 ^ greatest(attempts, 1))::int)),
    locked_at     = NULL
  WHERE id = p_inbox_id
  RETURNING jsonb_build_object('inbox_id', id, 'source', source, 'event_key', event_key,
                               'status', status, 'attempts', attempts, 'last_error', last_error,
                               'next_retry_at', next_retry_at)
$$;

-- =====================================================================
-- OAuth token cache (Zoho allows only a few refreshes per 10 minutes)
-- =====================================================================
CREATE OR REPLACE FUNCTION leadops.cache_token(p_provider text, p_token text, p_expires_in int, p_error text DEFAULT NULL)
RETURNS TABLE (access_token text, expires_at timestamptz)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
BEGIN
  IF p_token IS NULL OR p_token = '' THEN
    RAISE EXCEPTION 'Token refresh for % failed: %', p_provider,
      coalesce(nullif(p_error, ''), 'response had no access_token');
  END IF;
  RETURN QUERY
  INSERT INTO leadops.oauth_tokens AS t (provider, access_token, expires_at, updated_at)
  VALUES (p_provider, p_token, now() + make_interval(secs => coalesce(p_expires_in, 3600)), now())
  ON CONFLICT (provider) DO UPDATE
     SET access_token = EXCLUDED.access_token, expires_at = EXCLUDED.expires_at, updated_at = now()
  RETURNING t.access_token, t.expires_at;
END $$;

-- =====================================================================
-- Alert throttling: same fingerprint inside the window is suppressed
-- =====================================================================
CREATE OR REPLACE FUNCTION leadops.record_alert(p_fingerprint text, p_severity text, p_title text,
                                                p_detail text, p_window_minutes int DEFAULT 15)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_suppressed boolean;
  v_id bigint;
BEGIN
  SELECT EXISTS (SELECT 1 FROM leadops.alerts
                  WHERE fingerprint = p_fingerprint AND NOT suppressed
                    AND created_at > now() - make_interval(mins => p_window_minutes))
    INTO v_suppressed;
  INSERT INTO leadops.alerts (fingerprint, severity, title, detail, suppressed)
  VALUES (p_fingerprint, coalesce(nullif(p_severity, ''), 'error'), coalesce(p_title, 'Alert'),
          left(p_detail, 4000), v_suppressed)
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('alert_id', v_id, 'suppressed', v_suppressed,
                            'severity', coalesce(nullif(p_severity, ''), 'error'),
                            'title', coalesce(p_title, 'Alert'), 'detail', p_detail,
                            'school_name', leadops.setting('school_name', 'LeadOps'));
END $$;

-- =====================================================================
-- Dashboard data (one call, one JSON document)
-- =====================================================================
CREATE OR REPLACE FUNCTION leadops.dashboard_data(p_days int DEFAULT 30)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_tz         text := leadops.setting('timezone', 'Asia/Dubai');
  v_since      timestamptz := now() - make_interval(days => p_days);
  v_prev_since timestamptz := now() - make_interval(days => 2 * p_days);
  v_today      date := (now() AT TIME ZONE v_tz)::date;
  v_kpi jsonb; v_daily jsonb; v_weekly jsonb; v_strip jsonb; v_channels jsonb; v_campaigns jsonb;
  v_agents jsonb; v_heat jsonb; v_open jsonb; v_health jsonb; v_lang jsonb; v_rules jsonb;
  v_sla_ref numeric;
BEGIN
  SELECT coalesce(jsonb_object_agg(period, k), '{}'::jsonb) INTO v_kpi FROM (
    SELECT CASE WHEN received_at >= v_since THEN 'current' ELSE 'previous' END AS period,
           jsonb_build_object(
             'inquiries',         count(*),
             'new_leads',         count(*) FILTER (WHERE NOT is_repeat),
             'returning',         count(*) FILTER (WHERE is_repeat AND status <> 'merged'),
             'merged',            count(*) FILTER (WHERE status = 'merged'),
             'median_claim_min',  round((percentile_cont(0.5) WITHIN GROUP (ORDER BY claim_min)
                                         FILTER (WHERE status <> 'merged'))::numeric, 1),
             'p90_claim_min',     round((percentile_cont(0.9) WITHIN GROUP (ORDER BY claim_min)
                                         FILTER (WHERE status <> 'merged'))::numeric, 1),
             'median_claim_staffed', round((percentile_cont(0.5) WITHIN GROUP (ORDER BY claim_min)
                                         FILTER (WHERE status <> 'merged' AND NOT after_hours))::numeric, 1),
             'median_claim_after_hours', round((percentile_cont(0.5) WITHIN GROUP (ORDER BY claim_min)
                                         FILTER (WHERE status <> 'merged' AND after_hours))::numeric, 1),
             'sla_pct_staffed',   round(100.0 * count(*) FILTER (WHERE in_sla AND NOT after_hours)
                                        / nullif(count(*) FILTER (WHERE status <> 'merged' AND sla_decided AND NOT after_hours), 0), 1),
             'median_contact_min',round((percentile_cont(0.5) WITHIN GROUP (ORDER BY contact_min)
                                         FILTER (WHERE status <> 'merged'))::numeric, 1),
             'sla_pct',           round(100.0 * count(*) FILTER (WHERE in_sla)
                                        / nullif(count(*) FILTER (WHERE status <> 'merged' AND sla_decided), 0), 1),
             'after_hours_pct',   round(100.0 * count(*) FILTER (WHERE after_hours) / nullif(count(*), 0), 1)
           ) AS k
      FROM leadops.v_inquiries
     WHERE received_at >= v_prev_since
     GROUP BY 1) s;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'day', d::date, 'meta', coalesce(c.meta, 0), 'web', coalesce(c.web, 0),
           'whatsapp', coalesce(c.wa, 0)) ORDER BY d), '[]'::jsonb)
    INTO v_daily
    FROM generate_series(v_today - (p_days - 1), v_today, interval '1 day') d
    LEFT JOIN (SELECT local_ts::date AS day,
                      count(*) FILTER (WHERE channel = 'meta') AS meta,
                      count(*) FILTER (WHERE channel = 'web') AS web,
                      count(*) FILTER (WHERE channel = 'whatsapp') AS wa
                 FROM leadops.v_inquiries WHERE received_at >= v_since GROUP BY 1) c
      ON c.day = d::date;

  SELECT coalesce(jsonb_agg(jsonb_build_object('week', w, 'median', m, 'n', n) ORDER BY w), '[]'::jsonb)
    INTO v_weekly
    FROM (SELECT date_trunc('week', local_ts)::date AS w,
                 round((percentile_cont(0.5) WITHIN GROUP (ORDER BY claim_min))::numeric, 1) AS m,
                 count(*) AS n
            FROM leadops.v_inquiries
           WHERE received_at >= now() - interval '126 days' AND status <> 'merged' AND claim_min IS NOT NULL
             AND NOT after_hours
           GROUP BY 1) s;

  SELECT coalesce(jsonb_agg(jsonb_build_array(
           CASE WHEN claim_min IS NULL THEN NULL ELSE round(claim_min::numeric, 2) END,
           channel, in_sla, after_hours,
           CASE WHEN claim_min IS NULL THEN round((extract(epoch FROM now() - received_at) / 60.0)::numeric, 1) END)),
         '[]'::jsonb)
    INTO v_strip
    FROM (SELECT * FROM leadops.v_inquiries
           WHERE received_at >= v_since AND status <> 'merged'
           ORDER BY received_at DESC LIMIT 900) s;

  SELECT round(percentile_disc(0.5) WITHIN GROUP (ORDER BY r.sla_minutes)::numeric, 0) INTO v_sla_ref
    FROM leadops.inquiries i JOIN leadops.routing_rules r ON r.id = i.routing_rule_id
   WHERE i.received_at >= v_since AND NOT r.is_after_hours;

  SELECT coalesce(jsonb_agg(x ORDER BY (x->>'inquiries')::int DESC), '[]'::jsonb) INTO v_channels FROM (
    SELECT jsonb_build_object(
             'channel', channel, 'inquiries', count(*),
             'median_claim_min', round((percentile_cont(0.5) WITHIN GROUP (ORDER BY claim_min)
                                        FILTER (WHERE status <> 'merged'))::numeric, 1),
             'sla_pct', round(100.0 * count(*) FILTER (WHERE in_sla)
                              / nullif(count(*) FILTER (WHERE status <> 'merged' AND sla_decided), 0), 1)) AS x
      FROM leadops.v_inquiries WHERE received_at >= v_since GROUP BY channel) s;

  SELECT coalesce(jsonb_agg(x ORDER BY (x->>'inquiries')::int DESC, x->>'campaign'), '[]'::jsonb) INTO v_campaigns FROM (
    SELECT jsonb_build_object(
             'campaign', coalesce(campaign_name, '(no campaign)'),
             'channel', mode() WITHIN GROUP (ORDER BY channel),
             'inquiries', count(*),
             'new_leads', count(*) FILTER (WHERE NOT is_repeat),
             'arabic_pct', round(100.0 * count(*) FILTER (WHERE language = 'ar') / nullif(count(*), 0)),
             'median_claim_min', round((percentile_cont(0.5) WITHIN GROUP (ORDER BY claim_min)
                                        FILTER (WHERE status <> 'merged'))::numeric, 1),
             'sla_pct', round(100.0 * count(*) FILTER (WHERE in_sla)
                              / nullif(count(*) FILTER (WHERE status <> 'merged' AND sla_decided), 0), 1)) AS x
      FROM leadops.v_inquiries WHERE received_at >= v_since
     GROUP BY coalesce(campaign_name, '(no campaign)')
     ORDER BY count(*) DESC LIMIT 12) s;

  SELECT coalesce(jsonb_agg(x ORDER BY (x->>'assigned')::int DESC), '[]'::jsonb) INTO v_agents FROM (
    SELECT jsonb_build_object(
             'agent', a.name, 'role', a.role,
             'assigned', count(v.id),
             'claimed', count(v.id) FILTER (WHERE v.claimed_by = a.id),
             'open', count(v.id) FILTER (WHERE v.status IN ('new','notified')),
             'median_claim_min', round((percentile_cont(0.5) WITHIN GROUP (ORDER BY v.claim_min))::numeric, 1),
             'sla_pct', round(100.0 * count(v.id) FILTER (WHERE v.in_sla)
                              / nullif(count(v.id) FILTER (WHERE v.sla_decided), 0), 1)) AS x
      FROM leadops.agents a
      JOIN leadops.v_inquiries v ON v.assigned_agent_id = a.id
                                AND v.received_at >= v_since AND v.status <> 'merged'
     GROUP BY a.id, a.name, a.role) s;

  SELECT coalesce(jsonb_agg(jsonb_build_array(dow, hr, n)), '[]'::jsonb) INTO v_heat FROM (
    SELECT extract(isodow FROM local_ts)::int AS dow, extract(hour FROM local_ts)::int AS hr, count(*) AS n
      FROM leadops.v_inquiries WHERE received_at >= v_since GROUP BY 1, 2) s;

  SELECT coalesce(jsonb_object_agg(coalesce(language, 'unknown'), n), '{}'::jsonb) INTO v_lang FROM (
    SELECT language, count(*) AS n FROM leadops.inquiries WHERE received_at >= v_since GROUP BY 1) s;

  SELECT coalesce(jsonb_agg(x ORDER BY (x->>'minutes_open')::numeric DESC), '[]'::jsonb) INTO v_open FROM (
    SELECT jsonb_build_object(
             'inquiry_id', i.id, 'name', coalesce(l.full_name, l.first_name, 'Unknown'),
             'channel', i.channel, 'campaign', i.campaign_name, 'language', i.language,
             'agent', a.name, 'reminders', i.reminder_count, 'escalated', i.escalated_at IS NOT NULL,
             'overdue', i.sla_due_at IS NOT NULL AND now() > i.sla_due_at,
             'after_hours', i.after_hours,
             'minutes_open', round((extract(epoch FROM now() - i.received_at) / 60.0)::numeric, 1)) AS x
      FROM leadops.inquiries i
      JOIN leadops.leads l ON l.id = i.lead_id
      LEFT JOIN leadops.agents a ON a.id = i.assigned_agent_id
     WHERE i.status IN ('new','notified')
     ORDER BY i.received_at LIMIT 25) s;

  SELECT coalesce(jsonb_agg(jsonb_build_object('name', name, 'days', days, 'start', to_char(start_time, 'HH24:MI'),
           'end', to_char(end_time, 'HH24:MI'), 'after_hours', is_after_hours, 'sla_minutes', sla_minutes)
           ORDER BY priority), '[]'::jsonb)
    INTO v_rules FROM leadops.routing_rules WHERE active;

  SELECT jsonb_build_object(
           'inbox', (SELECT coalesce(jsonb_object_agg(status, n), '{}'::jsonb)
                       FROM (SELECT status, count(*) n FROM leadops.inbox
                              WHERE received_at >= now() - interval '7 days' OR status IN ('failed','dead')
                              GROUP BY status) s),
           'last_event', (SELECT coalesce(jsonb_object_agg(source, last_at), '{}'::jsonb)
                            FROM (SELECT source, max(received_at) AS last_at FROM leadops.inbox GROUP BY source) s),
           'alerts_24h', (SELECT count(*) FROM leadops.alerts
                           WHERE created_at > now() - interval '24 hours' AND NOT suppressed),
           'crm_synced_pct', (SELECT round(100.0 * count(*) FILTER (WHERE crm_synced_at IS NOT NULL)
                                           / nullif(count(*), 0), 1)
                                FROM leadops.inquiries WHERE received_at >= v_since AND NOT is_demo))
    INTO v_health;

  RETURN jsonb_build_object(
    'generated_at', now(), 'days', p_days, 'timezone', v_tz,
    'school_name', leadops.setting('school_name', 'Admissions'),
    'has_demo', EXISTS (SELECT 1 FROM leadops.inquiries WHERE is_demo AND received_at >= v_since),
    'sla_reference_min', coalesce(v_sla_ref, 15),
    'kpis', v_kpi, 'daily', v_daily, 'weekly', v_weekly, 'strip', v_strip,
    'channels', v_channels, 'campaigns', v_campaigns, 'agents', v_agents,
    'heatmap', v_heat, 'languages', v_lang, 'open', v_open, 'rules', v_rules, 'health', v_health);
END $$;

-- =====================================================================
-- Morning digest for management (yesterday, local time)
-- =====================================================================
CREATE OR REPLACE FUNCTION leadops.digest_data()
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_tz    text := leadops.setting('timezone', 'Asia/Dubai');
  v_start timestamptz := (date_trunc('day', now() AT TIME ZONE v_tz) - interval '1 day') AT TIME ZONE v_tz;
  v_end   timestamptz := date_trunc('day', now() AT TIME ZONE v_tz) AT TIME ZONE v_tz;
BEGIN
  RETURN (
    SELECT jsonb_build_object(
      'school_name', leadops.setting('school_name', 'Admissions'),
      'date', (v_start AT TIME ZONE v_tz)::date,
      'inquiries', count(*),
      'new_leads', count(*) FILTER (WHERE NOT is_repeat),
      'merged', count(*) FILTER (WHERE status = 'merged'),
      'by_channel', (SELECT coalesce(jsonb_object_agg(channel, n), '{}'::jsonb) FROM
                      (SELECT channel, count(*) n FROM leadops.inquiries
                        WHERE received_at >= v_start AND received_at < v_end GROUP BY channel) c),
      'median_claim_min', round((percentile_cont(0.5) WITHIN GROUP (ORDER BY claim_min)
                                 FILTER (WHERE status <> 'merged'))::numeric, 1),
      'sla_pct', round(100.0 * count(*) FILTER (WHERE in_sla)
                       / nullif(count(*) FILTER (WHERE status <> 'merged' AND sla_decided), 0), 1),
      'top_campaign', (SELECT campaign_name FROM leadops.inquiries
                        WHERE received_at >= v_start AND received_at < v_end AND campaign_name IS NOT NULL
                        GROUP BY campaign_name ORDER BY count(*) DESC LIMIT 1),
      'open_now', (SELECT count(*) FROM leadops.inquiries WHERE status IN ('new','notified')),
      'oldest_open_min', (SELECT round((extract(epoch FROM now() - min(received_at)) / 60.0)::numeric)
                            FROM leadops.inquiries WHERE status IN ('new','notified')))
    FROM leadops.v_inquiries
    WHERE received_at >= v_start AND received_at < v_end);
END $$;
