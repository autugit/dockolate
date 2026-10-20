# DockStats

在 macOS Dock 图标上用**水位**实时显示 CPU / GPU / 内存 / 内存压力，无需打开任何窗口。

图标是 2×2 四宫格，每格一个字母水印 + 从底部升起的水位，高低和颜色一眼看出紧迫程度：

```
┌────────┬────────┐
│   C    │   G    │   C = CPU      G = GPU
│  ▓▓░░  │  ▓░░░  │   （蓝色水位 = 极低）
├────────┼────────┤
│   Z    │   M    │   Z = 压缩+换页   M = 内存
│  ▓▓▓▓  │  ▓▓▓░  │   （绿/黄/红随水位升高）
└────────┴────────┘
```

水位配色：**< 20% 蓝 · 20–50% 绿 · 50–80% 黄 · ≥ 80% 红**

- 图标里**不放数字**——数字会跟字母抢地方，而且 Dock 尺寸下也读不准；精确值去窗口看。
- 点 Dock 图标 → 弹出窗口：**CPU / GPU / 内存占用最高的各三个进程**，外加内存去向（应用/内核/压缩/缓存/空闲）与换页量。
- 菜单栏读数默认关闭，窗口里的「菜单栏读数」按钮可随时打开。

### Z 是什么

**Z = 内存压缩 + 换页水位** = (压缩内存 + 已换页) ÷ 物理内存。
它和 M 是两个维度：M 看「用了多少」，Z 看「被挤压了多少」——
Z 越高说明系统为了腾地方压得越狠、换出去的越多，内存越紧张。

## 安装

```bash
./install.sh
```

会编译、装到 `~/Applications/DockStats.app`，并注册 LaunchAgent（登录自启 + 崩溃 4 秒内自拉起）。

## 卸载

```bash
./uninstall.sh
```

## 只编译不安装

```bash
./build.sh          # 产物：build/DockStats.app
```

## 自检 / 验收（无需屏幕录制权限）

```bash
BIN=./build/DockStats.app/Contents/MacOS/DockStats

$BIN --dump --out=/tmp                        # 采样一次并导出图标 PNG
$BIN --dump --verbose --out=/tmp              # 附带内存去向与 Z 的分解
$BIN --dump --mock=8,16,35,88 --out=/tmp      # 强制 C/G/M/Z 四个水位，验四种颜色
$BIN --procs                                  # 打印三个进程榜（窗口的数据源）
```

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
