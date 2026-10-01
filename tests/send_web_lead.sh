#!/usr/bin/env bash
# Posts a website inquiry like the embed form does.
# Usage: tests/send_web_lead.sh ["Full name"] ["phone"] ["email"] [submission_id]
set -euo pipefail
. "$(dirname "$0")/_common.sh"
NAME="$(json_escape "${1:-Daniel Test}")"
PHONE="$(json_escape "${2:-+971 55 765 4321}")"
EMAIL="$(json_escape "${3:-daniel.test@example.com}")"
SID="${4:-test-$(date +%s%N)}"
# Body goes through stdin, not argv: on Windows non-ASCII args get mangled
printf '%s' "{\"name\":\"$NAME\",\"phone\":\"$PHONE\",\"email\":\"$EMAIL\",\"message\":\"We are moving to Dubai in January. Is there space in Year 1?\",\"grade\":\"Year 1\",\"campus\":\"Main campus\",\"utm_source\":\"google\",\"utm_medium\":\"cpc\",\"utm_campaign\":\"Brand search - admissions\",\"page_url\":\"https://school.example/admissions\",\"submission_id\":\"$SID\"}" \
  | curl -sS -X POST "$BASE/webhook/leadops/web-form" -H 'Content-Type: application/json' --data-binary @-
echo
