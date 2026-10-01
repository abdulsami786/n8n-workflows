#!/usr/bin/env bash
# Phase 1 acceptance checks. Every check prints PASS/FAIL and the measured time.
#  1. Meta webhook verification handshake
#  2. Forged Meta signature is rejected
#  3. Signed Meta lead -> CRM (if enabled) + notification, within 60 s, campaign attached
#  4. The same Meta delivery twice creates one inquiry (idempotency)
#  5. Website lead -> CRM (if enabled) + notification, within 60 s, campaign attached
#  6. Same family again inside the dedupe window is merged (no second alert)
#  7. Dashboard answers with basic auth
set -uo pipefail
. "$(dirname "$0")/_common.sh"
DIR="$(dirname "$0")"
PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }
CRM_ON=false; [ "${CRM_PROVIDER:-none}" = "bigin" ] && CRM_ON=true
RND="$(date +%s | tail -c 6)"

wait_for() {  # $1 = SQL returning a row when done, $2 = timeout seconds
  local start end; start=$(date +%s)
  while :; do
    [ -n "$(sql "$1" 2>/dev/null)" ] && { end=$(date +%s); echo $((end-start)); return 0; }
    [ $(( $(date +%s) - start )) -ge "$2" ] && return 1
    sleep 1
  done
}
done_sql() {  # inquiry fully processed for a phone number
  local crm=""; $CRM_ON && crm="AND i.crm_synced_at IS NOT NULL"
  echo "SELECT i.id FROM leadops.inquiries i JOIN leadops.leads l ON l.id = i.lead_id
        WHERE l.phone_e164 = '$1' AND i.campaign_name IS NOT NULL AND i.notified_at IS NOT NULL $crm LIMIT 1"
}

echo "LeadOps acceptance checks against $BASE (CRM sync: $CRM_ON)"

C="challenge$RND"
R="$(curl -s "$BASE/webhook/leadops/meta?hub.mode=subscribe&hub.verify_token=${META_VERIFY_TOKEN:-}&hub.challenge=$C")"
[ "$R" = "$C" ] && ok "1. Meta verification returns hub.challenge" || bad "1. Meta verification (got: $R)"

CODE="$(SIGNATURE_SECRET=wrong-secret "$DIR/send_meta_test_lead.sh" 'Forged Lead' '0500000000' 2>/dev/null)"
[ "$CODE" = "401" ] && ok "2. Forged signature rejected with 401" || bad "2. Forged signature (HTTP $CODE)"

P1="0501${RND}9"; E164_1="+971501${RND}9"
LID="9$(date +%s%N | cut -c1-16)"
CODE="$(LEADGEN_ID=$LID "$DIR/send_meta_test_lead.sh" 'ليلى العامري' "$P1" ar 2>/dev/null)"
if T="$(wait_for "$(done_sql "$E164_1")" 60)"; then ok "3. Meta lead saved, synced and notified in ${T}s (HTTP $CODE)"; else bad "3. Meta lead not complete within 60 s"; fi

CODE="$(LEADGEN_ID=$LID "$DIR/send_meta_test_lead.sh" 'ليلى العامري' "$P1" ar 2>/dev/null)"
sleep 3
N="$(sql "SELECT count(*) FROM leadops.inquiries i JOIN leadops.leads l ON l.id=i.lead_id WHERE l.phone_e164='$E164_1'")"
[ "$N" = "1" ] && ok "4. Duplicate Meta delivery ignored (1 inquiry)" || bad "4. Duplicate Meta delivery produced $N inquiries"

P2="+97155${RND}21"; E164_2="+97155${RND}21"
"$DIR/send_web_lead.sh" "Daniel Acceptance" "$P2" "daniel.$RND@example.com" >/dev/null
if T="$(wait_for "$(done_sql "$E164_2")" 60)"; then ok "5. Website lead saved, synced and notified in ${T}s"; else bad "5. Website lead not complete within 60 s"; fi

"$DIR/send_web_lead.sh" "Daniel Acceptance" "$P2" "daniel.$RND@example.com" >/dev/null
if T="$(wait_for "SELECT i.id FROM leadops.inquiries i JOIN leadops.leads l ON l.id=i.lead_id WHERE l.phone_e164='$E164_2' AND i.status='merged'" 30)"; then
  ok "6. Second inquiry from same family merged (no second alert)"; else bad "6. Second inquiry was not merged"; fi

CODE="$(curl -s -o /dev/null -w '%{http_code}' -u "${DASHBOARD_USER:-admissions}:${DASHBOARD_PASSWORD:-}" "$BASE/webhook/leadops/dashboard")"
[ "$CODE" = "200" ] && ok "7. Dashboard responds (HTTP 200)" || bad "7. Dashboard HTTP $CODE"

echo "Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
