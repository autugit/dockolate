# DockStats

在 macOS Dock 图标上**实时显示 CPU / GPU / 内存占用率**，无需打开任何窗口。

图标布局是「上二下一」，每格一个大号数字 + 底部细进度条，颜色随负载分级（< 50% 绿 / 50–80% 黄 / ≥ 80% 红）：

```
┌────────────┬────────────┐
│   42%      │    7%      │   ← 背景有大号半透明的 C / G
│   ▓▓▓░░░   │   ▓░░░░░   │
├────────────┴────────────┤
│ M 61%                   │   ← M 作为数字前缀
│ ▓▓▓▓▓▓░░░░              │
└─────────────────────────┘
```

- 上排左 **C** = CPU、上排右 **G** = GPU（大号半透明字母压在数字后面）；
- 下排 **M** = 内存（大写 M 放在数字前面）。
- 点 Dock 图标 → 弹出窗口，列出 **CPU / GPU / 内存占用最高的各三个进程**。
- 菜单栏读数默认关闭，窗口里的「菜单栏读数」按钮可随时打开。

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
$BIN --dump --mock=100,100,100 --out=/tmp     # 强制数值，验三位数不溢出
$BIN --procs                                  # 打印三个进程榜（窗口的数据源）
```

## 数据口径

| 指标 | 来源 | 口径 |
|---|---|---|
| CPU | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` | 两次采样间全核 busy/total 增量比 |
| GPU | `ioreg -c IOAccelerator` → `Device Utilization %` | 设备整体利用率，免 root |
| 内存 | `host_statistics64(HOST_VM_INFO64)` | (活跃 + wired + 压缩器占用) / 总物理内存 |
| 进程 CPU | `ps -r` 按 `%CPU` 降序 | 取前三 |
| 进程 GPU | `ioreg -c AGXDeviceUserClient` → `AppUsage.accumulatedGPUTime` 差 | 该客户端累计 GPU 时间（ns）增量 ÷ 墙钟 = 占整颗 GPU 的百分比 |
| 进程内存 | `ps -m` 按 `RSS` 降序 | 常驻内存实际占用 |

> 进程 GPU 是这套工具的硬货：macOS 不提供公开的按进程 GPU 统计（`powermetrics` 要 root），
> 这里靠 IOKit 的 `AGXDeviceUserClient` 拿到，实测与设备总利用率吻合（压测进程 87.4% vs 设备 85–89%）。

采样节奏：CPU/内存 1 秒、GPU 2 秒；显示按 0.5 秒插值平滑；
图标只在**整数百分比**变化时重绘（小数抖动肉眼不可见，重绘纯属浪费）。
进程榜只在窗口打开时采样，窗口关闭即停。
实测自身开销约 **0.67% CPU / 93 MB**。

详见 `docs/开发文档.md`。
