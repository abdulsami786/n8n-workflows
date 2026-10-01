#!/usr/bin/env bash
# Sends a SIGNED Meta leadgen webhook containing a test lead (no Meta account needed).
# Usage: tests/send_meta_test_lead.sh ["Full name"] ["phone"] [en|ar]
# Env:   LEADGEN_ID to reuse an id (duplicate test), SIGNATURE_SECRET to force a wrong secret.
set -euo pipefail
. "$(dirname "$0")/_common.sh"
NAME="$(json_escape "${1:-Layla Test}")"
PHONE="$(json_escape "${2:-050 123 4567}")"
LANG_CODE="${3:-en}"
# 17 digits on purpose: larger than JavaScript's safe integer range, like real Meta ids
LEADGEN_ID="${LEADGEN_ID:-9$(date +%s%N | cut -c1-16)}"
NOW="$(date +%s)"
LOCALE="en_US"; [ "$LANG_CODE" = "ar" ] && LOCALE="ar_AR"
EMAIL="test+${LEADGEN_ID: -6}@example.com"
BODY="{\"object\":\"page\",\"entry\":[{\"id\":\"${META_PAGE_ID:-100000000000001}\",\"time\":$NOW,\"changes\":[{\"field\":\"leadgen\",\"value\":{\"leadgen_id\":$LEADGEN_ID,\"page_id\":\"${META_PAGE_ID:-100000000000001}\",\"form_id\":\"200000000000002\",\"ad_id\":\"300000000000003\",\"created_time\":$NOW,\"test_lead\":{\"created_time\":$NOW,\"form_id\":\"200000000000002\",\"campaign_name\":\"LeadOps test campaign\",\"adset_name\":\"Test ad set\",\"ad_name\":\"Test ad\",\"platform\":\"ig\",\"is_organic\":false,\"form\":{\"name\":\"Admissions enquiry (test)\",\"locale\":\"$LOCALE\"},\"field_data\":[{\"name\":\"full_name\",\"values\":[\"$NAME\"]},{\"name\":\"phone_number\",\"values\":[\"$PHONE\"]},{\"name\":\"email\",\"values\":[\"$EMAIL\"]},{\"name\":\"which_grade_is_your_child_applying_for?\",\"values\":[\"Year 3\"]}]}}}]}]}"
SECRET="${SIGNATURE_SECRET:-${META_APP_SECRET:?META_APP_SECRET is not set}}"
SIG="$(printf '%s' "$BODY" | openssl dgst -sha256 -hmac "$SECRET" | sed 's/^.* //')"
echo "leadgen_id=$LEADGEN_ID" >&2
# Body goes through stdin, not argv: on Windows non-ASCII args get mangled and the signature no longer matches
printf '%s' "$BODY" | curl -sS -o /dev/stderr -w '%{http_code}\n' -X POST "$BASE/webhook/leadops/meta" \
  -H 'Content-Type: application/json' -H "X-Hub-Signature-256: sha256=$SIG" --data-binary @-
