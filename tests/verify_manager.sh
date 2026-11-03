#!/bin/bash
# 管理器判据回归（v1.6）：分类 / 内存估算 / 三色可行性 / 配方匹配 / 日志与 /metrics 解析。
# 断言全部用合成数据，不依赖本机真的跑着哪个引擎。
# 用法：tests/verify_manager.sh [BIN]
set -uo pipefail
cd "$(dirname "$0")/.."

BIN="${1:-./build/Dockolate.app/Contents/MacOS/Dockolate}"
[[ -x "$BIN" ]] || { echo "✗ 找不到可执行文件：$BIN（先 ./build.sh）"; exit 2; }

OUT="$("$BIN" --self-test-manager 2>&1)"
RC=$?
echo "$OUT"

if [[ $RC -eq 0 ]]; then
  echo "✅ 全部通过（$(grep -c '✓' <<< "$OUT") 条断言）"
else
  echo "❌ 有断言失败（$(grep -c '✗' <<< "$OUT") 条）"
fi
exit $RC
