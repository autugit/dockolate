# DockStats

在 macOS Dock 图标上**实时显示 CPU / GPU / 内存占用率**，无需打开任何窗口。

图标布局是「上二下一」：左上 CPU、右上 GPU、下方通栏 MEM，每格一个大号数字 + 底部细进度条。
颜色随负载分级：< 50% 绿 / 50–80% 黄 / ≥ 80% 红。

```
┌─────────┬─────────┐
│ CPU  14%│ GPU   0%│
│ ▓▓░░░░░ │ ░░░░░░░ │
├─────────┴─────────┤
│ MEM           22% │
│ ▓▓░░░░░░░░░░░░░░░ │
└───────────────────┘
```

顺带在菜单栏右侧给一份 `C14 G0 M22` 的紧凑读数；点 Dock 图标可开详情窗口。

## 安装

```bash
./install.sh
```

会编译、装到 `~/Applications/DockStats.app`，并注册 LaunchAgent（登录自启 + 崩溃 5 秒内自拉起）。

## 卸载

```bash
./uninstall.sh
```

## 只编译不安装

```bash
./build.sh          # 产物：build/DockStats.app
```

## 自检 / 验收

```bash
# 采样一次并把图标导出成 PNG（无屏幕录制权限也能验）
./build/DockStats.app/Contents/MacOS/DockStats --dump --out=/tmp
# 强制指定数值，验收边界态（如三位数不溢出）
./build/DockStats.app/Contents/MacOS/DockStats --dump --mock=100,100,100 --out=/tmp
```

## 数据口径

| 指标 | 来源 | 口径 |
|---|---|---|
| CPU | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` | 两次采样间全核 busy/total 增量比 |
| GPU | `ioreg -c IOAccelerator` → `Device Utilization %` | 设备整体利用率，免 root |
| 内存 | `host_statistics64(HOST_VM_INFO64)` | (活跃 + wired + 压缩器占用) / 总物理内存 |

采样节奏：CPU/内存 1 秒、GPU 2 秒；显示按 0.5 秒插值平滑；
图标只在**整数百分比**变化时重绘（小数抖动肉眼不可见，重绘纯属浪费）。
实测自身开销约 **1.8% CPU / 87 MB**。

详见 `docs/开发文档.md`。
