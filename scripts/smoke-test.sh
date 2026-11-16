#!/bin/bash
# End-to-end test on a Mac where LockedIn is installed. Starts a REAL 2-minute block of
# example.com and a TEST-NET address, then checks hosts, pf, tamper recovery, and expiry.
# Then a REAL 1-minute allowlist block of example.com: every other site is unreachable meanwhile.
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

echo "7. start a 1-minute allowlist block of example.com"
"$CLI" start 1m --allow example.com || { echo "allowlist start failed"; exit 1; }
sleep 6
check "allowlist rules loaded"           "pfctl -a $ANCHOR -s rules 2>/dev/null | grep -q '<lockedin_allowed>'"
check "catch-all block is last"          "pfctl -a $ANCHOR -s rules 2>/dev/null | tail -n 1 | grep -q 'block return out quick all'"
check "allowed table filled"             "pfctl -a $ANCHOR -t lockedin_allowed -T show 2>/dev/null | grep -q ."
check "no hosts section"                 "! grep -q LOCKEDIN /etc/hosts"
check "DNS still answers"                "dig +short +time=3 +tries=1 www.apple.com | grep -q ."
# Dev servers often listen on only one of these (Astro and Vite: ::1).
nc -l 127.0.0.1 54321 >/dev/null 2>&1 &
listener4=$!
nc -6 -l ::1 54322 >/dev/null 2>&1 &
listener6=$!
sleep 1
check "localhost (127.0.0.1) reachable"  "nc -z -w 3 127.0.0.1 54321"
check "localhost (::1) reachable"        "nc -6 -z -w 3 ::1 54322"
kill "$listener4" "$listener6" 2>/dev/null
if curl -m 10 -sS -o /dev/null https://example.com 2>/dev/null; then ok "example.com reachable"; else fail "example.com blocked"; fi
if curl -m 5 -sS -o /dev/null https://www.apple.com 2>/dev/null; then fail "www.apple.com still reachable"; else ok "www.apple.com unreachable"; fi
check "add refused"                      "! \"$CLI\" add www.apple.com >/dev/null 2>&1"

after=$("$CLI" status --json | python3 -c 'import json,sys; print(int(json.load(sys.stdin)["remainingSeconds"]))')
echo "8. wait for expiry (${after}s)"
sleep $((after + 4))
check "status idle"                      "\"$CLI\" status | grep -q idle"
check "anchor empty"                     "! pfctl -a $ANCHOR -s rules 2>/dev/null | grep -q 'lockedin_'"
if curl -m 10 -sS -o /dev/null https://www.apple.com 2>/dev/null; then ok "www.apple.com reachable again"; else fail "www.apple.com still unreachable"; fi

echo
if [ $fails -eq 0 ]; then echo "SMOKE TEST PASSED"; else echo "SMOKE TEST: $fails failure(s); see /Library/Logs/LockedIn/lockedind.log"; exit 1; fi
