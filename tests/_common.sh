# Shared helpers for the test scripts. Reads ../.env when present.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$ROOT/.env" ]; then set -a; . "$ROOT/.env"; set +a; fi
BASE="${BASE_URL:-${PUBLIC_BASE_URL:-http://localhost:5678}}"
BASE="${BASE%/}"
# SQL access: docker compose by default, the local PostgreSQL when there is no Docker (Windows setup-local.ps1),
# or override with PSQL="psql -h ... -tA" when running elsewhere
if [ -z "${PSQL:-}" ] && ! command -v docker >/dev/null 2>&1; then
  PG_BIN="$(ls -d /c/Program\ Files/PostgreSQL/*/bin 2>/dev/null | tail -1)"
  [ -n "$PG_BIN" ] && PATH="$PG_BIN:$PATH"
  export PGPASSWORD="${POSTGRES_PASSWORD:-}" PGCLIENTENCODING=UTF8
  PSQL="psql -h 127.0.0.1 -U ${POSTGRES_USER:-leadops} -d leadops -tA"
fi
PSQL="${PSQL:-docker compose -f $ROOT/docker-compose.yml exec -T postgres psql -U ${POSTGRES_USER:-leadops} -d leadops -tA}"
sql() { $PSQL -c "$1"; }
json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
