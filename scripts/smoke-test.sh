#!/bin/bash
# End-to-end test on a Mac where LockedIn is installed. Starts a REAL 2-minute block of
# example.com and a TEST-NET address, then checks hosts, pf, tamper recovery, and expiry.
# Run with sudo. Nothing else on the machine is changed.
set -uo pipefail

[ "$(id -u)" = 0 ] || { echo "run with: sudo scripts/smoke-test.sh"; exit 1; }
CLI=/usr/local/bin/lockedin
ANCHOR=com.apple/300.lockedin
TABLE=lockedin_blocked
IP=198.51.100.1
fails=0
ok()   { echo "  ok    $1"; }
fail() { echo "  FAIL  $1"; fails=$((fails + 1)); }
check(){ if eval "$2"; then ok "$1"; else fail "$1"; fi; }

echo "1. doctor"
"$CLI" doctor || true

echo "2. start a 2-minute block"
"$CLI" start 2m "$IP" example.com || { echo "start failed (is a block already running?)"; exit 1; }
sleep 4
check "hosts section present"            "grep -q '# BEGIN LOCKEDIN BLOCK' /etc/hosts"
check "example.com in hosts"             "grep -q '0.0.0.0.*www.example.com' /etc/hosts"
check "pf enabled"                       "pfctl -s info 2>/dev/null | grep -q 'Status: Enabled'"
check "main ruleset has com.apple/*"     "pfctl -s rules 2>/dev/null | grep -q 'anchor \"com.apple/\\*\"'"
check "anchor rules loaded"              "pfctl -a $ANCHOR -s rules 2>/dev/null | grep -q '<$TABLE>'"
check "table holds $IP"                  "pfctl -a $ANCHOR -t $TABLE -T show 2>/dev/null | grep -q '$IP'"

start=$(date +%s)
nc -z -w 3 "$IP" 80 >/dev/null 2>&1; rc=$?
elapsed=$(( $(date +%s) - start ))
if [ $rc -ne 0 ] && [ $elapsed -le 1 ]; then ok "connection to $IP refused immediately (${elapsed}s)"; else fail "connection to $IP not refused quickly (rc=$rc, ${elapsed}s)"; fi
if curl -m 5 -sS -o /dev/null https://example.com 2>/dev/null; then fail "example.com still reachable"; else ok "example.com unreachable"; fi

echo "3. tamper: disable pf"
pfctl -d >/dev/null 2>&1
sleep 17
check "pf re-enabled within 17 s"        "pfctl -s info 2>/dev/null | grep -q 'Status: Enabled'"

echo "4. tamper: strip the hosts section"
sed -i '' '/# BEGIN LOCKEDIN BLOCK/,/# END LOCKEDIN BLOCK/d' /etc/hosts
sleep 3
check "hosts section restored"           "grep -q '# BEGIN LOCKEDIN BLOCK' /etc/hosts"

echo "5. kill the daemon"
before=$("$CLI" status --json | python3 -c 'import json,sys; print(int(json.load(sys.stdin)["remainingSeconds"]))')
launchctl kickstart -k system/com.tgreco.lockedin.daemon
sleep 3
after=$("$CLI" status --json | python3 -c 'import json,sys; print(int(json.load(sys.stdin)["remainingSeconds"]))')
if [ "$after" -le "$before" ] && [ "$after" -ge $((before - 10)) ]; then ok "countdown continued across restart ($before -> $after)"; else fail "countdown wrong after restart ($before -> $after)"; fi

echo "6. wait for expiry (${after}s)"
sleep $((after + 4))
check "status idle"                      "\"$CLI\" status | grep -q idle"
check "hosts section gone"               "! grep -q LOCKEDIN /etc/hosts"
check "no stray example.com lines"       "! grep -qE '^(0\\.0\\.0\\.0|::)[[:space:]]+(www\\.|m\\.)?example\\.com' /etc/hosts"
check "anchor empty"                     "! pfctl -a $ANCHOR -s rules 2>/dev/null | grep -q '<$TABLE>'"
if curl -m 10 -sS -o /dev/null https://example.com 2>/dev/null; then ok "example.com reachable again"; else fail "example.com still unreachable"; fi

echo
if [ $fails -eq 0 ]; then echo "SMOKE TEST PASSED"; else echo "SMOKE TEST: $fails failure(s); see /Library/Logs/LockedIn/lockedind.log"; exit 1; fi
