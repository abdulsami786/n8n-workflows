# Workflow reference

Every workflow also carries a sticky note in n8n that explains it. Config comes from `.env`, and team, shifts and school settings come from the `leadops` tables.

## 01 · Meta Lead Ads intake
**Trigger:** `GET` and `POST /webhook/leadops/meta`.

**GET (verification):** if `hub.mode=subscribe` and `hub.verify_token` equals `META_VERIFY_TOKEN`, it returns `hub.challenge`. Otherwise it returns 403.

**POST:**
1. Raw body to text, then HMAC-SHA256 with `META_APP_SECRET`, compared with `X-Hub-Signature-256`. A mismatch gets 401 plus a warning alert.
2. Extract `leadgen` changes. Long numeric ids are quoted before JSON parsing.
3. A single SQL statement inserts all events into `leadops.inbox` with `ON CONFLICT DO NOTHING`, which is the idempotency step.
4. Reply `200 EVENT_RECEIVED` only after the insert. A database failure becomes a 5xx, and Meta retries.
5. Each **new** event runs through workflow 03, one at a time. A failure schedules a retry, and an alert goes out on the first failure and on give-up.

## 02 · Website form intake
**Trigger:** `POST /webhook/leadops/web-form` (JSON or form-encoded).
1. Optional key check.
2. Honeypot and "submitted in under 2.5 s" traps. Spam gets a fake 200.
3. Validation: a name, plus a phone or an email. Failures get 422 with the errors.
4. Idempotency key: the form's `submission_id`, or a content fingerprint per 10-minute window.
5. Inbox insert, then reply `{ok, reference: "LO-123"}`, then workflow 03 for new submissions (same failure handling as 01).

## 03 · Lead processor (sub-workflow)
**Input:** `inbox_id`.
1. **Claim event:** atomic `UPDATE ... RETURNING`. Already done or being processed means stop.
2. **Meta:** Graph API `/{leadgen_id}` including campaign, ad set and ad names. On error it falls back to basic fields, then fetches the form name and locale (non-critical). Signed test leads skip the Graph call when `ALLOW_TEST_LEADS=true`.
3. **Map to canonical:** Meta `field_data` and website fields become one shape. Unknown questions are kept as `answers`.
4. **Normalize:**
   - E.164 phone: handles `05x`, `00971`, `+971 (0)`, and Arabic-Indic digits.
   - Email: lowercased and validated.
   - Name: split into first and last.
   - Language: explicit field, then form locale, then Arabic script detection.
5. **Save lead (dedupe):** `leadops.upsert_inquiry()` runs under an advisory lock.
   - Match the family by phone, then by email. Only blank fields are filled; nothing staff corrected is overwritten.
   - Create the inquiry. The same family inside `dedupe_window_hours` becomes `merged` (no alert).
   - Replays of the same inbox event return the existing inquiry.
6. **CRM sync:** calls 04 only if not synced yet. The record id is stored.
7. **Route and assign:** `leadops.route_inquiry()` picks the rule for local time, language and channel. It keeps the previous owner if that person is on shift, otherwise the least-loaded agent. It also sets the SLA deadline.
8. **Notify:** calls 05 for new, unmerged inquiries, then marks the inquiry notified and the inbox event done.

## 04 · CRM sync: Zoho Bigin (sub-workflow)
**Input:** `inquiry_id`.
1. Builds the contact (Bigin requires Last_Name; single names go there), the search criteria and the note.
2. Access token: the cached token in `leadops.oauth_tokens` if valid. Otherwise it refreshes, validates the answer (Zoho returns 200 even on error) and caches it.
3. Known CRM id: note only. Otherwise it searches `(Email or Mobile)`. 204 means not found, so it creates the contact (a `DUPLICATE_DATA` answer is treated as a match).
4. Adds a note with channel, campaign, ad set, ad, form, UTM, language, answers and message.

## 05 · Notify agent (sub-workflow)
**Inputs:** `inquiry_id`, `kind` (new, reminder or escalation), `agent_id` (0 means the assigned agent).
- Telegram (HTML) with buttons **Open and claim** and **WhatsApp with greeting**. The greeting is pre-written in the family's language. Link previews are disabled.
- Email via SMTP when enabled.
- Each send is logged to `leadops.events`.
- Fails loudly if the agent has no working channel.

## 06 · SLA watchdog
Runs every minute. `leadops.due_followups()` selects due reminders (every N minutes, up to a maximum) and escalations (deadline passed, sent to the rule's manager). The counters are bumped in the same statement, so overlapping runs never double-send.

## 07 · Lead page
`GET /webhook/leadops/lead?t=TOKEN&u=AGENT` shows the family, one-tap Call, WhatsApp and Email, answers, and earlier inquiries. Viewing never changes anything. `POST a=claim` or `a=contacted` records the response time. Bots get 403. A merged duplicate opens the original inquiry.

## 08 · Dashboard
`GET /webhook/leadops/dashboard?days=7|30|90` (basic auth). Add `&format=json` for BI tools. One SQL call (`leadops.dashboard_data`) returns:
- inquiries and new families
- time to first response in staffed hours and after hours, and % within the promise
- previous-period comparison
- a dot plot of every response
- the live queue
- a weekly trend
- volume by channel and day
- a weekday × hour heatmap with shifts outlined
- campaign and team tables
- pipeline health

## 09 · Retry sweeper
Runs every 2 minutes. It retries:
- failed events after backoff (2, 4, 8, 16, 32, 60 min)
- events accepted but never processed
- events stuck in processing for more than 10 minutes

After `MAX_ATTEMPTS` the event is marked `dead` and a critical alert goes out.

## 10 · Alerts
The Error Trigger (any top-level LeadOps workflow failing) and the sub-workflow call both go through `leadops.record_alert()`. The same fingerprint within 15 minutes is logged but not re-sent. Alerts go to Telegram (`ALERT_TELEGRAM_CHAT_ID`) and/or email (`ALERT_EMAIL`).

## 11 · Morning digest
Runs at 07:30 local time. It sends yesterday's inquiries by channel, median response, % on time, top campaign and anything still waiting to every active agent with role `manager`.
