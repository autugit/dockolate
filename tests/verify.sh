#!/bin/bash
# 引擎探测回归测试（判据 R1–R3、R6）：每个 fixture 单独起一个假引擎 → 跑 --engines → 逐条比对。
# 用法：tests/verify.sh [BIN]
# 依赖：build.sh 已产出可执行文件；python3 可用。
# 说明：用 --ports-only 把真实引擎排除在外，保证结果只由 fixture 决定（否则本机在跑的引擎会污染断言）。
set -uo pipefail
cd "$(dirname "$0")/.."

BIN="${1:-./build/Dockolate.app/Contents/MacOS/$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' build/Dockolate.app/Contents/Info.plist 2>/dev/null || echo Dockolate
)}"
FIX="tests/fixtures"
BASE_PORT="${BASE_PORT:-9430}"

[[ -x "$BIN" ]] || { echo "✗ 找不到可执行文件：$BIN（先 ./build.sh）"; exit 2; }
[[ -d "$FIX" ]] || { echo "✗ 缺 $FIX"; exit 2; }

fail=0
checks=0
fixtures=0
# 基端口按 pid 偏移，避免上一轮残留占用导致「假引擎没起来」这种假失败
port=${BASE_PORT:-$((19000 + ($$ % 400)))}
SRV=""
cleanup() { [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null; rm -f /tmp/dockolate_fixture_$$.out; }
trap cleanup EXIT

for dir in "$FIX"/*/; do
  name=$(basename "$dir")
  [[ "$name" == _* ]] && continue
  [[ -f "$dir/routes.json" ]] || continue
  [[ -f "$dir/expect.txt" ]] || { echo "⚠ $name 缺 expect.txt，跳过"; continue; }

  python3 tests/serve_fixtures.py "${dir%/}" "$port" > /tmp/dockolate_fixture_$$.out 2>&1 &
  SRV=$!
  for _ in $(seq 1 40); do
    grep -q '^ready ' /tmp/dockolate_fixture_$$.out && break
    sleep 0.1
  done
  if ! grep -q '^ready ' /tmp/dockolate_fixture_$$.out; then
    echo "✗ $name 假引擎没起来"; cat /tmp/dockolate_fixture_$$.out; kill $SRV 2>/dev/null
    fail=$((fail+1)); port=$((port+1)); continue
  fi

  OUT=$("$BIN" --engines --ports-only --ports="$port" 2>&1)
  fixtures=$((fixtures+1))
  echo "· ${name}（端口 ${port}）"
  echo "$OUT" | sed 's/^/    │ /'

  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    checks=$((checks+1))
    case "$line" in
      "+"*) pat="${line:1}"
            if grep -qF -- "$pat" <<< "$OUT"; then echo "    ✓ 出现：$pat"
            else echo "    ✗ 缺少：$pat"; fail=$((fail+1)); fi ;;
      "-"*) pat="${line:1}"
            if grep -qF -- "$pat" <<< "$OUT"; then echo "    ✗ 不该出现：$pat"; fail=$((fail+1))
            else echo "    ✓ 未出现：$pat"; fi ;;
      *)    echo "    ⚠ 无法解析的期望行：$line"; fail=$((fail+1)) ;;
    esac
  done < "$dir/expect.txt"

  kill $SRV 2>/dev/null
  wait $SRV 2>/dev/null
  rm -f /tmp/dockolate_fixture_$$.out
  port=$((port+1))
done

echo
if [[ $fail -eq 0 ]]; then
  echo "✅ 全部通过（$checks 条断言 / $fixtures 个 fixture）"
  exit 0
fi
echo "❌ 失败 $fail 条（共 $checks 条断言 / $fixtures 个 fixture）"
exit 1
