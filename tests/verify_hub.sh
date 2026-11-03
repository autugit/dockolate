#!/bin/bash
# verify_hub.sh -- M0 acceptance test for the hub daemon (no model dependency)
#
#  1. --hub starts and keeps refreshing the state file (seq increases)
#  2. single instance: a second --hub exits 3
#  3. --hub-status reads the state
#  4. killing the daemon stops the refresh AND leaves running engines alone
#
# usage: bash tests/verify_hub.sh [/path/to/Dockolate]

# 默认测「实际部署的那一个」：中枢跑在 DockolateHub.app 里（独立 bundle id），
# 不是 GUI 的 Dockolate.app。测 GUI bundle 的那个二进制等于没测到线上路径。
HUB_BIN="$(cd "$(dirname "$0")/.." && pwd)/build/DockolateHub.app/Contents/MacOS/Dockolate"
GUI_BIN="$(cd "$(dirname "$0")/.." && pwd)/build/Dockolate.app/Contents/MacOS/Dockolate"
BIN="${1:-$HUB_BIN}"
[[ -x "$BIN" ]] || BIN="$GUI_BIN"
STATE="$HOME/Library/Application Support/Dockolate/hub-state.json"
ok=0
fail=0

pass() { echo "  PASS  $1"; ok=$((ok+1)); }
bad()  { echo "  FAIL  $1 ${2:-}"; fail=$((fail+1)); }

if [ ! -x "$BIN" ]; then echo "not executable: $BIN"; exit 2; fi

seq_of() { python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('seq',-1))" "$STATE" 2>/dev/null || echo -1; }
engines_of() { python3 -c "
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
print(' '.join('%s:%s' % (e.get('port'), e.get('pid')) for e in d.get('engines',[]) if e.get('pid')))" "$STATE" 2>/dev/null; }

echo "[1] start daemon (interval=1s)"
pkill -f "MacOS/Dockolate --hub" 2>/dev/null
sleep 1
"$BIN" --hub --interval=1 >/dev/null 2>&1 &
sleep 4
HUB_PID=$(pgrep -f "MacOS/Dockolate --hub" | head -1)
if [ -z "$HUB_PID" ]; then HUB_PID=$!; fi
if ps -p "$HUB_PID" >/dev/null 2>&1; then pass "daemon running (pid $HUB_PID)"; else bad "daemon did not start"; fi
S1=$(seq_of)
sleep 3
S2=$(seq_of)
if [ "$S1" -ge 0 ] && [ "$S2" -gt "$S1" ]; then pass "state refreshing (seq $S1 -> $S2)"; else bad "state not refreshing" "seq $S1 -> $S2"; fi

echo "[2] single instance"
"$BIN" --hub --interval=1 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 3 ]; then pass "second instance refused (exit 3)"; else bad "second instance not refused" "exit $RC"; fi

echo "[3] read-only status"
"$BIN" --hub-status >/tmp/hub_verify_status.txt 2>&1
if grep -q '"schema"' /tmp/hub_verify_status.txt; then pass "--hub-status returns state"; else bad "--hub-status empty"; fi

echo "[4] killing the daemon must not touch engines"
BEFORE=$(engines_of)
kill -TERM "$HUB_PID" 2>/dev/null
sleep 2
if ps -p "$HUB_PID" >/dev/null 2>&1; then bad "daemon still alive"; else pass "daemon exited"; fi
S3=$(seq_of)
sleep 2
S4=$(seq_of)
if [ "$S3" = "$S4" ]; then pass "refresh stopped (seq frozen at $S3)"; else bad "still refreshing" "$S3 -> $S4"; fi
for pair in $BEFORE; do
  P=${pair%%:*}
  E=${pair##*:}
  if ps -p "$E" >/dev/null 2>&1; then pass "engine pid $E (port $P) survived"; else bad "engine pid $E died with daemon"; fi
done

echo
echo "result: $ok passed / $fail failed"
[ "$fail" -eq 0 ]
