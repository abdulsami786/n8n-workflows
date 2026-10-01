-- =====================================================================
-- LeadOps · DEMO history (~95 days) so the dashboard tells a story.
-- Every row is flagged is_demo = true; remove with 99_remove_demo_data.sql
-- Names, phones (+9715...) and emails (@example.com) are fictional.
-- =====================================================================
DO $demo$
DECLARE
  v_tz       text := leadops.setting('timezone', 'Asia/Dubai');
  v_today    date := (now() AT TIME ZONE v_tz)::date;
  v_day      date;
  v_n        int;
  k          int;
  v_seq      int := 0;
  v_hour     int;
  u          float8;
  v_progress numeric;
  v_local    timestamp;
  v_received timestamptz;
  v_channel  text; v_lang text; v_campaign text; v_detail text; v_platform text;
  v_first    text; v_last text; v_phone text; v_email text;
  v_lead_id  bigint; v_inq_id bigint; v_repeat boolean;
  v_rule     leadops.routing_rules%ROWTYPE;
  v_agent    int;
  v_resp     numeric; v_claimed timestamptz; v_contacted timestamptz; v_open boolean;
  en_first text[] := ARRAY['Sarah','James','Priya','Michael','Emma','Daniel','Aisha','Ryan','Olivia','Arjun','Hannah','David','Sofia','Ahmed','Maria','Thomas','Zara','Lucas','Nina','Omar'];
  en_last  text[] := ARRAY['Thompson','Patel','Williams','Fernandes','Khan','Murphy','Rahman','Clarke','Mendes','Iyer','Nair','Brooks','Haddad','Costa','Walker','Sharma','Evans','Rossi','Chen','Ali'];
  ar_first text[] := ARRAY['محمد','فاطمة','أحمد','مريم','خالد','نورة','عبدالله','ريم','سعيد','هند','يوسف','لطيفة','حمدان','شيخة','علي','عائشة','راشد','سلمى','ماجد','ليلى'];
  ar_last  text[] := ARRAY['المنصوري','الشامسي','الكعبي','النعيمي','الظاهري','البلوشي','الحمادي','المهيري','السويدي','الكتبي','العامري','الزعابي','القاسمي','الفلاسي','المزروعي'];
  meta_c   text[] := ARRAY['KG1 Admissions 2026-27','KG1 Admissions 2026-27','Scholarship Week','Arabic & Islamic Studies Programme','Retargeting - Website visitors','British Curriculum - Secondary'];
  web_c    text[] := ARRAY['google / cpc - brand','google / organic','School tour booking page','Parent referral','instagram / bio link'];
  grades   text[] := ARRAY['FS1','FS2','Year 1','Year 2','Year 3','Year 5','Year 7','Year 9','Year 10','Year 12'];
