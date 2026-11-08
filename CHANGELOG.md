# Changelog

All notable changes to Dockolate are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is
[semantic](https://semver.org/).

## [1.8.3] — 2026-11-06

### Fixed — Dock 里出现多个同款图标

- **一次性 CLI 模式不再向 LaunchServices 注册成前台 App**。链路是：界面每次做互斥判定都会
  fork 一个自身副本（`MainWindow.runEnsure` → `Bundle.main.executablePath --ensure=…`），
  副本里 `_ = NSApplication.shared` 让它以 `Foreground` 身份登记；Dock 的「最近使用」于是
  每 fork 一次多一格，而且不会自动去重 —— 一本机的 `recent-apps` 里攒出三条同 bundle 的
  记录，加上钉住的那条，正好是界面上的四个图标。
- 新增 `cliApp()`：CLI 分支（`--ensure=` / `--release=` / `--mgmt-*` / `--explain=`）**连
  `NSApplication` 都不创建**。只靠 `setActivationPolicy(.prohibited)` 仍会在 Dock 留格子，
  真正的判据是「别让 LaunchServices 记一次 App 启动」；这些分支全链路只用 Foundation。
- `DockolateHub` 的 Info.plist 增加 `LSBackgroundOnly`：后台中枢每次启动都会在「最近使用」
  留一条记录，`LSUIElement` 不足以让它彻底不进 Dock。
- Hub bundle 被 LaunchServices 直接拉起（`open -a` / 双击 / 登录恢复）时 argv 里没有 `--hub`，
  旧代码会退化成「前台 GUI 副本」并抢走 `instance.lock`，让真正的 GUI 静默 `exit(0)`；
  现在按 bundle id 判定，一律进后台模式。

### Changed — 互斥判定改成进程内调用（不再 fork 自身）

- `MainWindow.runEnsure` 每次判定都会 fork 一份自身可执行文件（`--ensure=… --json`），一次
  界面动作就多一个进程、多一次 1.2 s 采样差分。现在改为**同进程**调用
  `HubEnsure.decide(target:ask:forceSwitch:)`，采样放后台队列，结果回主线程弹窗。
- `HubEnsure.run`（CLI 入口）拆成两层：`decide` 只算并返回 `Outcome`，`run` 负责打印与退出码；
  `--ensure` / `--release` 的对外行为不变。
- 新增 `--self-test-admit=<模型>`：在后台队列跑一次与界面完全相同的判定并打印结果，用来验证
  「不再 fork 自身」这条路径（不建 AppKit、不动模型）。

### Fixed — 「挂载待机」的模型不算互斥占用

- 判断「谁在跑」时只认 `running` / `loading`，漏了 `idle`（模型已加载、占着内存但没在解码）。
  于是一个占着几十 GB 的模型挂着待机时，中枢对「拉起另一个重模型」仍答「与在跑的模型不互斥」，
  真叠上去会把机器压爆。界面各处一直是三态一起算，这里对齐。

## [1.8.1] — 2026-11-04

### Fixed — 引擎归属：ComfyUI 是引擎，不是模型

- **引擎可以「认领」模型**：`modelOverrides` 新增 `assignedEngine`，把磁盘上的模型挂到某个引擎托盘下，
  不必为每个模型都写一条启动配方。归属优先级：配方声明的 `engine` → `assignedEngine` → 运行时自报 →
  「未绑定引擎」托盘。
- ComfyUI 的配方改为声明 `engine: "ComfyUI"`，因此它自己形成一个引擎托盘；Qwen-Image 2.1 / Edit 系列的
  权重通过 `assignedEngine: "ComfyUI"` 落在同一个托盘里，不再孤零零地待在「未绑定引擎」。
- `--explain` 增加「归属引擎」一行，托盘归属可直接查。

## [1.8.0] — 2026-11-04

### Added — 模型识别层完全数据驱动 + 引擎托盘 + 可排序

- **识别规则进数据**：新增 `registry.json` 的 `classifyRules` / `modelOverrides` / `engineFamilies`，
  模型类型、别名、是否属于「部件」全部可由用户配置，**改规则不必重新编译**。
- `--explain=<目标>`：打印某个条目命中了哪条规则、证据是什么（规则可查，不靠猜）。
  `--mgmt-list --all` 显示被折叠的部件；`--mgmt-action` 支持 `id` / `recipe:<id>` / `engine:<名>` 三种写法，
  名称有歧义时报错并列出候选，不静默猜一个。
- **引擎托盘**：模型管理器按「能启动它的引擎」分组，引擎即托盘；没有配方的进「未绑定引擎」托盘
  （诚实单列，不按文件格式瞎猜）。托盘一行放不满会并排 2～3 个。
- **排序**：托盘（调用次数 / 名称）、模型（调用次数 / 名称 / 大小），默认按调用次数；
  调用次数跨重启累计（引擎计数归零时按增量累加，不丢历史）。
- **类型视觉**：每张卡片标题行带类型图标，并有同一枚图标放大成半透明**水印**铺在卡片底上，
  形状 + 颜色双通道，远看就能分辨推理 / 生图 / 视频 / 语音 / 嵌入 / 服务。
  图标与配色也可用 `registry.json` 的 `categoryVisuals` 覆盖。

### Changed — 部件不再占列表

- LoRA、投影层、VAE、ControlNet 这类**部件默认折叠**，不再混在模型列表里当模型摆着；
  头部提示「已折叠 N 个部件」，需要时 `--all` 或 `defaults write … dk.showParts -bool YES` 展开。

### Fixed

- 内存池刻度画在了「池外」小箱右侧，看起来像小箱也带整机容量的刻度：现在刻度紧贴池壁，
  池外小箱挪到最左、明显缩小（更窄更矮），不再与池壁刻度共用一个视觉轴。
- 配方匹配用字符串包含判断，导致一个配方的运行状态被写到另一个模型的卡片上（幽灵卡片、重复卡片）。
- 停止命令在「没有进程可杀」时返回非零退出码，被误报成「停止失败」。
- 主权重目录名里含 `mtp` / `lora` 字样时被误判成部件。

## [1.7.0] — 2026-11-03

### Added — 管理 API（给用户的 AI 用）+ 程序本体完整性

- `--api '<json>'`：一个请求一行 JSON 回答，`model.add/update/remove/launch/stop`、
  `config.get/set`、`workgroup.*`、`status`、`doctor` 全都有；不依赖 GUI 在跑。
  写 `registry.json` 走「读原始 JSON → 改字段 → 原子写回」，不丢未知字段，写前留 `.bak`（保留 5 份）。
  文档：`docs/CLI_API.md`；契约测试：`tests/verify_api.sh`（28 项，全部在临时状态目录里跑）。
- `--doctor`：清单哈希 + `codesign --verify` + 配置语义 + LaunchAgent + 中枢新鲜度，一次全查。
- **完整性清单**：`build.sh` 在签名前写 `Contents/Resources/manifest.json`（资源 SHA-256），
  启动时检测程序本体是否被改过并提示（`DOCKOLATE_SKIP_MANIFEST=1` 可跳过）。
- **安装留旧版**：`--install` 把旧 bundle 移到 `~/Applications/_prev/`（保留 3 份），
  `build.sh --rollback` 一键回滚。
- **系统版安装**：`tools/install-system.command` 装到 `/Applications`，`root:wheel` + 去写权限
  （同用户进程改不动），配套 `tools/uninstall-system.command`。
- 状态目录统一走 `SupportDir`，支持 `DOCKOLATE_SUPPORT_DIR` 覆盖（测试隔离用）。
- 配方语义校验：重复 id / 端口冲突 / 越界端口 / 缺 start / 估算荒谬 ⇒ 显式 warning，`--doctor` 可见。

### Changed — 蓄水池改「敞口水箱」（废弃冰山，2026-11-03 用户裁定）

- 水箱恢复**固定大小、顶部开口**：只画左右两壁与池底，口沿不封线；空闲统一挪到最上面，
  改**绿色**。
- 模型浮出池口的部分画**红色**警告，口沿上方给「溢出 N GB（模型名）」气泡。
- 未载入内存的权重移到池子右侧下方的**「池外」小箱**：颜色与池内同名模型一致、名字相同，
  不再在池内凸起（冰山方案下线）。
- 模型改为**按体积竖直叠放**：并排多列会让各列起始高度错开，并在高处留出读不出含义的空白。
- 色块高度 ≥ 17 pt（按字体量出）才在块内居中写名字，低于阈值不写（名字仍在图例里）。
- 修**假溢出**：`系统 / 应用与其他 / 压缩` 按权重分「已用 − Σ模型」，不再把模型的 Metal 页
  既算进 wired 又算进模型列（实测（同机复现）会算出超过物理内存的合计）。
- 新增验收：`--demo-pool` / `--demo-pool=overflow` 与 `--dump-pool`（导出与绘制同源的几何）。

### Added — 内存蓄水池（冰山视图 · 已被第四版取代）

- 「内存池」条换成**竖直蓄水池**：顶部模型（实心＝已驻留 / 虚线＝未加载）→ 空闲 →
  沉底（应用与其他 / 系统内核 / 压缩 / **预留在最底**）。
- **驻留口径改进程树 RSS**：footprint 不计 mmap 权重页（大模型：只有进程树 RSS 的三分之一左右），
  实测让「系统与其他」那根巨大灰条缩掉大半 —— 原先那块灰条的真因。
- **池内不写字**：层名与数字全在右侧图例（配小色块），池内只靠拉开颜色的色块区分。
- **版式统一**：所有色块圆角矩形（r=3）+ 统一 3 pt 窄缝；薄层（<4 pt）不缩缝、改用 r=1.5，
  空闲带加 0.8 pt 描边，保证 1–2 GB 的空闲也看得见。
- **动态头寸**：水池上沿会随「最高的冰山尖」抬高（水面到窗口上沿的距离可变），
  冰山尖因此永远有地方露出水面；模型不跑时头寸归零。冰山顶用模型色 45% 填充 + 虚线边，
  空闲改白色（＝空的），避免两者被读反。
- 缓慢浮动动画：±1.6 pt / 8 fps，只在窗口可见、模型 ≤3、系统未开「减弱动态」时跑。
- 新增 `--shot-pool=<png>` 单独渲染蓄水池；演示数据改成自洽的一组数字。
- **页序**：蓄水池置顶（用户令）→ 模型运行时 → 模型管理器 → 工作组；蓄水池与扫盘无关，
  刷新时就先画（否则开始扫盘那几秒顶部是空的）。

### Changed — AI 管理的模型方块重做（等宽、变高、按状态着色）

- **方块等宽、只改高度**：高度 = 模型大小，走凹函数 `112 + 104·sqrt(size/sizeMax)`（与内存池段长同一条曲线）。
- **方块表面按状态着色**：蓝＝运行中/待机，琥珀＝拉起中/停止中（边框加粗），绿＝可拉起，
  黄＝勉强够，红＝内存不足，灰＝不可单独起/未配置启动方式。用不透明混色，浅底上才看得见。
- **单一砖石网格**：不再按分类切成多段（每段只剩一两行 ⇒ 一列装不下几块）；
  分类降为方块内的小标签，落块进「当前最矮的列」。
- **紧凑方块**：高度 < 150 pt 的方块藏副标题与状态行，只留名称/盘占/按钮。
- **长名换行**：两行显示并在第二行末尾省略，不再靠加宽方块。
- **页序调整**：模型运行时 → 模型管理器 → 内存池 → 工作组（管理器提到内存池之前，
  默认窗口里一列从 2 块变成 4 块上下）。
- 演示数据补了「勉强够」一档（`--demo-models` 才能验收黄色）。
- 新增 `--dump-tiles`：渲染时导出每个方块的真实 frame（id/y/h/x/w），几何验收不靠看图估。

### Added — 模型运行时里直接卸载；launch 结果落日志

- **「模型运行时」每行右侧新增「卸载」按钮**：内存里正在跑的模型就地卸载，不用再滑到下面的
  模型管理器里找同一张卡。判据与管理器一致（`canStop`），停止过程中按钮变「停止中…」并禁用，
  走的仍是同一个 `actions.stop`，所以端口释放 / 内存回收等待与管理器完全一致。
- **`action-<id>.log` 记录结果行**：`✓ 停止完成（退出码 0，端口已释放）` /
  `✓ 已拉起（端口 N 就绪）` / `✗ 启动命令退出码 N` + launcher 输出尾巴。此前只记
  `spawned pid`，launcher 以非 0 退出（例如内存闸门 `return 7`）时日志里没有任何痕迹，
  用户看到的就是「点了没反应」。

### Added — 生图 / 视频改显示「轮次 · 每轮耗时 · 当前这轮」

图片和视频模型不再显示 prefill / decode（媒体引擎根本没有这两个阶段）。配方里声明
`"media": "comfyui"` 或 `"media": "mlxserve"` 后，那一行改显示：

- **已出 N 张 / 段**（按产物边界数，不按 HTTP 请求数）
- **平均 / 最近 / 最快最慢 每轮耗时**（观测到的轮次少于总轮次时标「（观测 N 轮）」）
- **当前这张 / 这段已用多久**，视频带 `12/20 步`；队列里还有几个（ComfyUI）

来源：ComfyUI 走 `/queue` + `/history`（`execution_start` / `execution_success` 毫秒时间戳，
轮次与耗时是引擎真值）；H3 / mlx-serve 走引擎日志的三条边界（开轮 / 步 / 出片）。
观测不到起点的那一轮只计轮次、耗时标「未观测」——不猜数字。

新增 `--media=<端口> [--watch=秒]` 在终端直接验媒体指标；`--shot-height=N` 按任意高度离屏截图。

### Fixed — ComfyUI 在界面里变成两张卡

只有端口、没有引擎名与权重模式的服务配方，之前匹配不上自己的运行行，管理器里同时出现
「ComfyUI（未运行）」和「ComfyUI（运行中）」；现在按端口认领（自检里有断言）。
H3 配方的 `log` 路径原本指向一个不存在的文件名，已改成实际写日志的那个。

## [1.6.0] — 2026-10-28

### Changed — 主界面改卡片式，拆成「首页 / AI 管理」两页

窗口不再是一屏手工摆位的读数，而是可滚动的卡片页（`docs/DESIGN.md` 是新的设计权威）：
首页放三格总览、内存去向堆叠条、本机 AI 模型、进程三榜；AI 管理放运行时指标、模型管理器、工作组。
布局全部 Auto Layout + `NSStackView`，卡片的宽度跟随页面，不再靠坐标硬凑。

### Added — 模型运行时指标（这一趟跑了多久 / 多快）

每个在内存里的模型可以展开看：**运行时间、平均 prefill、平均 decode、请求数、输入/输出 token、
平均 TTFT、数据来源**。三条来源按可靠性排序：

- **某 MLX 引擎的 `/metrics`（JSON）** —— `Σprompt_read ÷ Σprompt_ms` 是真 prefill（不含前缀缓存），
  `Σoutput ÷ Σdecode_ms` 是 decode，`since` 给起算时间；
- **Prometheus `/metrics`**（llama.cpp / vLLM / SGLang / TGI）—— 累计 token ÷ 累计秒；
  llama.cpp 需要 `--metrics` 启动，否则界面照实写「指标来源未配置」；
- **引擎日志**（引擎日志里的 `Done · input … cached … · TTFT … · tok/s`）—— prefill 剔除缓存命中，
  按本次加载的起始标记切分、增量读取。

拿不到就写「—」，不编数字。另一类引擎日志里的 `reading the prompt` 含缓存命中，
按它算会得到 1 万 tok/s 的假数，代码里已明确不用它算 prefill。

### Added — 本地模型管理器

- **扫盘识别 + 自动分类**：对话/推理、生图、视频、语音、嵌入/检索、服务、部件；
  同一模型目录下的主权重与部件（`transformer` + `vae` / `text_encoder`、`IQ3_S` + `mtp`/`mmproj`）
  归成一行；扫描根下互不相干的散件不硬凑。
- **内存可行性三色**：估算 = 权重（磁盘实测）+ 开销（按类别 10–22%），跑过一次后改用实测峰值；
  配方可声明 `estMemGB`（MoE + mmap 的模型，权重文件 ≠ 常驻）。
  可用 = 物理 − 已用 − 余量（默认 6 GB）：绿 ≤ 可用×85%，黄 ≤ 可用，红 > 可用。
- **统一拉起 / 卸载**：`launchers.json` 的配方（shell 串或 argv 数组）驱动；
  Ollama 与 LM Studio 有内置适配器；没有配方的条目明说「未配置启动方式」，
  运行中的可以「结束进程」。**启动命令可以是常驻进程**（llama.cpp / ComfyUI），
  以「端口就绪」判成功，超时会清掉没退出的子进程。
- **工作组**：把几个模型绑成一个名字一起拉起 / 一起停，合计估算同样三色判定能否并存。

### Fixed

- **家族名被版本号截断**：`deletingPathExtension` 把 `My-Chat-Model-27B-…` 的 `.8-27B-…` 当成扩展名，
  列表里只剩 `Qwen3`。只剥已知权重扩展名。
- **带 MTP 头的主权重被误判成「草稿头」**：角色以 `config.json` 的 architectures 为准。
- **HF 缓存里的符号链接字节数按链接本身算**：整份权重显示「盘 —」，现按目标文件统计。
- **默认扫描根顺序**：用户目录排在 HF 缓存前面，按 inode 去重时不会把用户目录那份丢掉。
- **扫盘用过期快照对账**：扫盘只缓存磁盘单元，运行时对账每次探测后重算，不再出现「全都没登记」。
- **服务类配方的目录不再当扫描根**：否则 ComfyUI 那种目录会变出十几行「几十上百 GB 的模型」。
- **没拉起过的模型也挂着可点的「卸载」**：判断写成了「有停止配方就算能卸载」，
  应该只对**真的在内存里**的模型（运行 / 待机 / 加载中）生效。现在未运行的条目只有「拉起」可点，
  运行中的才亮「卸载」（无 stop 配方时退化为结束进程，tooltip 说明）。
- **内存口径在 GPU 高负载时虚高**：macOS 26+ 的 Metal 显存既算匿名页也算 wired，
  「应用 + 联动 + 压缩」会超过物理内存（实测会算到超过物理内存的合计），「可用」永远是 0、
  管理器把所有模型都判成放不下。现在超过物理内存时改用 `max(应用, 联动) + 压缩`，
  窗口里两段合并成「应用+显存」并注明重叠；常规机器仍走老口径。
- **进程识别**：`python -m serve/server.py --engine strata` 这类包装进程现在能认出引擎名
  （只看 argv[0] 会被端口兜底表叫成 llama.cpp）；参数里的路径只取最后一段
  （`~/models/...` 曾让 llama.cpp 的进程被认成 MLX）。

### Tests

`tests/verify_manager.sh`（46 条断言：分类 / 估算 / 三色 / 配方匹配 / 引擎日志 / 引擎 JSON），
并接入 `tests/verify_all.sh` 的发布前矩阵（同时补拍 AI 管理页截图）。

## [Unreleased]

## [1.5.0] — 2026-10-28

### Added — 签名表外置：新引擎不必等发版（方案 M4）

The parts of detection that are **pure data** now live in `resources/adapters.json`
(inside the bundle) and can be extended without rebuilding the app:

| 段 | 作用 |
|---|---|
| `processHints` | 进程特征词 → 引擎显示名（外部条目优先于内置 68 条） |
| `ports` | 端口 → 兜底显示名（只在进程认不出来时用） |
| `states` | 引擎自报的状态串 → `resident` / `loading` / `failed` / `absent` |
| `roles` | 文件名/目录特征词 → 角色（草稿头 / 投影 / LoRA / VAE / 文本编码器） |
| `probePaths` | 诊断与发现报告里额外探测的路径 |

叠加顺序：内置 → `~/Library/Application Support/Dockolate/adapters.json`（用户覆盖）
→ `DOCKOLATE_ADAPTERS=<path>`（排障/测试）。**解析失败只警告、不致命**：坏 JSON 不会让应用起不来。

`--check-adapters` 打印每份来源是否读到、条目数与解析警告——加完数据用它确认加对了。

### Added — 发布前自检矩阵

```bash
bash tests/verify_all.sh        # 三套回归 + 一趟「干净环境」冒烟，产出 tests/last_report.json
```

- 三套回归：引擎探测（28 条断言 / 10 fixture）、身份+清单（15 条）、签名表外置（14 条）；
- 「干净环境」= 换一个**空的 HOME**（没有模型、没有配置、没有缓存）：清单为空、无引擎时探测正常返回、
  两个窗口仍能渲染出非空白 PNG、发现报告是合法 JSON；
- 结果写成 `tests/last_report.json`，可直接附在 Release 里。

### Added — 签名表回归（关键一条）

`tests/verify_adapters.sh` 端到端验证「不改代码就认新东西」：
同一台假引擎、同一个二进制，仅靠一份 JSON，就把一个二进制**没见过**的状态串（`warmup-x`）
从「待确认」变成正常显示；再用一个名字本身就是特征词的假引擎二进制，验证进程指纹命名。
坏 JSON 也覆盖：只警告、返回非 0、引擎探测照常。

## [1.4.0] — 2026-10-28

### Added — 身份层：这是哪个版本，不再靠名字猜（方案 M2）

- Reads the **file header**, not the file name: GGUF header KV (`general.architecture`,
  `general.name`, `general.size_label`), the safetensors JSON header, and `config.json`
  (`architectures` / `model_type` / `quantization{bits, group_size, mode}`).
- Distinguishes **role**: 主权重 / 草稿头（MTP）/ 视觉投影（mmproj）/ LoRA / VAE / 文本编码器 —
  from the GGUF architecture suffix, the file name, or the ComfyUI-style parent directory.
- Dedupe by **inode**, not by path: hard-linked copies of the same bytes (and HF snapshot
  symlinks into `blobs/`) collapse into one row, so the disk totals stop double-counting.
- A directory that holds only draft heads / projectors and has subdirectories is treated as a
  **container**, not a model — that is what turned "a folder of loose gguf files" into fake models.

### Added — 清单层：盘上有哪些版本，看得见（方案 M3）

- Scans **known stores only** (Hugging Face cache, Ollama manifests, LM Studio, ComfyUI model
  directories) plus `modelDirs` from `engines.json` plus **the directories a running engine
  declared in its own argv** (`--model-dir` / `--model-path` / `--model`) — "where the engine
  loads from" is better evidence than guessing a user's folder.
- Reconciles three sources (engine-reported id × header identity × disk directory) by score, so
  a running 8-bit model is linked to its 8-bit directory and not to the 4-bit sibling.
- New rows for weights **no engine has registered** (state 在盘未登记), plus a new
  **本机模型清单** window (menu ⌘I) that lists everything with quantization, role, disk and memory.
- Only counts a directory as a model when there is positive evidence (config.json, real GGUF
  header, or safetensors); a lone `.bin` pack is not a model.

### Added — 诊断

- `--identify=<path>` prints one weight tree's identity.
- `--inventory [--json] [--dirs=a:b] [--no-defaults]` prints the reconciled list.
- `--shot-inventory=<png> [--demo-inventory]` renders the new window in-process (no screen
  recording permission needed).
- `--discovery-report=<file>` exports a **redacted** JSON (payload shapes, candidate scores, chosen
  adapter, counts) — no model names, no paths, no pids, no keys.
- `tests/verify_identity.sh` + `tests/make_fixture_tree.py`: 15 assertions over a synthetic weight
  tree (MLX dir with `quantization`, GGUF with a real header, draft head, hard-link duplicate,
  empty shell, VAE role).

### Fixed — 截图验收与系统外观解耦

- The in-process window capture now paints the window background inside the bitmap's own graphics
  context. In dark mode the previous code produced white text on a transparent (→ white) buffer,
  i.e. an apparently blank window.

## [1.3.0] — 2026-10-28

### Changed — detection is scored, not first-match (plan M0 in `docs/引擎发现_方案v1.md`)

- Every known shape is collected first and the answer is chosen by **how much the payload
  actually says** (per-model state > resident bytes > disk/quant fields > a bare id list >
  an empty array). Previously the first branch that parsed won — that is exactly how a
  half-Ollama-compatible server with a rich `/v1/models` had its state ignored.
- A "nothing is loaded" conclusion now needs **two independent negatives** (`/v1/models`
  reporting nothing resident *and* `/api/ps` being empty). With fewer, the row reads
  **待确认 / unconfirmed** and the tooltip names what was observed instead of asserting a negative.
- State strings the app does not recognise are shown **verbatim**
  (「引擎自报状态 "warmup-x"」) instead of being folded into "not loaded".
- A port that answers but whose payload matches no known shape now gets an
  **unconfirmed** row rather than vanishing — only when there is evidence it is a model engine
  (process identified by fingerprint, or the port declared by the user), so macOS system
  services sitting on default ports do not turn into noise.

### Added — regression suite and diagnostics

- `tests/verify.sh` + `tests/fixtures/*`: ten recorded payload shapes (Ollama classic, the
  empty-`/api/ps`-but-stateful regression, loading, unknown state, ids-only, LM Studio, A1111,
  ComfyUI, unrecognised shape, all-empty), 28 assertions, run against `--engines`.
- `--probe=<port>` prints every probed path, the payload **shape** (keys / types / counts —
  never values), every candidate with its score, and the chosen adapter: safe to paste into a
  bug report.
- `--engines --ports-only` restricts scanning to the declared ports (used by the suite).
- The model-row footnote now counts hidden **unconfirmed** rows when the four-row limit pushes
  them off the list.

## [1.2.0] — 2026-10-28

### Fixed — engines that report per-model state were read from the wrong endpoint

- The Ollama probe (`GET /api/ps`) ran first and claimed any server that also speaks
  the Ollama API. Such a server (e.g. **mlx-serve**) lists only *fully resident* models
  there, so a model that was still loading — or an engine that loads weights on demand —
  showed as "no model loaded" while every weight on disk was dumped into the
  "not loaded" list. The engine itself was also mislabelled.
- `GET /v1/models` is now read **first** when its entries carry per-model state
  (`state` / `loaded` / `bytes_resident`), and `loading` / `error` are reported as such.
  Only when those fields are absent does detection fall through to the Ollama /
  LM Studio / OpenAI-compatible branches — Ollama's own `/v1/models` has no state
  fields, so Ollama detection is unchanged.
- New status **loading** (amber): weights on their way into memory, not yet serving.
- When a server reports `bytes_resident`, that number is shown for the model instead of
  the process footprint — one process can host several models, and process memory is
  then only their sum.

### Fixed — model names

- Repository-style ids keep their prefix (`org/model`, `subdir/model`) instead of being
  cut down to the last path component; only absolute paths and weight file names lose
  their directory. The Ollama-compat `:latest` tag is dropped, real tags (`:8b`) stay.

### Changed — engine names on custom ports

- A process identified by fingerprint now names the engine even when its port is not in
  the fallback table, instead of the generic "local model server" label.

### Added

- The "not loaded" footnote is fitted to the label's real width and collapses to
  "… and N more" rather than being silently cut off by an ellipsis; the full list is in
  the tooltip.
- `--shot-panel=<png>` renders the main window to a PNG **in-process**, so UI can be
  reviewed on machines that have not granted screen-recording permission;
  `--demo-models` injects a snapshot covering running / loading / idle / failed.

## [1.1.1] — 2026-10-23

### Fixed — no machine-specific ports in public code

- Dropped three **non-default** ports from `knownEngines` (multi-instance llama.cpp
  numbers and one used by a retired local engine). That table only supplies a fallback
  *name* for processes that cannot be identified — a process's real listening ports are
  discovered and probed anyway — so hard-coding non-default numbers just freezes one
  machine's history into shared code.
- Removed the extra SD.Next port too: SD.Next reuses A1111's 7860, so that label now
  reads `A1111 / SD.Next / Draw Things`. Fooocus moved to its official default 7865
  (the old value was habit, not its default).
- Concrete port numbers in comments and changelog prose became generic wording
  ("a reverse proxy / gateway port"), and machine-specific memory figures were dropped
  from code comments — those describe an operating site, not the detection rule.

## [1.1.0] — 2026-10-23

### Added — engine whitelist

- Process hints (`kindHints`) went from 30 to **68 keywords** covering four families:
  conversational (Ollama, LM Studio, llama.cpp/llamafile, vLLM, SGLang, TGI,
  TensorRT-LLM, LocalAI, Xinference, FastChat, OpenLLM, LiteLLM, TabbyAPI,
  KTransformers, MLC LLM, RamaLama, Petals, GPT4All, Jan, Docker Model Runner,
  text-generation-webui, KoboldCpp), MLX-family engines (Splash, oMLX, MTPLX,
  MLX 系与 mlx_lm/mlx_vlm 服务), image/video (ComfyUI, SwarmUI,
  Fooocus, InvokeAI, SD.Next, sd.cpp, A1111/Forge/reForge, Draw Things,
  DiffusionBee, Amuse, mflux, Qwen-Image, Flux, Wan, MiniMax, HunyuanVideo,
  LTX-Video, CogVideo) and speech (Whisper, Kokoro, Coqui, ChatTTS, Piper, XTTS).
- `knownEngines` fallback port table: 16 → 19 entries, official defaults only
  (added Jan 1337, GPT4All 4891, OpenLLM 3000, LiteLLM 4000, Xinference 9997,
  SGLang 30000, SwarmUI 7801, Fooocus 7865).
- Ordering is documented in-file: specific patterns precede generic ones
  (`reforge` before `forge`, `text-generation-webui` before `webui.py`), and
  `quickHints` deliberately omits broad words (`swift`, `exo`, `wan`) so the 2-second
  scan does not parse argv/fd tables of unrelated processes.
- `knownEngines` now carries an explicit warning **not** to register a reverse proxy
  or gateway port as an engine — a proxy listed as an engine reports the same model
  twice.

### Fixed — engine rows for two-layer engines (某 MLX 引擎)

- **A model whose weights live in a child process was reported as an idle shell.**
  Each engine row took its memory and activity from whichever process *listens* on
  the port. 某 MLX 引擎 serves HTTP from a small Python parent and runs the
  model in an `engine/splash serve-native` child (tens of GB, all the GPU work), so the
  row read **「挂载待机 / 只有父进程那点内存」** while the machine sat at 60–85 % GPU decoding —
  and `splash` was not in the process-name hints at all, so the child was never
  scanned to begin with.
- Fix: `splash` added to the process hints; every engine row now aggregates memory
  and CPU/GPU activity across the holder's **process tree** (`ppid` read via
  `PROC_PIDTBSDINFO`), and descendants of a claimed holder are skipped instead of
  being listed a second time.
