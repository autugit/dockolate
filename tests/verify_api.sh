#!/bin/bash
# 管理 API 的契约测试：全部写操作都挡在临时 SupportDir 里，绝不碰真实配置。
# 用法：bash tests/verify_api.sh [--bin <可执行文件>]
set -uo pipefail

cd "$(dirname "$0")/.."
BIN="build/Dockolate.app/Contents/MacOS/Dockolate"
[[ "${1:-}" == "--bin" && -n "${2:-}" ]] && BIN="$2"
[[ -x "$BIN" ]] || { echo "找不到可执行文件：$BIN（先跑 ./build.sh）"; exit 1; }

TMP=$(mktemp -d /tmp/dockolate-api.XXXXXX)
export DOCKOLATE_SUPPORT_DIR="$TMP"
export DOCKOLATE_SKIP_MANIFEST=1

PASS=0; FAIL=0
call() { "$BIN" --api "$1"; }

expect() { # expect <desc> <json> <python 断言表达式，用 d=json>
  local desc="$1" json="$2" expr="$3"
  if printf '%s' "$json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
assert $expr, d
" 2>/dev/null; then
    PASS=$((PASS+1)); printf '  ✅ %s\n' "$desc"
  else
    FAIL=$((FAIL+1)); printf '  ❌ %s\n     请求输出：%s\n' "$desc" "$(printf '%s' "$json" | head -c 400)"
  fi
}

echo "== 临时状态目录：$TMP"
echo "1) help / 空清单"
expect "help 列得出 op" "$(call '{"op":"help"}')" "d['ok'] and 'model.add' in d['ops']"
expect "model.list 初始为空" "$(call '{"op":"model.list"}')" "d['ok'] and d['count']==0"

echo "2) 添加模型（HTTP 服务，端口 49555）"
ADD=$(call '{"op":"model.add","model":{"id":"test-http","title":"测试 HTTP 服务","engine":"test","port":49555,"start":"python3 -m http.server 49555","stop":"pkill -f \"http.server 49555\"","category":"service","estMemGB":0.2}}')
expect "add 成功并回 id" "$ADD" "d['ok'] and d['id']=='test-http'"
expect "registry.json 真的落盘" "$(call '{"op":"model.list"}')" "d['count']==1 and d['models'][0]['id']=='test-http'"

echo "3) 校验与冲突"
expect "同 id 再添加 → conflict" "$(call '{"op":"model.add","model":{"id":"test-http","title":"dup","start":"true"}}')" "(not d['ok']) and d['code']=='conflict'"
expect "端口冲突 → 拒绝" "$(call '{"op":"model.add","model":{"id":"dup2","title":"dup","port":49555,"start":"true"}}')" "(not d['ok']) and '端口' in d['message']"
expect "缺 start → 拒绝" "$(call '{"op":"model.add","model":{"id":"nostart","title":"x"}}')" "(not d['ok'])"
expect "非法 port → 拒绝" "$(call '{"op":"model.add","model":{"id":"badport","title":"x","port":99999,"start":"true"}}')" "(not d['ok'])"
expect "非法 id → 拒绝" "$(call '{"op":"model.add","model":{"id":"空格 名字","title":"x","start":"true"}}')" "(not d['ok'])"
expect "未知 op → usage" "$(call '{"op":"nope"}')" "(not d['ok']) and d['code']=='usage'"

echo "4) 更新与查询"
expect "update 改标题" "$(call '{"op":"model.update","id":"test-http","patch":{"title":"改名后的服务"}}')" "d['ok']"
expect "get 看得到新标题" "$(call '{"op":"model.get","id":"test-http"}')" "d['model']['title']=='改名后的服务'"
expect "get 不存在 → notfound" "$(call '{"op":"model.get","id":"nope"}')" "(not d['ok']) and d['code']=='notfound'"

echo "5) 配置读写"
expect "config.set reserveGB + scanDirs" "$(call '{"op":"config.set","config":{"reserveGB":8,"scanDirs":["~","/definitely/not/here"]}}')" "d['ok'] and d['scanDirs'][0].startswith('/Users')"
expect "config.get 读回 8 GB" "$(call '{"op":"config.get"}')" "d['config']['reserveGB']==8"
expect "不存在的目录给 warning" "$(call '{"op":"config.set","config":{"scanDirs":["/definitely/not/here"]}}')" "d['ok'] and any('不存在' in w for w in d['warnings'])"

echo "6) 启停"
LAUNCH=$(call '{"op":"model.launch","id":"test-http","wait":true}')
expect "launch 等到端口就绪" "$LAUNCH" "d['ok'] and d.get('ready') is True"
expect "status 里能看到在跑" "$(call '{"op":"status"}')" "any(r['id']=='test-http' for r in d['running'])"
expect "删除正在跑的 → busy（需 stop:true）" "$(call '{"op":"model.remove","id":"test-http"}')" "(not d['ok']) and d['code']=='busy'"
expect "stop 成功" "$(call '{"op":"model.stop","id":"test-http","force":true}')" "d['ok']"
expect "停后 status 看不到" "$(call '{"op":"status"}')" "not any(r['id']=='test-http' for r in d['running'])"

echo "7) 工作组"
expect "workgroup.add" "$(call '{"op":"workgroup.add","name":"tg","members":["test-http"]}')" "d['ok']"
expect "workgroup.list" "$(call '{"op":"workgroup.list"}')" "d['count']==1"
expect "workgroup 成员必须是已存在的 id" "$(call '{"op":"workgroup.add","name":"tg2","members":["ghost"]}')" "(not d['ok'])"
expect "workgroup.remove" "$(call '{"op":"workgroup.remove","name":"tg"}')" "d['ok']"

echo "8) 删除与备份"
expect "删除配方" "$(call '{"op":"model.remove","id":"test-http"}')" "d['ok'] and d['count']==0"
expect "删除后 list 为空" "$(call '{"op":"model.list"}')" "d['count']==0"
if ls "$TMP"/registry.json.bak.* >/dev/null 2>&1; then
  PASS=$((PASS+1)); echo "  ✅ 写操作留了 .bak"
else
  FAIL=$((FAIL+1)); echo "  ❌ 没有 .bak 备份"
fi

echo
echo "结果：✅ ${PASS} / ❌ ${FAIL}  （临时目录保留：${TMP}）"
[[ $FAIL -eq 0 ]] || exit 1