BEGIN
  IF EXISTS (SELECT 1 FROM leadops.inquiries WHERE is_demo) THEN
    RAISE NOTICE 'Demo data already present - skipping';
    RETURN;
  END IF;
  PERFORM setseed(0.4242);

  FOR v_day IN SELECT d::date FROM generate_series(v_today - 94, v_today, interval '1 day') d LOOP
    v_progress := (v_day - (v_today - 94))::numeric / 94.0;
    v_n := CASE WHEN extract(isodow FROM v_day) IN (6, 7) THEN 4 + floor(random() * 5)::int
                ELSE 7 + floor(random() * 8)::int END;
    IF v_day BETWEEN v_today - 40 AND v_today - 27 THEN v_n := v_n + 5; END IF;   -- Open House push

    FOR k IN 1..v_n LOOP
      u := random();
      v_hour := CASE WHEN u < 0.07 THEN floor(random() * 7)::int
                     WHEN u < 0.40 THEN 7 + floor(random() * 5)::int
                     WHEN u < 0.54 THEN 12 + floor(random() * 4)::int
                     WHEN u < 0.62 THEN 16 + floor(random() * 2)::int
                     ELSE 18 + floor(random() * 6)::int END;
      v_local := v_day + make_time(v_hour, floor(random() * 60)::int, floor(random() * 59)::double precision);
      v_received := v_local AT TIME ZONE v_tz;
      CONTINUE WHEN v_received > now() - interval '3 minutes';

      v_channel := CASE WHEN random() < 0.58 THEN 'meta' ELSE 'web' END;
      v_lang    := CASE WHEN random() < 0.44 THEN 'ar' ELSE 'en' END;
      v_platform := NULL;
      IF v_channel = 'meta' THEN
        v_campaign := meta_c[1 + floor(random() * array_length(meta_c, 1))::int];
        IF v_day BETWEEN v_today - 40 AND v_today - 27 AND random() < 0.55 THEN
          v_campaign := 'Open House - October';
        END IF;
        v_detail := 'Meta lead form: ' || CASE WHEN v_lang = 'ar' THEN 'Admissions enquiry (AR)' ELSE 'Admissions enquiry (EN)' END;
        v_platform := CASE WHEN random() < 0.62 THEN 'ig' ELSE 'fb' END;
      ELSE
        v_campaign := web_c[1 + floor(random() * array_length(web_c, 1))::int];
        v_detail := 'Website form: /admissions/enquire';
      END IF;

      -- ~9% are families who already inquired before
      v_repeat := random() < 0.09 AND EXISTS (SELECT 1 FROM leadops.leads WHERE is_demo);
      IF v_repeat THEN
        SELECT id INTO v_lead_id FROM leadops.leads WHERE is_demo ORDER BY random() LIMIT 1;
      ELSE
        v_seq := v_seq + 1;
        IF v_lang = 'ar' AND random() < 0.7 THEN
          v_first := ar_first[1 + floor(random() * array_length(ar_first, 1))::int];
          v_last  := ar_last[1 + floor(random() * array_length(ar_last, 1))::int];
          v_email := CASE WHEN random() < 0.75 THEN 'parent' || v_seq || '@example.com' END;
        ELSE
          v_first := en_first[1 + floor(random() * array_length(en_first, 1))::int];
          v_last  := en_last[1 + floor(random() * array_length(en_last, 1))::int];
          v_email := CASE WHEN random() < 0.85 THEN lower(v_first || '.' || v_last || v_seq || '@example.com') END;
        END IF;
        v_phone := '+9715' || (ARRAY['0','2','4','5','6','8'])[1 + floor(random() * 6)::int]
                   || lpad(((v_seq * 7919) % 10000000)::text, 7, '0');
        INSERT INTO leadops.leads (full_name, first_name, last_name, phone_e164, email_norm, language,
                                   first_channel, first_campaign, crm_record_id, is_demo, created_at, updated_at)
        VALUES (v_first || ' ' || v_last, v_first, v_last, v_phone, v_email, v_lang, v_channel, v_campaign,
                'demo-' || v_seq, true, v_received, v_received)
        RETURNING id INTO v_lead_id;
      END IF;

      SELECT r.* INTO v_rule FROM leadops.routing_rules r
       WHERE leadops.rule_matches(r, v_local, v_lang, v_channel)
       ORDER BY r.priority, r.id LIMIT 1;
      v_agent := v_rule.agent_ids[1 + floor(random() * array_length(v_rule.agent_ids, 1))::int];

      -- Response model: in-hours median drifts from ~26 min to ~5 min as the team adopts the system
      IF v_rule.is_after_hours THEN
        v_resp := extract(epoch FROM (
                    (CASE WHEN extract(hour FROM v_local) < 7 THEN date_trunc('day', v_local)
                          ELSE date_trunc('day', v_local) + interval '1 day' END)
                    + interval '7 hours 40 minutes' + make_interval(mins => floor(random() * 70)::int) - v_local)) / 60.0;
      ELSE
        v_resp := exp(ln(26 - 21 * v_progress)
                      + 0.8 * sqrt(-2 * ln(greatest(random(), 1e-9))) * cos(2 * pi() * random()));
        IF v_rule.name = 'Weekend duty' THEN v_resp := v_resp * 1.8; END IF;
        v_resp := greatest(0.4, v_resp);
      END IF;

      v_open := v_received > now() - interval '40 minutes' AND random() < 0.75;
      v_claimed   := CASE WHEN v_open THEN NULL ELSE v_received + make_interval(secs => v_resp * 60) END;
      v_contacted := CASE WHEN v_claimed IS NULL OR random() < 0.08 THEN NULL
                          ELSE v_claimed + make_interval(secs => 30 + random() * 420) END;
      IF v_claimed > now() THEN v_claimed := NULL; v_contacted := NULL; v_open := true; END IF;
      IF v_contacted > now() THEN v_contacted := NULL; END IF;

      INSERT INTO leadops.inquiries (
          lead_id, channel, source_detail, campaign_name, platform, utm_source, utm_campaign, language,
          answers, is_repeat, status, submitted_at, received_at, crm_synced_at, crm_record_id,
          routing_rule_id, assigned_agent_id, after_hours, sla_due_at, notified_at,
          reminder_count, last_reminder_at, escalated_at, claimed_at, claimed_by, contacted_at, is_demo)
      VALUES (
          v_lead_id, v_channel, v_detail, v_campaign, v_platform,
          CASE WHEN v_channel = 'web' THEN split_part(v_campaign, ' /', 1) END,
          CASE WHEN v_channel = 'web' THEN v_campaign END,
          v_lang,
          jsonb_build_object('Grade applying for', grades[1 + floor(random() * array_length(grades, 1))::int],
                             'Academic year', '2026-27'),
          v_repeat,
          CASE WHEN v_open THEN 'notified' WHEN v_contacted IS NOT NULL THEN 'contacted' ELSE 'claimed' END,
          v_received - interval '4 seconds', v_received,
          v_received + make_interval(secs => 18 + random() * 30), 'demo-crm-' || v_lead_id,
          v_rule.id, v_agent, v_rule.is_after_hours,
          v_received + make_interval(mins => v_rule.sla_minutes),
          v_received + make_interval(secs => 8 + random() * 20),
          CASE WHEN v_resp > v_rule.reminder_every_minutes
               THEN least(v_rule.max_reminders, floor(v_resp / v_rule.reminder_every_minutes)::int) ELSE 0 END,
          NULL,
          CASE WHEN v_rule.escalate_to_agent_id IS NOT NULL AND v_resp > v_rule.sla_minutes AND NOT v_open
               THEN v_received + make_interval(mins => v_rule.sla_minutes) END,
          v_claimed, CASE WHEN v_claimed IS NOT NULL THEN v_agent END, v_contacted, true)
      RETURNING id INTO v_inq_id;

      -- ~3% submit twice within minutes (Meta form + website) -> merged duplicate, no second alert
      IF NOT v_open AND random() < 0.03 THEN
        INSERT INTO leadops.inquiries (lead_id, channel, source_detail, campaign_name, language, is_repeat,
                                       duplicate_of, status, submitted_at, received_at, is_demo)
        VALUES (v_lead_id, CASE WHEN v_channel = 'meta' THEN 'web' ELSE 'meta' END,
                'Second submission (merged)', v_campaign, v_lang, true, v_inq_id, 'merged',
                v_received + interval '6 minutes', v_received + interval '6 minutes', true);
      END IF;
    END LOOP;
  END LOOP;
END
$demo$;