- Verified live (2026-10-23, Apple Silicon): row went from `挂载待机`（只看到父进程） to
  `正在运行`（父 + 子合并）with the engine showing 85 % GPU. Cross-check: the app's own
  top-memory list read the same figure for the child, and parent + child matched the
  reported total.
- Whitelist verified with a fake OpenAI-compatible server on a spare port: it was picked up
  as `Xinference` and listed both served model ids, with no duplicate row for the
  two-layer engine's parent/child pair.

### Docs — discoverability

- New **landing page** `docs/index.html` for GitHub Pages
  (https://autugit.github.io/dockolate/) — `SoftwareApplication` + `FAQPage`
  JSON-LD, OpenGraph/Twitter cards, direct download button.
- README (EN + zh-CN): new "Common questions" section — nine natural-language
  questions a stranger would actually type (GPU without `sudo`, which local
  models are resident, Apple Silicon vs Intel, permissions, difference from
  iStat Menus / Stats / Activity Monitor, custom ports, the name).
- Repository topics 10 → 15: `apple-silicon`, `cpu-monitor`, `local-ai`,
  `macos-app`, `resource-monitor`.
- `docs/开发文档.md` §13 records the measured search-index state: GitHub repo
  search finds the repository, GitHub code search does not yet, and web search
  engines have not indexed it (the repo was ~20 h old with zero inbound links).

## [1.0.0] — first public release

The first version published on GitHub. Everything below was already running on a
day-to-day machine before release; the engine table was verified against fake
servers speaking the real protocols (see *Verification* at the end).

### Dock icon

- 2×2 water-level gauge: `C` CPU (top-left), `G` GPU (top-right), `M` memory
  used (bottom-left), `Z` compressed + swapped (bottom-right). No digits —
  colour and level carry the meaning at Dock size.
- Four colour bands: <20 % blue, 20–50 % green, 50–80 % yellow, ≥80 % red.
- Repaints only when an integer percentage changes (0.5 s interpolation,
  2 Hz), which is what keeps the app at ~1.5–2.3 % CPU.

### Window

- **Local AI models in memory**, sorted by footprint, each row tagged
  running / loaded-idle / failed, with a separate line for downloaded-but-not-
  loaded models.
- Top 3 processes by CPU, by **per-process GPU** (no `sudo`, no `powermetrics`),
  and by physical memory.
- Memory breakdown (app / wired / compressed / cached / free), swap usage, and
  the `Z` pressure reading.
- Row count adapts to how many models are present; the window shrinks instead of
  leaving blank rows.

### Engine discovery

- Zero-config port table covering Ollama, LM Studio, llama.cpp, vLLM, MLX/oMLX,
  ComfyUI, A1111/Forge, Draw Things, Fooocus, InvokeAI, KoboldCpp,
  text-generation-webui and any OpenAI-compatible endpoint.
- Model names come from each engine's own API (`/api/ps`, `/api/v0/models`,
  `/sdapi/v1/options`, `/queue`, `/v1/models`), never guessed from config.
