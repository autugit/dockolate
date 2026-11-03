# Dockolate 管理 API（给用户的 AI / 脚本用）

一次调用一个 JSON 请求，一行 JSON 回答。**不依赖 GUI 是否在跑**，也不碰程序本体。

```bash
DOCKOLATE=/Applications/Dockolate.app/Contents/MacOS/Dockolate   # 系统版
# 开发版：./build/Dockolate.app/Contents/MacOS/Dockolate

$DOCKOLATE --api '{"op":"help"}'
$DOCKOLATE --api @request.json      # 从文件读
echo '{"op":"status"}' | $DOCKOLATE --api -   # 从 stdin 读
```

- 回答恒为 JSON 对象，含 `ok`（true/false）；失败时还有 `code` 与 `message`。
- 退出码：`0` 成功 ｜ `2` 用法/请求格式错 ｜ `3` 找不到 ｜ `4` 校验失败 ｜ `5` 冲突（端口占用 / 正在跑 / 内存不够）。
- 状态目录：`~/Library/Application Support/Dockolate/`（可用环境变量 `DOCKOLATE_SUPPORT_DIR` 覆盖，测试用）。
- 程序本体（`.app`）与状态分离：API 只读写状态目录。系统版装在 `/Applications`、`root:wheel` 只读，
  升级只能整体替换（见文末）。

---

## op 一览

| op | 作用 |
|---|---|
| `help` | 列出支持的 op |
| `status` | 内存 / 在跑模型 / 中枢状态 |
| `model.list` | 列配方（含 running / pid / rssGB） |
| `model.get` | 单条配方 |
| `model.add` | **添加模型并配置启动/停止命令** |
| `model.update` | 改字段（id 不可改） |
| `model.remove` | 删配方（默认不删权重；正在跑要 `stop:true`） |
| `model.launch` | 按配方拉起，可选等端口就绪 |
| `model.stop` | 按配方的 stop 停；没 stop 要 `force:true` |
| `config.get` / `config.set` | `reserveGB` / `scanDirs` |
| `workgroup.list` / `.add` / `.remove` | 工作组 |
| `doctor` | 完整性 + 配置 + LaunchAgent + 中枢自检 |

---

## 1. 添加一个模型（最常见）

```bash
$DOCKOLATE --api '{
  "op": "model.add",
  "model": {
    "id": "my-chat-model",
    "title": "My-Chat-Model-27B 无审查",
    "engine": "MyEngine",
    "port": 12345,
    "path": "~/models/My-Chat-Model-27B-4bit",
    "category": "chat",
    "estMemGB": 26.0,
    "start": "~/bin/launch-splash.sh start",
    "stop":  "~/bin/launch-splash.sh stop",
    "log":   "~/Library/Logs/splash/server.log",
    "readyTimeoutSec": 180
  }
}'
```

回答：

```json
{"ok": true, "id": "my-chat-model", "warnings": [], "count": 7,
 "path": "/Users/…/Library/Application Support/Dockolate/registry.json"}
```

字段规则（`model.add` / `model.update` 同一套）：

| 字段 | 必填 | 说明 |
|---|---|---|
| `id` | 否（自动生成） | 字母/数字/`._-`，≤64；**创建后不可改** |
| `title` | ✅ | 界面显示名 |
| `start` | ✅（`kind=service` 可省） | 字符串（走 `bash -lc`）或 argv 数组 |
| `stop` | 否 | 字符串或 argv；**不填就停不了**（除非 `force:true` 强杀端口） |
| `port` | 否 | 1…65535，**不能与其它配方重复** |
| `engine` | 否 | 展示 + 进程识别用 |
| `path` | 否 | 权重路径（`~` 会展开）；现在不存在只警告 |
| `category` | 否 | chat / image / video / audio / embedding / service / part |
| `estMemGB` | 否 | 拉起前的内存预检（超过可用内存会拒绝拉起） |
| `metrics` / `media` | 否 | `text`（默认）/ `comfyui` / `mlxserve` |
| `readyTimeoutSec` | 否 | `launch` 等端口的上限，默认 180 |

