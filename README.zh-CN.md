# Dockolate

[![Release](https://img.shields.io/github/v/release/autugit/dockolate?display_name=tag)](https://github.com/autugit/dockolate/releases/latest)
[![Website](https://img.shields.io/badge/website-autugit.github.io%2Fdockolate-e0b040)](https://autugit.github.io/dockolate/)
[![License: MIT](https://img.shields.io/github/license/autugit/dockolate)](LICENSE)
[![Platform](https://img.shields.io/badge/macOS-13%2B-blue)](https://github.com/autugit/dockolate)
[![Stars](https://img.shields.io/github/stars/autugit/dockolate)](https://github.com/autugit/dockolate/stargazers)

**Dock 里的一板巧克力** —— 用四格水位实时显示 CPU / GPU / 内存压力，外加一份「内存里现在真挂着哪些本地 AI 模型」的清单。

<p align="center">
  <img src="docs/img/dock-icon.png" width="140" alt="Dock 图标：四格水位 C / G / M / Z">
  <img src="docs/img/window.png" width="440" alt="窗口：本机 AI 模型、进程榜、内存分解">
</p>



图标是 2×2 四宫格，每格一个字母水印 + 从底部升起的水位，高低和颜色一眼看出紧迫程度：

```
┌────────┬────────┐
│   C    │   G    │   C = CPU      G = GPU
│  ▓▓░░  │  ▓░░░  │   （蓝色水位 = 极低）
├────────┼────────┤
│   M    │   Z    │   M = 内存     Z = 压缩+换页
│  ▓▓▓░  │  ▓▓▓▓  │   （绿/黄/红随水位升高）
└────────┴────────┘
```

水位配色：**< 20% 蓝 · 20–50% 绿 · 50–80% 黄 · ≥ 80% 红**

- 图标里**不放数字**——数字会跟字母抢地方，而且 Dock 尺寸下也读不准；精确值去窗口看。
- 点 Dock 图标 → 弹出窗口：
  - **本机 AI 模型**：内存里挂着的本地模型（oMLX / llama.cpp / ComfyUI / Draw Things …），
    按内存占用从大到小排，逐行标 **正在运行 / 挂载待机 / 出现故障**；声明了但没加载的列在脚注里；
  - **CPU / GPU / 内存占用最高的各三个进程**，外加内存分解（应用/联动/压缩/缓存/空闲）与换页量。
- 菜单栏读数默认关闭，窗口里的「菜单栏读数」按钮可随时打开。

### Z 是什么

**Z = 内存压缩 + 换页水位** = (压缩内存 + 已换页) ÷ 物理内存。
它和 M 是两个维度：M 看「用了多少」，Z 看「被挤压了多少」——
Z 越高说明系统为了腾地方压得越狠、换出去的越多，内存越紧张。

## 两个显示面，各自可开关

窗口左下角：**「Dock 图标读数」** 与 **「菜单栏读数」** 两个独立勾选框，选择记进 `UserDefaults`，下次启动沿用。

| Dock 图标 | 菜单栏 | 效果 |
|---|---|---|
| 勾 | 不勾 | 只有 Dock 水位四宫格（默认） |
| 不勾 | 勾 | 菜单栏紧凑读数 `C12 G40 M63`（字母按占用率变色） |
| 勾 | 勾 | 两个都要 |
| 不勾 | 不勾 | 只留窗口，不画任何常驻读数 |

## 支持哪些本地引擎（通用探测，不依赖任何一家私有网关）

**端口是探测出来的，不是写死的。** 先看被识别为模型服务的进程实际监听了哪些端口，
所以你把服务挪到自定义端口照样认得出；内置的一张小默认表只在「进程认不出来」时兜底，
其余可以在 `engines.json` 里补。下面这张表列的是**询问方式**，不是端口要求。

| 引擎 | 模型名怎么来 |
|---|---|
| **Ollama** | `GET /api/ps`（在跑）+ `GET /api/tags`（已下载 → 未加载清单） |
| **LM Studio** | `GET /api/v0/models` 的 `state == "loaded"` |
| **在 `GET /v1/models` 里逐条报状态的引擎**（如 **mlx-serve**） | 取 `state` / `loaded` / `bytes_resident` → 正在运行 / 加载中 / 未加载 |
| **llama.cpp / llamafile / KoboldCpp** | `GET /v1/models`，取不到再从 `--model` 参数抠 |
| **vLLM / SGLang / TGI / TensorRT-LLM / LocalAI / TabbyAPI / LiteLLM / OpenLLM / FastChat / Xinference** | `GET /v1/models` |
| **MLX 系：Splash / oMLX / MTPLX / Flash-Next / Swift-Qwen / `mlx-serve` / `mlx_lm.server` / `mlx_vlm.server`** | `GET /v1/models`，取不到再从 argv 抠 |
| **Jan / GPT4All / Docker Model Runner / text-generation-webui** | `GET /v1/models` 或进程指纹 |
| **ComfyUI** | `GET /queue` → `GET /history` 的 `ckpt_name` / `unet_name` |
| **A1111 / Forge / reForge / SD.Next / Draw Things** | `GET /sdapi/v1/options` 的 `sd_model_checkpoint` |
| **Fooocus / InvokeAI / SwarmUI / DiffusionBee / Amuse / mflux** | `/v1/models` 或进程指纹 |
| **视频：Wan / MiniMax / HunyuanVideo / LTX-Video / CogVideo** | 进程指纹 + `phys_footprint` |
| **语音：Whisper / Kokoro / Coqui / ChatTTS / Piper / XTTS** | 进程指纹 + `phys_footprint` |
| **应用内模型（Draw Things、LM Studio 桌面版）** | 进程指纹 + `phys_footprint` |

名单在 `src/EngineProbe.swift` 的三张表里：`kindHints`（进程特征词 → 引擎名）、
`quickHints`（扫描粗筛，值不值得深扫这个进程）、`knownEngines`（进程认不出来时的端口兜底）。
缺哪个引擎就往 `kindHints` 加一行，判定逻辑不用动；自定义端口用 `engines.json` 补。

有的引擎是**两层进程**（父进程监听端口、子进程跑推理，Splash 1.4 就是：Python 父进程 0.4 GB +
`serve-native` 子进程几十 GB）。内存与「是否在算」按**整棵进程树**聚合，不会只报父进程那几十 MB。

状态口径：**正在运行** = 端口在应答且最近 12 秒内真算过东西（CPU 或 GPU 时间在涨）；
**挂载待机** = 权重在内存、端口在应答、没在算；**加载中** = 引擎自报权重正在往内存里搬，
这时还接不了请求；**出现故障** = 进程占着端口但端口不应答，或引擎自报该模型出错；
**未加载** = 已下载未常驻，单独列出、不占内存；
**待确认** = 引擎在应答但载荷形状不认识，或证据不足以判断（tooltip 写明看到了什么）。

判定是**打分制，不是先到先得**：先把每个已知形状都收下来，谁的信息量大谁说了算
（逐条状态 > 常驻字节 > 磁盘/量化字段 > 只有 id 列表 > 空数组）。
任何「没有加载模型」的结论都要**两条互相独立的负面证据**；不足两条就标「待确认」，
不硬下结论。引擎自报但本程序不认识的状态字符串**原样显示**。

`GET /v1/models` 里的条目带逐条状态时，**先读它**，再考虑 Ollama 的接口。
不少服务只兼容了半套 Ollama API，而它的 `/api/ps` 只列**完全常驻**的模型 ——
先读那一路，会把「正在加载」和「引擎按需加载、还没加载」的模型报成不存在
（引擎名也会认错）。Ollama 自己的 `/v1/models` 没有状态字段，照旧走 `/api/ps`。

需要鉴权的引擎（比如 oMLX 无 key 一律 401）拿不到模型名时只显示引擎名 + 端口，不猜。
配置 `~/Library/Application Support/Dockolate/engines.json`：

```json
{ "extraPorts": [12345], "apiKeys": { "12345": "sk-your-key" } }
```

也支持环境变量 `DOCKOLATE_KEY_<端口>` 或 `DOCKOLATE_KEY`。

## 安装

```bash
./install.sh
```

会编译、装到 `~/Applications/Dockolate.app`，并注册 LaunchAgent（登录自启 + 崩溃 4 秒内自拉起）。

## 卸载

```bash
./uninstall.sh
```

## 只编译不安装

```bash
./build.sh          # 产物：build/Dockolate.app
```

### 这是哪个版本？看文件头，不看文件名

同一家族的 4bit / 8bit / IQ3 / IQ4，各引擎的命名习惯都不一样。Dockolate 对每个能找到的权重目录读**文件头**：
GGUF 的键值对（`general.architecture`、`general.name`、`general.size_label`）、safetensors 的 JSON 头、
`config.json` 的 `architectures` 与 `quantization{bits, group_size}`。靠这个把**同一家族的不同量化**分开，
并分辨**主权重 / 草稿头（MTP）/ 视觉投影（mmproj）/ LoRA / VAE / 文本编码器**。

在盘字节按 **inode** 去重：硬链接副本与 HF 快照里指向 `blobs/` 的符号链接只算一次。

### 盘上有、但没有任何引擎登记的权重

「引擎在跑什么」不等于「你机器上有什么」。**本机模型清单**窗口（菜单 ⌘I）把三路对起来 ——
引擎自报、文件头写的、盘上目录 —— 并把**没有引擎登记**的权重单列成「在盘未登记」。

扫描范围：已知仓库（HF 缓存 / Ollama / LM Studio / ComfyUI 模型目录）、`engines.json` 里的 `modelDirs`，
以及**正在运行的引擎自己在 argv 里声明的目录**（`--model-dir` / `--model-path` / `--model`）。
不做全盘扫描：又慢又越界。

### 不改代码就认新引擎

判定里**纯数据**的那几层放在 `resources/adapters.json`（随应用发布）与
`~/Library/Application Support/Dockolate/adapters.json`（用户覆盖，格式相同、逐段叠加）：

| 段 | 作用 |
|---|---|
| `processHints` | 进程特征词 → 引擎名（外部条目优先于内置 68 条） |
| `ports` | 端口 → 兜底名（只在进程认不出时用） |
| `states` | 引擎自报的状态串 → `resident` / `loading` / `failed` / `absent` |
| `roles` | 特征词 → 角色（草稿头 / 投影 / LoRA / VAE / 文本编码器） |
| `probePaths` | 诊断与发现报告额外探测的路径 |

```bash
Dockolate --check-adapters     # 哪几份读到了、多少条目、有没有解析警告
```

写坏了只警告不崩。所以「引擎换了名字」或「升级后多了一个没见过的状态串」，加几行 JSON 就能认，
不必等我发新版。

### 发布前自检

```bash
bash tests/verify_all.sh       # 三套回归 + 干净环境冒烟，产出 tests/last_report.json
```

「干净环境」＝ 换一个**空的 HOME**（没有模型/配置/缓存）：清单为空、无引擎时探测正常、
两个窗口仍能渲染出非空白 PNG。它**不**代表已在别人的 macOS 版本与引擎组合上验证过 —— 这条仍是缺口。

## 自检 / 验收（无需屏幕录制权限）

```bash
BIN=./build/Dockolate.app/Contents/MacOS/Dockolate

$BIN --dump --out=/tmp                        # 采样一次并导出图标 PNG
$BIN --dump --verbose --out=/tmp              # 附带内存去向与 Z 的分解
$BIN --dump --mock=8,16,35,88 --out=/tmp      # 强制 C/G/M/Z 四个水位，验四种颜色
$BIN --procs                                  # 打印三个进程榜（窗口的数据源）
$BIN --engines                                # 引擎探测报告（模型名 / 状态 / 内存）
$BIN --engines --ports=9000,9001              # 额外探测自定义端口
$BIN --shot-panel=/tmp/panel.png              # 主窗口离屏渲染成 PNG（进程内 cacheDisplay）
$BIN --shot-panel=/tmp/panel.png --demo-models # 注入「运行/加载中/待确认/故障」四态快照，验收配色与文案
$BIN --probe=<端口>                            # 打印各接口的载荷形状 + 候选评分 + 选中的适配器（可贴进反馈）
$BIN --identify=<路径>                         # 这个权重目录/文件到底是什么（家族/量化/角色/字节）
$BIN --inventory [--json] [--dirs=a:b]         # 磁盘清单（运行时 + 在盘未登记）
$BIN --shot-inventory=/tmp/inv.png             # 清单窗口离屏渲染（可加 --demo-inventory）
$BIN --discovery-report=/tmp/report.json       # 脱敏发现报告（无模型名/路径/pid/key）
bash tests/verify.sh && bash tests/verify_identity.sh   # 两套回归：引擎探测 + 身份/清单
```

`--shot-panel` 不需要屏幕录制权限（本机 `screencapture` 直接报
`could not create image from display`），界面验收一律走它。

## 数据口径

| 指标 | 来源 | 口径 |
|---|---|---|
| CPU | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` | 两次采样间全核 busy/total 增量比 |
| GPU | `ioreg -c AGXDeviceUserClient` → Σ`accumulatedGPUTime` 增量 | 所有客户端 GPU 时间增量 ÷ 墙钟（**不要用 `Device Utilization %`，它会假报 0**） |
| 内存 | `host_statistics64(HOST_VM_INFO64)` | (internal 匿名页 + wired + 压缩器) / 总物理内存（**不要用 active_count，它混着几十 GB 文件缓存**） |
| Z 压缩+换页 | `sysctl vm.swapusage` + 压缩器页数 | (压缩内存 + 已换页) / 总物理内存 |
| 进程 CPU | `ps -r` 按 `%CPU` 降序 | 取前三 |
| 进程 GPU | `ioreg -c AGXDeviceUserClient` → `AppUsage.accumulatedGPUTime` 差 | 该客户端累计 GPU 时间（ns）增量 ÷ 墙钟 = 占整颗 GPU 的百分比 |
| 进程内存 | `proc_pid_rusage` → `ri_phys_footprint`（libproc） | 物理占用，与活动监视器同口径（**别用 `ps` 的 rss，对 mmap 大户会少报 23 倍**） |

> 进程 GPU 是这套工具的硬货：macOS 不提供公开的按进程 GPU 统计（`powermetrics` 要 root），
> 这里靠 IOKit 的 `AGXDeviceUserClient` 拿到，实测与设备总利用率吻合（压测进程 87.4% vs 设备 85–89%）。

采样节奏：CPU/内存 1 秒、GPU 2 秒；显示按 0.5 秒插值平滑；
图标只在**整数百分比**变化时重绘（小数抖动肉眼不可见，重绘纯属浪费）。
进程榜只在窗口打开时采样，窗口关闭即停。
实测自身开销约 **0.7% CPU / 93 MB**。

详见 `docs/开发文档.md`。

## 常见问题

**Mac 上不装 `sudo` 怎么看 GPU 占用？**
不调 `powermetrics`，而是从 `ioreg` 里遍历每个 `AGXDeviceUserClient` 的
`accumulatedGPUTime` 求和，所以永远不会弹密码框。总 GPU 占用在 Dock 图标上，
按进程的前三名在窗口里。

**怎么知道本机现在内存里挂着哪些本地 AI 模型？**
打开窗口。每个认出来的模型服务都会列出它实际占的内存
（`ri_phys_footprint`，与活动监视器同口径），并标 `running` / `loaded-idle` /
`failed`；Ollama、LM Studio 里下载了但没加载的也会单独列出。

**这是菜单栏应用还是 Dock 应用？**
都是，各自独立：Dock 图标是水位（默认开）；菜单栏文字读数（紧凑的
`C12 G40 M63`）是一个可选勾选框。两个都关就只剩窗口。

**Apple Silicon 还是 Intel？**
构建目标是 `arm64-apple-macosx13.0`。Intel 机器把 `build.sh` 里这一个目标改成
`x86_64-apple-macosx13.0` 即可，别处没有架构相关代码。

**需要 root、管理员权限或屏幕录制权限吗？**
都不需要。数据全来自公开 API —— `host_statistics64`、
`host_processor_info`、`proc_pid_rusage`、`proc_pidinfo`、`ioreg`。
没有特权守护进程，没有 entitlement，也不会弹权限申请。

**数据会离开本机吗？**
不会。HTTP 只发往 `127.0.0.1`；没有遥测，也没有更新检查。

**自定义端口的模型服务没被认出来。**
端口是从「认出来的进程实际监听的端口」反推的。进程认不出来时，可在
`~/Library/Application Support/Dockolate/engines.json` 里显式声明
`{"extraPorts": [12345]}`。

**和 iStat Menus、Stats、活动监视器有什么区别？**
那三个报在菜单栏或窗口里。Dockolate 的前提是 Dock 始终在眼前，四格水位隔着房间
就能回答「这台机器现在有没有压力」；而且它是这几个里唯一会把内存中常驻的本地
AI 模型清点出来的。

**为什么叫 Dockolate？**
它住在 Dock 里，2×2 的图标看着像一板掰开的巧克力。

## 作者

由 **Autumemory** 与 **Hermes**（agent）、**DeepSeek v4.1 flash**（模型）共同完成。
设计取舍、代码、实测数据与这些文档都出自这次协作。

## 许可

MIT，见 [LICENSE](LICENSE)。