- Engines behind API keys: add keys in
  `~/Library/Application Support/Dockolate/engines.json` or via
  `DOCKOLATE_KEY_<port>`; without a key the row shows the engine name and port
  instead of inventing a model name.

### Display surfaces

- Dock icon readout and menu bar readout are independent checkboxes, persisted
  in `UserDefaults`. Both, either, or neither.
- Menu bar readout: compact colour-coded `C12 G40 M63`.

### Packaging

- MIT licence, English and Chinese READMEs, single `swiftc` build, no
  dependencies, LaunchAgent for login start + crash restart.

### Fixed during development

- macOS 27 kernel `socket_info` is 24 bytes larger than the SDK header; naive
  casting returned garbage ports (`soi_kind == 0`). Fields are now read by byte
  offset with the returned size as the shift, plus a family/state double check.
- Window height used an incremental `height -= delta` and could shrink to
  nothing when the model count toggled; it is now computed from a base frame.
- A LaunchAgent plus a user `open` started two instances fighting over the Dock
  icon. Comparing pids was not enough: on login the LaunchAgent's `RunAtLoad` and
  the Dock's session restore launch both copies within the same second, and each
  looks for the other before the other has registered — both survived and drew a
  Dock icon. Single-instance is now arbitrated by an exclusive `flock` on
  `~/Library/Application Support/Dockolate/instance.lock`; the loser activates the
  winner and exits. Verified by launching two copies simultaneously.
- Engine restarts left two rows for one engine (an old process without a port
  next to the serving one); orphan memory is merged into the serving row.
- `screencapture -R` grabs whatever window is on top; verification uses
  `screencapture -l<windowNumber>` instead.

### Verification before release

- Icon geometry and colour bands checked by exporting the drawn PNG
  (`--dump --mock=…`) and reading it back, not by eyeballing the Dock.
- Engine protocol layer checked with local fake servers speaking the real
  response shapes for Ollama (`/api/ps` + `/api/tags`), LM Studio
  (`/api/v0/models`) and A1111 (`/sdapi/v1/options`); the running / not-loaded
  split and the `[hash]` suffix stripping were confirmed.
- ComfyUI and an oMLX deployment verified on real hardware, including the
  `ckpt_name` lookup through `/queue` → `/history`.
- **Not verified against real installations** of Ollama, LM Studio or A1111 —
  those were only exercised at the protocol level. Reported plainly so nobody
  mistakes it for a tested integration.
