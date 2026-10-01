# Setup guide

## Part 1: server
1. Point a DNS A record (e.g. `n8n.yourschool.example`) at the VPS. Open ports 80 and 443.
2. `cp .env.example .env`. Set `PUBLIC_BASE_URL=https://n8n.yourschool.example`, `N8N_DOMAIN`, strong passwords, `N8N_ENCRYPTION_KEY` (keep a copy: it decrypts stored credentials), `TIMEZONE`, `DEFAULT_COUNTRY_CODE` and `SCHOOL_NAME`.
3. `./setup.sh` (add `--demo` for sample history). It starts Postgres 17, n8n and Caddy (automatic HTTPS), loads the schema, imports credentials and workflows, and publishes them.
4. Open `PUBLIC_BASE_URL` and create the n8n owner account.

## Part 2: Meta Lead Ads
1. In **Meta for Developers**, create an app (type Business) owned by the school's Business Manager.
2. Add the **Webhooks** product. Choose the object **Page**:
   - Callback URL: `PUBLIC_BASE_URL/webhook/leadops/meta`
   - Verify token: the value of `META_VERIFY_TOKEN`

   Meta calls the GET endpoint immediately, and workflow 01 answers with the challenge. Then subscribe to the **leadgen** field.
3. Copy **App settings, Basic, App secret** into `META_APP_SECRET`. It is used to verify `X-Hub-Signature-256`.
4. **Long-lived page token.** Generate a user token with `pages_show_list, pages_read_engagement, pages_manage_metadata, leads_retrieval` (add `ads_read` to get campaign, ad set and ad names).
   - Exchange it for a long-lived user token:
     `GET https://graph.facebook.com/v26.0/oauth/access_token?grant_type=fb_exchange_token&client_id=APP_ID&client_secret=APP_SECRET&fb_exchange_token=SHORT_TOKEN`
   - Then read the page token: `GET https://graph.facebook.com/v26.0/me/accounts?access_token=LONG_USER_TOKEN`
   - A page token derived from a long-lived user token does not expire. Put it in `META_PAGE_ACCESS_TOKEN`. For several pages use `META_PAGE_TOKENS={"PAGE_ID":"TOKEN",...}`.
5. **Subscribe the page to the app:**
   `POST https://graph.facebook.com/v26.0/PAGE_ID/subscribed_apps?subscribed_fields=leadgen&access_token=PAGE_TOKEN`
6. **Leads access.** In Business Manager, go to Integrations, Leads Access, and make sure the app (or no restriction) has access. Otherwise lead fetches fail with a permissions error.
7. **Test.** Use Meta's *Lead Ads Testing Tool* to create a test lead. Without Meta access, `tests/send_meta_test_lead.sh` sends a correctly signed test payload.
8. Restart n8n after changing `.env`: `docker compose up -d n8n`.

## Part 3: Zoho Bigin
1. Find the account's data centre (the URL shows `bigin.zoho.com`, `.eu`, `.sa` ...). Set `ZOHO_ACCOUNTS_URL` and `BIGIN_API_BASE` to the same region.
2. Go to https://api-console.zoho.com (same region) and create a **Self Client**. Under **Generate Code**, use:
   - scope `ZohoBigin.modules.ALL,ZohoBigin.users.READ`
   - duration 10 minutes
3. Exchange the code for a refresh token within 10 minutes:
   ```bash
   curl -X POST "https://accounts.zoho.com/oauth/v2/token?grant_type=authorization_code&client_id=ID&client_secret=SECRET&code=CODE"
   ```
   Put `client_id`, `client_secret` and `refresh_token` in `.env`, and set `CRM_PROVIDER=bigin`.
4. **Optional custom fields.** In Bigin, add fields such as *Lead Channel*, *Lead Campaign* and *Preferred Language* to Contacts. Put their API names in `BIGIN_FIELD_*`. Without them, source, campaign and language still go into the contact description and a note on every inquiry.

## Part 4: team, shifts and notifications
1. Create a Telegram bot with @BotFather and put the token in `TELEGRAM_BOT_TOKEN`.
2. Each staff member opens the bot and presses Start. Get their chat id from `https://api.telegram.org/botTOKEN/getUpdates`.
3. Put the team into the database:
   ```sql
   UPDATE leadops.agents SET name='Sara Haddad', telegram_chat_id='123456789', email='sara@school.example' WHERE code='sara';
   ```
4. **Shifts** live in `leadops.routing_rules`:
   - `days` (1=Mon ... 7=Sun), `start_time` and `end_time`, optional `language` and `channel`
   - `agent_ids`, which is a pool: the agent with the least open work gets the lead
   - `sla_minutes`, `reminder_every_minutes`, `max_reminders` and `escalate_to_agent_id`

   UAE schools usually work Mon to Fri. For KSA and Qatar use `{7,1,2,3,4}`. The rule with the lowest `priority` that matches wins, and a returning family goes back to its previous owner when that person is on shift.
5. The operator alert chat goes in `ALERT_TELEGRAM_CHAT_ID`. Email is optional: set `SMTP_ENABLED=true` with the SMTP settings.

## Part 5: website form
Either embed `web/inquiry-form.html` (set `ENDPOINT`), or point an existing form plugin's webhook at `/webhook/leadops/web-form`. Common field names are recognised (`name`, `your-name`, `phone`, `mobile`, `email`, `message`, `utm_*` ...), and any extra fields are kept as answers. Server-to-server posts can send `X-LeadOps-Key: WEB_FORM_KEY`.

## Part 6: go live
- Set `ALLOW_TEST_LEADS=false`.
- Run `tests/acceptance.sh`.
- Remove the demo history: `docker compose exec -T postgres psql -U $POSTGRES_USER -d leadops < sql/99_remove_demo_data.sql`
