# DockStats

**A macOS system monitor that lives in your Dock icon — water-level gauge for CPU / GPU / memory, plus a live inventory of the local AI models actually loaded in RAM.**

No Electron. No dependencies. One `swiftc` invocation. ~2% CPU, ~96 MB RSS.

```
┌────────┬────────┐
│   C    │   G    │   C = CPU      G = GPU
│  ▓▓░░  │  ▓░░░  │
├────────┼────────┤
│   M    │   Z    │   M = memory used    Z = compressed + swapped
│  ▓▓▓░  │  ▓▓▓▓  │   blue → green → yellow → red as it climbs
└────────┴────────┘
```

Click the Dock icon for a window with:

- **Local AI models in memory** — sorted by footprint, each line tagged
  **running / loaded-idle / failed**, plus what's downloaded but not loaded;
- Top 3 processes by **CPU**, **GPU** (per-process, no `sudo`), and **memory**;
- Memory breakdown (app / wired / compressed / cached / free) and swap usage.

## Why another system monitor

Most macOS monitors live in the menu bar; Dock icons are barely used because
they can only be replaced with a bitmap. The Dock is always visible, so four
water-level cells answer "is this machine under pressure?" from across the
room, without opening anything.

Three things here are uncommon in existing tools:

1. **Dock icon as a gauge** — four cells, no digits, colour-coded levels.
2. **Per-process GPU without root** — sums `accumulatedGPUTime` across
   `AGXDeviceUserClient` instances from `ioreg`, instead of parsing
   `powermetrics` (which needs admin rights and a password prompt).
3. **Local AI model inventory** — which models are resident right now, how much
   RAM each holds, and whether it is actually computing. Works with Ollama,
   LM Studio, llama.cpp, vLLM, MLX/oMLX, ComfyUI, A1111/Forge, Draw Things,
   Fooocus, InvokeAI, KoboldCpp and any OpenAI-compatible server.

## Install

```bash
git clone <this repo> DockStats && cd DockStats
./install.sh          # build → ~/Applications → LaunchAgent (login item + auto-restart)
```

Uninstall: `./uninstall.sh`

Build only (no install): `./build.sh` → `build/DockStats.app`

Requires macOS 13+ and the Xcode command line tools. The build targets Apple
Silicon; for Intel change `-target arm64-apple-macosx13.0` in `build.sh` to
`x86_64-apple-macosx13.0`.

The app is ad-hoc signed, not notarized — the first launch needs
right-click → Open, or `xattr -d com.apple.quarantine /path/to/DockStats.app`.

## Two display surfaces, each optional

Bottom-left of the window: **Dock icon readout** and **menu bar readout** are
independent checkboxes; both choices persist in `UserDefaults`.

| Dock icon | Menu bar | Result |
|---|---|---|
| on | off | gauge only (default) |
| off | on | compact `C12 G40 M63` text in the menu bar |
| on | on | both |
| off | off | window only — the app keeps sampling, nothing is drawn |

The menu bar readout is a compact, colour-coded `C` / `G` / `M` + number, the
same letter-number pairing as the Dock cells.

## Supported local engines

| Engine | Default port | How the model name is obtained |
|---|---|---|
| Ollama | 11434 | `GET /api/ps` (running) + `GET /api/tags` (downloaded → "not loaded" list) |
| LM Studio | 1234 | `GET /api/v0/models`, `state == "loaded"` |
| llama.cpp `llama-server` | 8080 / 8081 / 8082 | `GET /v1/models`, `--model` argv fallback |
| vLLM / MLX / oMLX | 8000 / 8001 | `GET /v1/models` |
| ComfyUI | 8188 / 8189 | `GET /queue` → `GET /history` → `ckpt_name` / `unet_name` |
| A1111 / Forge / Draw Things | 7860 / 7861 | `GET /sdapi/v1/options` → `sd_model_checkpoint` |
| Fooocus / InvokeAI / KoboldCpp / text-generation-webui | 8888 / 9090 / 5001 / 5000 | `GET /v1/models` |
| In-app models (Draw Things, LM Studio desktop) | — | process fingerprint + `phys_footprint` |

Anything listening on a port you add is probed the same way.

### Status meanings

| Label | Meaning |
|---|---|
| **running** | process alive, port answering, **and** it computed something in the last 12 s (CPU or GPU time increased) |
| **loaded-idle** | weights are resident and the port answers, but nothing is computing |
| **failed** | the process holds a port that no longer answers |
| **not loaded** | downloaded but not resident (Ollama / LM Studio) — listed separately, holds no RAM |

Memory is `ri_phys_footprint` (Activity Monitor's "Memory" column), not RSS:
RSS can under-report by an order of magnitude for mmap-heavy models
(measured: ComfyUI shows 62 MB via `ps` and 59.29 GB via `phys_footprint`).

## Configuration (optional)

Zero config works. To reach engines elsewhere or behind an API key, create
`~/Library/Application Support/DockStats/engines.json`:

```json
{
  "extraPorts": [9000, 9001],
  "apiKeys": { "8000": "sk-your-key" }
}
```

Keys may also come from the environment: `DOCKSTATS_KEY_<port>`, or a global
`DOCKSTATS_KEY`. Engines that require auth answer 401 without a key — DockStats
then shows the engine name and port instead of a model name, and never guesses.

## Diagnostics (no GUI, no screen-recording permission)

```bash
./build/DockStats.app/Contents/MacOS/DockStats --dump --out=/tmp   # one sample + icon PNG
./build/DockStats.app/Contents/MacOS/DockStats --dump --mock=8,16,35,88 --out=/tmp
./build/DockStats.app/Contents/MacOS/DockStats --procs             # top-3 process lists
./build/DockStats.app/Contents/MacOS/DockStats --engines           # engine probe report
./build/DockStats.app/Contents/MacOS/DockStats --engines --ports=9000,9001
```

## How it works

| Metric | API |
|---|---|
| CPU | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` delta across all cores |
| Memory used | `internal + wired + compressor` pages, real page size from `host_page_size()` |
| GPU | Σ `accumulatedGPUTime` over `AGXDeviceUserClient` instances ÷ wall clock |
| Per-process memory | `proc_pid_rusage` → `ri_phys_footprint` |
| Listening ports | `proc_pidinfo(PROC_PIDLISTFDS)` + `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)` |
| Process argv | `sysctl(KERN_PROCARGS2)` |

No root, no private entitlements, no telemetry, no network access beyond
`127.0.0.1`.

### Pitfalls baked into the code

- macOS 27's kernel `struct socket_info` is 24 bytes larger than the SDK header
  (792 vs 768). Casting the result to the SDK struct silently yields garbage
  (`soi_kind == 0`); the code compensates with the returned byte count and reads
  fields by byte offset.
- `URLSession` honours the system HTTP proxy, so requests to `127.0.0.1` can
  fail behind a proxy. All local HTTP here uses raw sockets.
- The model-list window height must be computed from a base frame, never
  `height -= delta`, or repeated row-count changes shrink the window to nothing.
- A LaunchAgent plus a user `open` starts two instances fighting over the Dock
  icon; the later one activates the earlier and exits.

## Privacy

Everything is read locally. Nothing is transmitted, collected or logged.

## License

MIT — see [LICENSE](LICENSE).

中文说明见 [README.zh-CN.md](README.zh-CN.md)。
