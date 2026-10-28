#!/bin/bash
# 身份层 + 清单层回归（方案 M2/M3）：造一棵假权重树 → 断言识别结果与去重行为。
# 用法：tests/verify_identity.sh [BIN]
# 说明：用 --no-defaults --dirs=<临时树>，把本机真实权重排除在外，断言只由 fixture 决定。
set -uo pipefail
cd "$(dirname "$0")/.."

BIN="${1:-./build/Dockolate.app/Contents/MacOS/Dockolate}"
[[ -x "$BIN" ]] || { echo "✗ 找不到可执行文件：$BIN（先 ./build.sh）"; exit 2; }

TREE="$(mktemp -d /tmp/dockolate_ident.XXXXXX)" || exit 2
trap 'rm -rf "$TREE"' EXIT

echo "==> 造 fixture 树：$TREE"
python3 tests/make_fixture_tree.py "$TREE" || exit 2

fail=0
checks=0
check() {   # check <描述> <期望包含> <实际文本>
  checks=$((checks+1))
  if grep -qF -- "$2" <<< "$3"; then echo "    ✓ $1"; else echo "    ✗ $1（缺：$2）"; fail=$((fail+1)); fi
}
check_not() {
  checks=$((checks+1))
  if grep -qF -- "$2" <<< "$3"; then echo "    ✗ $1（不该出现：$2）"; fail=$((fail+1)); else echo "    ✓ $1"; fi
}

# ---------- 1. 身份识别 ----------
echo "· MLX 目录（config.json 的量化）"
OUT=$("$BIN" --identify="$TREE/mlx-4bit" 2>&1)
echo "$OUT" | sed 's/^/    │ /'
check "识别到 4bit gs64"      "quant=4bit gs64" "$OUT"
check "识别为 mlx 格式"       "format=mlx"      "$OUT"
check "角色是主权重"          "role=主权重"      "$OUT"

echo "· GGUF 主权重（头里的 general.name / architecture）"
OUT=$("$BIN" --identify="$TREE/gguf-model/main-Q4_K_M.gguf" 2>&1)
echo "$OUT" | sed 's/^/    │ /'
check "格式 gguf"             "format=gguf"     "$OUT"
check "量化 Q4_K_M"           "quant=Q4_K_M"    "$OUT"
check "架构来自 GGUF 头"      "architecture=test-arch" "$OUT"
check "家族名来自 general.name" "Test Model 7B"  "$OUT"

echo "· GGUF 草稿头（architecture 后缀 -mtp ⇒ 角色是草稿头）"
OUT=$("$BIN" --identify="$TREE/gguf-draft/mtp-draft-Q8_0.gguf" 2>&1)
echo "$OUT" | sed 's/^/    │ /'
check "角色=草稿头"           "role=草稿头"      "$OUT"

echo "· 空壳目录（只有 config，没有权重）"
OUT=$("$BIN" --identify="$TREE/empty" 2>&1 || true)
echo "$OUT" | sed 's/^/    │ /'
# 身份层可以认出它是个「没有权重的 config」，清单层会把它排除

# ---------- 2. 清单层 ----------
echo "· 清单（--no-defaults --dirs=<fixture 树>）"
OUT=$("$BIN" --inventory --json --no-defaults --dirs="$TREE" 2>&1)
echo "$OUT" | head -40 | sed 's/^/    │ /'
check "MLX 4bit 出现在清单里"      "mlx-4bit"        "$OUT"
check "GGUF 主权重出现在清单里"    "Q4_K_M"          "$OUT"
check "有在盘未登记的行"           '"unregistered" : true' "$OUT"
check_not "空壳目录不算模型"       '"title": "TestEmpty"' "$OUT"

# ---------- 3. 硬链接去重 ----------
echo "· 硬链接副本去重（gguf-dup 与 gguf-model 同一 inode）"
DUP_COUNT=$(grep -o '"title"' <<< "$OUT" | wc -l | tr -d ' ')
UNREG=$(python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
rows=[r for r in d['rows'] if 'Q4_K_M' in r['title']]
print(len(rows))
" <<< "$OUT" 2>/dev/null || echo "?")
checks=$((checks+1))
if [[ "$UNREG" == "1" ]]; then echo "    ✓ 同一份字节只出现一次（Q4_K_M 行数=1）"
else echo "    ✗ 硬链接副本没折叠（Q4_K_M 行数=${UNREG}）"; fail=$((fail+1)); fi

# ---------- 4. 角色与量化能在同一次清单里区分开 ----------
check "清单里能看到 VAE 角色"      "VAE"      "$OUT"
check "清单里能看到草稿头角色"     "草稿头"    "$OUT"

echo
if [[ $fail -eq 0 ]]; then
  echo "✅ 全部通过（$checks 条断言）"
  exit 0
fi
echo "❌ 失败 $fail 条（共 $checks 条断言）"
exit 1