**安全边界**：`model.remove` 只删配方，**不动权重文件**；每次写 `registry.json` 前都会备份
`registry.json.bak.<时间戳>`（保留最近 5 份）。

## 2. 删模型

```bash
# 没在跑
$DOCKOLATE --api '{"op":"model.remove","id":"my-chat-model"}'
# 在跑：一起停（会先跑 stop，再删配方）
$DOCKOLATE --api '{"op":"model.remove","id":"my-chat-model","stop":true}'
```

## 3. 改配置

```bash
$DOCKOLATE --api '{"op":"config.get"}'
$DOCKOLATE --api '{"op":"config.set","config":{"reserveGB":8,"scanDirs":["~/models","/Volumes/models"]}}'
```

## 4. 拉起 / 停止

```bash
$DOCKOLATE --api '{"op":"model.launch","id":"my-chat-model","wait":true}'
# → {"ok":true,"id":…,"pid":12345,"ready":true,"log":"…"}

$DOCKOLATE --api '{"op":"model.stop","id":"my-chat-model"}'
$DOCKOLATE --api '{"op":"model.stop","id":"my-chat-model","force":true}'   # 没配 stop 时
```

`launch` 会做和界面一样的内存预检：`estMemGB > 可用内存` 时直接拒绝（`code:"busy"`），
确实要硬上就传 `"force":true`。

## 5. 看状态

```bash
$DOCKOLATE --api '{"op":"status"}'
```
```json
{"ok":true,
 "memory":{"totalGB":96,"usedGB":42.1,"reserveGB":6,"freeGB":47.9},
 "recipes":7,
 "running":[{"id":"my-chat-model","title":"My-Chat-Model-27B 无审查","port": 12345,"pid":12345,"rssGB":17.2}],
 "hub":{"stateAgeSec":3.2,"policies":4},
 "stateDir":"/Users/…/Library/Application Support/Dockolate"}
```

## 6. 工作组

```bash
$DOCKOLATE --api '{"op":"workgroup.add","name":"出片","members":["comfy","h3"]}'
$DOCKOLATE --api '{"op":"workgroup.list"}'
$DOCKOLATE --api '{"op":"workgroup.remove","name":"出片"}'
```

## 7. 自检

```bash
$DOCKOLATE --api '{"op":"doctor"}'
$DOCKOLATE --doctor --text        # 人能读的版本
```

检查项：`bundle.manifest`（资源哈希）、`bundle.signature`（`codesign --verify --deep --strict`）、
`bundle.location`（当前用户是否可写程序本体）、`state`（配置是否有语义警告）、
`launchagents`（GUI 与中枢是否已加载）、`hub`（中枢状态新鲜度）。

---

## 错误码

| `code` | 含义 |
|---|---|
| `usage` | 请求不是合法 JSON / 缺 op / 缺参数 |
| `invalid` | 字段校验失败（端口越界、id 非法、缺 start…） |
| `notfound` | id / 工作组不存在 |
| `conflict` | id 已存在 |
| `busy` | 端口占用 / 正在跑 / 可用内存不够 |
| `io` | 文件读写失败（含 registry 不是合法 JSON——此时**拒绝改动**） |

`warnings` 数组永远存在（可能为空）：路径暂时不存在、类别不认识这类「能加但不完美」的情况只警告不拒绝。

---

## 程序本体与升级

| 位置 | 谁拥有 | 用途 |
|---|---|---|
| `/Applications/Dockolate.app` | `root:wheel`，只读 | **发布版**（AI 改不动） |
| `~/Applications/Dockolate.app` | 你自己 | 开发版（`./build.sh --install`） |

- 安装 / 升级发布版：`./build.sh && bash tools/install-system.command`（要输管理员密码）。
- 回滚：`./build.sh --rollback`（开发版）或把 `~/Applications/_prev/` 里的旧 `.app` 拷回 `/Applications`。
- 程序本体被改过时：启动会弹提示，`--doctor` 会列出是哪个文件；重装即可恢复。
