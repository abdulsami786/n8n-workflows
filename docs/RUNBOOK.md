# Runbook

**Open a SQL shell:**
```bash
docker compose exec postgres psql -U $POSTGRES_USER -d leadops
```

## Daily
- Open the dashboard. **Pipeline health** should read "No events waiting for retry" and "Nothing failed permanently".
- The morning digest arrives at 07:30.

## Alerts and what to do

| Alert | Meaning | Action |
|---|---|---|
| Rejected a Meta webhook with an invalid signature | `META_APP_SECRET` doesn't match the app, or someone is probing the URL | Compare the secret in the Meta app; restart n8n after changing `.env` |
| Lead event failed, retrying automatically | A step failed (Graph, Bigin, Telegram) | Usually nothing; the sweeper retries. Check the error text |
| Lead event gave up after N attempts | Failed `MAX_ATTEMPTS` times | Fix the cause, then replay (below) |
| Token refresh for zoho failed: invalid_code | The refresh token was revoked or is for another region | Generate a new one (SETUP part 3) |
| No routing rule matches inquiry | A gap in `routing_rules` | Add a catch-all rule (like "After hours") |
| Agent "X" has no working notification channel | Missing chat id or email | Update `leadops.agents` |

## Replay events

A failed or dead event:
```sql
UPDATE leadops.inbox SET status = 'failed', attempts = 0, next_retry_at = now() WHERE id = 123;
```

All dead events:
```sql
UPDATE leadops.inbox SET status = 'failed', attempts = 0, next_retry_at = now() WHERE status = 'dead';
```

The sweeper picks them up within 2 minutes. Completed steps are skipped: no duplicate contacts, and no second alert unless the notification itself had not been sent.

## Useful queries

What is waiting right now:
```sql
SELECT i.id, l.full_name, i.channel, a.name AS agent, now() - i.received_at AS waiting
FROM leadops.inquiries i
JOIN leadops.leads l ON l.id = i.lead_id
LEFT JOIN leadops.agents a ON a.id = i.assigned_agent_id
WHERE i.status IN ('new', 'notified')
ORDER BY i.received_at;
```

Full history of one inquiry:
```sql
SELECT type, agent_id, detail, created_at FROM leadops.events WHERE inquiry_id = 123 ORDER BY id;
```

Events by status:
```sql
SELECT status, count(*) FROM leadops.inbox GROUP BY 1;
```

## Changes
- **Team / shifts:** edit `leadops.agents` and `leadops.routing_rules`. No restart needed.
- **Dedupe window:**
  ```sql
  UPDATE leadops.settings SET value = '48' WHERE key = 'dedupe_window_hours';
  ```
- **`.env`:** after editing, run `docker compose up -d n8n`.
- **Workflows:** after editing JSON, run `./setup.sh` again. It is idempotent: it re-imports and re-publishes.

## Backups
Run nightly:
```bash
docker compose exec -T postgres pg_dumpall -U $POSTGRES_USER | gzip > backup-$(date +%F).sql.gz
```
Also keep `.env`. Without `N8N_ENCRYPTION_KEY`, stored credentials cannot be decrypted.

## Updating n8n
Change the image tag in `docker-compose.yml`, run `docker compose up -d n8n`, then run `tests/acceptance.sh`. Test on a copy first when jumping several minor versions.
