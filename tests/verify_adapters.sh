#!/bin/bash
# 签名表外置的回归（方案 M4）：证明「新引擎 / 新状态串」不改代码、不发版就能认。
# 用法：tests/verify_adapters.sh [BIN]
set -uo pipefail
cd "$(dirname "$0")/.."

BIN="${1:-./build/Dockolate.app/Contents/MacOS/Dockolate}"
OVERRIDE="tests/fixtures_adapters/override.json"
BASE_PORT="${BASE_PORT:-$((19500 + ($$ % 200)))}"
FIX="tests/fixtures_adapters"

[[ -x "$BIN" ]] || { echo "✗ 找不到可执行文件：$BIN（先 ./build.sh）"; exit 2; }

fail=0
checks=0
SRV=""
cleanup() { [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null; rm -f /tmp/dockolate_adp_$$.out; }
trap cleanup EXIT

check() {   # check <描述> <期望包含> [文本，缺省用 $OUT]
  local text="${3:-$OUT}"
  checks=$((checks+1))
  if grep -qF -- "$2" <<< "$text"; then echo "    ✓ $1"; else echo "    ✗ $1（缺：${2}）"; fail=$((fail+1)); fi
}
check_not() {
  local text="${3:-$OUT}"
  checks=$((checks+1))
  if grep -qF -- "$2" <<< "$text"; then echo "    ✗ $1（不该出现：${2}）"; fail=$((fail+1)); else echo "    ✓ $1"; fi
}

start_engine() {   # start_engine <fixture 目录名> <端口> [argv0]
  local fx="$1" port="$2" argv0="${3:-}"
  if [[ -n "$argv0" ]]; then
    ( exec -a "$argv0" python3 tests/serve_fixtures.py "$FIX/$fx" "$port" ) > /tmp/dockolate_adp_$$.out 2>&1 &
  else
    python3 tests/serve_fixtures.py "$FIX/$fx" "$port" > /tmp/dockolate_adp_$$.out 2>&1 &
  fi
  SRV=$!
  for _ in $(seq 1 40); do grep -q '^ready ' /tmp/dockolate_adp_$$.out && break; sleep 0.1; done
  grep -q '^ready ' /tmp/dockolate_adp_$$.out || { echo "✗ $fx 假引擎没起来"; cat /tmp/dockolate_adp_$$.out; return 1; }
}
stop_engine() { kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""; }

# ---------- 1. 新状态串：没有覆盖表时 = 待确认 ----------
echo "· 未知状态串 warmup-x（无覆盖表）"
start_engine warmup "$BASE_PORT" || exit 2
OUT=$("$BIN" --engines --ports-only --ports="$BASE_PORT" 2>&1)
stop_engine
echo "$OUT" | sed 's/^/    │ /'
check "未知状态显示为待确认" "待确认" "$OUT"
check "原样透传状态串"       "warmup-x" "$OUT"

# ---------- 2. 同一引擎 + 用户覆盖表：认得了，不用发版 ----------
echo "· 加一行 JSON 之后（DOCKOLATE_ADAPTERS=覆盖表）"
start_engine warmup "$((BASE_PORT + 1))" || exit 2
OUT=$(DOCKOLATE_ADAPTERS="$OVERRIDE" "$BIN" --engines --ports-only --ports="$((BASE_PORT + 1))" 2>&1)
stop_engine
echo "$OUT" | sed 's/^/    │ /'
check "模型被列出来了"        "acme/warm-model" "$OUT"
check_not "不再显示待确认"    "待确认"
check_not "不再报未映射状态"  "warmup-x"

# ---------- 3. 进程特征词：外部表给新引擎起名 ----------
# 注意：python 假引擎的进程名/argv 改不了，端到端测不出「进程指纹」这条路径；
# 这里编译一个名字本身就是特征词（acmeimagined-serve）的假引擎二进制来测。
echo "· 进程特征词 acmeimagined → Acme Engine（内置表里完全没有这个引擎）"
STUB_DIR="$(mktemp -d /tmp/dockolate_stub.XXXXXX)"
swiftc -O tests/fake_engine_bin.swift -o "$STUB_DIR/acmeimagined-serve" 2>/dev/null \
  || { echo "✗ 假引擎编译失败（跳过第 3 项）"; fail=$((fail+1)); }
if [[ -x "$STUB_DIR/acmeimagined-serve" ]]; then
  "$STUB_DIR/acmeimagined-serve" "$((BASE_PORT + 2))" > /dev/null 2>&1 &
  SRV=$!
  sleep 0.6
  OUT=$(DOCKOLATE_ADAPTERS="$OVERRIDE" "$BIN" --engines --ports-only --ports="$((BASE_PORT + 2))" 2>&1)
  stop_engine
  echo "$OUT" | sed 's/^/    │ /'
  check "引擎按外部表命名"      "Acme Engine" "$OUT"
  OUT=$("$BIN" --engines --ports-only --ports="$((BASE_PORT + 2))" 2>&1 | head -5)
  check_not "没有覆盖表时认不出它" "Acme Engine" "$OUT"
fi
rm -rf "$STUB_DIR"

# ---------- 4. --check-adapters 汇总 ----------
echo "· --check-adapters（覆盖表生效）"
OUT=$(DOCKOLATE_ADAPTERS="$OVERRIDE" "$BIN" --check-adapters 2>&1)
echo "$OUT" | sed 's/^/    │ /'
check "覆盖表被读到"          "override.json" "$OUT"
check "states 条目合并"       "states:       20 条" "$OUT"
check "processHints 生效"     "processHints: 1 条" "$OUT"
check_not "没有解析警告"      "⚠"

# ---------- 5. 坏 JSON 不致命 ----------
echo "· 覆盖表写坏了：只警告，不崩"
BAD="$(mktemp /tmp/dockolate_bad.XXXXXX).json"
printf '{ this is not json' > "$BAD"
OUT=$(DOCKOLATE_ADAPTERS="$BAD" "$BIN" --check-adapters 2>&1); RC=$?
echo "$OUT" | sed 's/^/    │ /'
checks=$((checks+1))
if [[ $RC -ne 0 ]]; then echo "    ✓ 坏文件返回非 0（rc=${RC}）"; else echo "    ✗ 坏文件竟然返回 0"; fail=$((fail+1)); fi
check "给出警告"              "不是合法 JSON" "$OUT"
OUT=$("$BIN" --engines --ports-only --ports=1 2>&1); RC=$?
checks=$((checks+1))
if [[ $RC -eq 0 ]]; then echo "    ✓ 坏文件下引擎探测照常跑"; else echo "    ✗ 坏文件把引擎探测弄崩了"; fail=$((fail+1)); fi
rm -f "$BAD"

echo
if [[ $fail -eq 0 ]]; then
  echo "✅ 全部通过（$checks 条断言）"
  exit 0
fi
echo "❌ 失败 $fail 条（共 $checks 条断言）"
exit 1
