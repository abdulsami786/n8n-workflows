#!/usr/bin/env bash
# One-command install:  ./setup.sh            (add --demo to load 95 days of demo history)
set -euo pipefail
cd "$(dirname "$0")"
if [ ! -f .env ]; then cp .env.example .env; echo "Created .env - fill it in, then run ./setup.sh again."; exit 1; fi
set -a; . ./.env; set +a
DC="docker compose"; [ -n "${N8N_DOMAIN:-}" ] && [[ "$PUBLIC_BASE_URL" == https://* ]] && DC="docker compose --profile https"
PSQL="docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -q -U $POSTGRES_USER -d leadops"

echo "1/6 Starting Postgres"; $DC up -d postgres
until docker compose exec -T postgres pg_isready -U "$POSTGRES_USER" -d n8n >/dev/null 2>&1; do sleep 2; done
docker compose exec -T postgres psql -U "$POSTGRES_USER" -d n8n -tAc "SELECT 1 FROM pg_database WHERE datname='leadops'" | grep -q 1 \
  || docker compose exec -T postgres psql -U "$POSTGRES_USER" -d n8n -c "CREATE DATABASE leadops;"

echo "2/6 Database schema and settings"
$PSQL < sql/01_schema.sql
$PSQL -v tz="$TIMEZONE" -v school="$SCHOOL_NAME" < sql/02_seed.sql
if [ "${1:-}" = "--demo" ]; then echo "    loading demo history"; $PSQL < sql/03_demo_data.sql; fi

echo "3/6 Starting n8n"; $DC up -d
until curl -fsS http://127.0.0.1:5678/healthz >/dev/null 2>&1; do sleep 3; done

echo "4/6 Importing credentials and workflows"
docker compose exec -T n8n sh -c 'node /import/render-credentials.js > /tmp/leadops-credentials.json && n8n import:credentials --input=/tmp/leadops-credentials.json && rm /tmp/leadops-credentials.json'
docker compose exec -T n8n n8n import:workflow --separate --input=/import/workflows

echo "5/6 Publishing workflows"
for id in lo10Alerts000000 lo05Notify000000 lo04CrmSync00000 lo03Processor000 lo01MetaIntake00 \
          lo02WebIntake000 lo06SlaWatchdog0 lo07LeadActions0 lo08Dashboard000 lo09RetrySweep00 lo11DailyDigest0; do
  docker compose exec -T n8n n8n publish:workflow --id="$id" >/dev/null
done

echo "6/6 Restarting n8n so webhooks register"; docker compose restart n8n
until curl -fsS http://127.0.0.1:5678/healthz >/dev/null 2>&1; do sleep 3; done
cat <<DONE

Done.
  Editor:     $PUBLIC_BASE_URL   (create the owner account on first visit)
  Dashboard:  $PUBLIC_BASE_URL/webhook/leadops/dashboard   (user: $DASHBOARD_USER)
  Meta URL:   $PUBLIC_BASE_URL/webhook/leadops/meta
  Web form:   $PUBLIC_BASE_URL/webhook/leadops/web-form
Next: put your team's Telegram chat IDs / emails in leadops.agents (docs/SETUP.md, part 4),
then run tests/acceptance.sh
DONE
