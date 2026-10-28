#!/bin/bash
# 发布前自检矩阵（方案 M4）：把全部回归串起来，外加一趟「干净环境」冒烟。
#
# 用法：tests/verify_all.sh [BIN]
# 产出：终端汇总表 + tests/last_report.json（可附在 Release 里）
#
# 「干净环境」在这里指：换一个空的 HOME（没有任何模型、配置、缓存），
# 验证应用不会因为「什么都没有」而崩、而报错、而画出白板。
# ⚠️ 它不能替代真机验证：没有验证过「别人的 macOS 版本 / 别人的引擎组合」。
set -uo pipefail
cd "$(dirname "$0")/.."

BIN="${1:-./build/Dockolate.app/Contents/MacOS/Dockolate}"
[[ -x "$BIN" ]] || { echo "✗ 找不到可执行文件：$BIN（先 ./build.sh）"; exit 2; }

VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$(dirname "$BIN")/../Info.plist" 2>/dev/null || echo unknown)"
TMP="$(mktemp -d /tmp/dockolate_all.XXXXXX)"
REPORT="tests/last_report.json"
trap 'rm -rf "$TMP"' EXIT

declare -a NAMES=() RESULTS=() DETAILS=()
fail=0

run_suite() {   # run_suite <名称> <命令...>
  local name="$1"; shift
  echo
  echo "═══ ${name} ═══"
  local out; out=$("$@" 2>&1); local rc=$?
  local last; last=$(grep -E '✅|❌' <<< "$out" | tail -1)
  [[ -z "$last" ]] && last="（没有汇总行，rc=${rc}）"
  echo "$out" | tail -6
  NAMES+=("$name"); RESULTS+=("$rc"); DETAILS+=("$last")
  [[ $rc -ne 0 ]] && fail=$((fail+1))
  return 0
}

record() {   # record <名称> <0|1> <说明> —— 三个数组永远同步追加，避免汇总表错位
  NAMES+=("$1"); RESULTS+=("$2"); DETAILS+=("$3")
  if [[ "$2" -ne 0 ]]; then fail=$((fail+1)); fi
}

echo "Dockolate ${VER} — 发布前自检"
echo "可执行文件：$BIN"

run_suite "引擎探测回归（判据 R1–R3/R6）" bash tests/verify.sh "$BIN"
run_suite "身份层 + 清单层回归（M2/M3）"   bash tests/verify_identity.sh "$BIN"
run_suite "签名表外置回归（M4）"          bash tests/verify_adapters.sh "$BIN"

echo
echo "═══ 干净环境冒烟（空 HOME，且不声明任何目录）═══"
export HOME="$TMP/home"; mkdir -p "$HOME"

if "$BIN" --check-adapters > "$TMP/adapters.txt" 2>&1; then
  echo "  ✓ 签名表在空 HOME 下可读"
  record "干净环境：签名表" 0 "$(grep -c '条目' "$TMP/adapters.txt") 行来源"
else
  echo "  ✗ 签名表在空 HOME 下读不了"; record "干净环境：签名表" 1 "read failed"
fi

# --no-defaults：既不看默认仓库，也不看引擎声明目录；--ports-only --ports=1：不探任何引擎
# —— 这才是真正的「什么都没有」
"$BIN" --inventory --json --no-defaults --ports-only --ports=1 > "$TMP/inv.json" 2>&1
if python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if d.get('rows')==[] and d.get('scanned_roots')==[] else 1)
" "$TMP/inv.json" 2>/dev/null; then
  echo "  ✓ 空机器上清单为空、扫描根为空（不报错、不编造）"
  record "干净环境：空清单" 0 "rows=[] roots=[]"
else
  echo "  ✗ 空机器上清单不是空的（或输出不合法）"
  record "干净环境：空清单" 1 "$(head -c 160 "$TMP/inv.json" | tr '\n' ' ')"
fi

if "$BIN" --engines --ports-only --ports=1 > "$TMP/eng.txt" 2>&1; then
  echo "  ✓ 没有引擎时探测照常返回"
  record "干净环境：无引擎" 0 "$(wc -l < "$TMP/eng.txt" | tr -d ' ') 行输出"
else
  echo "  ✗ 没有引擎时探测失败"; record "干净环境：无引擎" 1 "non-zero exit"
fi

"$BIN" --shot-panel="$TMP/panel.png" > /dev/null 2>&1
"$BIN" --shot-inventory="$TMP/inv.png" > /dev/null 2>&1
for f in panel inv; do
  size=$(stat -f%z "$TMP/${f}.png" 2>/dev/null || echo 0)
  if [[ "$size" -gt 5000 ]]; then
    echo "  ✓ ${f} 窗口仍能渲染（${size} 字节）"; record "干净环境：${f} 渲染" 0 "${size} bytes"
  else
    echo "  ✗ ${f} 窗口渲染失败或空白（${size} 字节）"; record "干净环境：${f} 渲染" 1 "${size} bytes"
  fi
done

"$BIN" --discovery-report="$TMP/report.json" > /dev/null 2>&1
if python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$TMP/report.json" 2>/dev/null; then
  echo "  ✓ 发现报告是合法 JSON"; record "干净环境：发现报告" 0 "ok"
else
  echo "  ✗ 发现报告不可解析"; record "干净环境：发现报告" 1 "bad json"
fi

# ---------- 汇总 + 报告 ----------
echo
echo "═══ 汇总 ═══"
for i in "${!NAMES[@]}"; do
  mark="✓"; [[ "${RESULTS[$i]}" -ne 0 ]] && mark="✗"
  printf "  %s %-34s %s\n" "$mark" "${NAMES[$i]}" "${DETAILS[$i]}"
done

# 用 python 读 bash 数组：通过环境变量传
export DL_VER="$VER" DL_NAMES="$(printf '%s\n' "${NAMES[@]}")" \
       DL_RESULTS="$(printf '%s\n' "${RESULTS[@]}")" DL_DETAILS="$(printf '%s\n' "${DETAILS[@]}")" \
       DL_REPORT="$REPORT"
python3 - <<'PY'
import json, os, datetime
names = os.environ["DL_NAMES"].splitlines()
results = [int(x) for x in os.environ["DL_RESULTS"].splitlines()]
details = os.environ["DL_DETAILS"].splitlines()
report = {
    "app": "Dockolate",
    "version": os.environ["DL_VER"],
    "generated_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "os": "macOS",
    "steps": [{"name": n, "ok": r == 0, "detail": d}
              for n, r, d in zip(names, results, details)],
    "passed": all(r == 0 for r in results),
    "gaps": ["干净环境 = 空 HOME 冒烟，不代表已在其他机器的 macOS 版本 / 引擎组合上验证",
             "Unix domain socket 探测未实现（本机无可验证的引擎）"],
}
with open(os.environ["DL_REPORT"], "w") as f:
    json.dump(report, f, ensure_ascii=False, indent=2)
print("报告：", os.environ["DL_REPORT"], "→", "全部通过" if report["passed"] else "有失败项")
PY

echo
if [[ $fail -eq 0 ]]; then
  echo "✅ 发布前自检全部通过（$((${#NAMES[@]})) 项）"
  exit 0
fi
echo "❌ 发布前自检有 $fail 项失败"
exit 1
