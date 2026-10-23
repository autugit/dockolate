# Dockolate

[![Release](https://img.shields.io/github/v/release/autugit/dockolate?display_name=tag)](https://github.com/autugit/dockolate/releases/latest)
[![Website](https://img.shields.io/badge/website-autugit.github.io%2Fdockolate-e0b040)](https://autugit.github.io/dockolate/)
[![License: MIT](https://img.shields.io/github/license/autugit/dockolate)](LICENSE)
[![Platform](https://img.shields.io/badge/macOS-13%2B-blue)](https://github.com/autugit/dockolate)
[![Stars](https://img.shields.io/github/stars/autugit/dockolate)](https://github.com/autugit/dockolate/stargazers)
[![Language](https://img.shields.io/github/languages/top/autugit/dockolate)](https://github.com/autugit/dockolate)

**A chocolate bar in your Dock — water-level gauge for CPU / GPU / memory, plus a live inventory of the local AI models actually loaded in RAM.**

<p align="center">
  <img src="docs/img/dock-icon.png" width="140" alt="Dock icon: four cells, C / G / M / Z water levels">
  <img src="docs/img/window.png" width="440" alt="Window: local AI models, top processes, memory breakdown">
</p>

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
git clone https://github.com/autugit/dockolate.git && cd dockolate
./install.sh          # build → ~/Applications → LaunchAgent (login item + auto-restart)
```

Uninstall: `./uninstall.sh`

Build only (no install): `./build.sh` → `build/Dockolate.app`

Requires macOS 13+ and the Xcode command line tools. The build targets Apple
Silicon; for Intel change `-target arm64-apple-macosx13.0` in `build.sh` to
`x86_64-apple-macosx13.0`.

The app is ad-hoc signed, not notarized — the first launch needs
right-click → Open, or `xattr -d com.apple.quarantine /path/to/Dockolate.app`.

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

**Ports are discovered, not assumed.** Dockolate first looks at which ports the
identified model processes actually listen on, so a server you moved to a custom
port is still found. A small built-in default table is only a fallback for the
case where a process cannot be identified; anything else can be declared in
`engines.json`. Nothing in the list below is a requirement.

| Engine | How the model name is obtained |
|---|---|
| **Ollama** | `GET /api/ps` (running) + `GET /api/tags` (downloaded → "not loaded" list) |
| **LM Studio** | `GET /api/v0/models`, `state == "loaded"` |
| **llama.cpp / llamafile / KoboldCpp** | `GET /v1/models`, `--model` argv fallback |
| **vLLM / SGLang / TGI / TensorRT-LLM / LocalAI / TabbyAPI / LiteLLM / OpenLLM / FastChat / Xinference** | `GET /v1/models` |
| **MLX family: Splash / oMLX / MTPLX / Flash-Next / Swift-Qwen / `mlx_lm.server` / `mlx_vlm.server`** | `GET /v1/models`, argv fallback |
| **Jan / GPT4All / Docker Model Runner / text-generation-webui** | `GET /v1/models` or process fingerprint |
| **ComfyUI** | `GET /queue` → `GET /history` → `ckpt_name` / `unet_name` |
| **A1111 / Forge / reForge / SD.Next / Draw Things** | `GET /sdapi/v1/options` → `sd_model_checkpoint` |
| **Fooocus / InvokeAI / SwarmUI / DiffusionBee / Amuse / mflux** | `/v1/models` or process fingerprint |
| **Video: Wan / MiniMax / HunyuanVideo / LTX-Video / CogVideo** | process fingerprint + `phys_footprint` |
| **Speech: Whisper / Kokoro / Coqui / ChatTTS / Piper / XTTS** | process fingerprint + `phys_footprint` |
| **In-app models (Draw Things, LM Studio desktop)** | process fingerprint + `phys_footprint` |

The list lives in three tables in `src/EngineProbe.swift`: `kindHints` (process
keywords → engine name), `quickHints` (cheap pre-filter for whether a process is worth
deep-scanning) and `knownEngines` (port fallback when a process cannot be identified).
Adding an engine is one line in `kindHints`; the detection logic does not change.
Custom ports go in `engines.json`.

Some engines run as **two processes** — a small parent that serves HTTP and a child
that holds the weights and does all the GPU work (Splash 1.4: a 0.4 GB Python parent
plus a multi-GB `serve-native` child). Memory and the "is it computing" decision are
aggregated over the **whole process tree**, so the row never reports just the parent.

Any OpenAI-compatible server on a port you declare is probed the same way.

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
`~/Library/Application Support/Dockolate/engines.json`:

```json
{
  "extraPorts": [12345],
  "apiKeys": { "12345": "sk-your-key" }
}
```

Keys may also come from the environment: `DOCKOLATE_KEY_<port>`, or a global
`DOCKOLATE_KEY`. Engines that require auth answer 401 without a key — Dockolate
then shows the engine name and port instead of a model name, and never guesses.

## Diagnostics (no GUI, no screen-recording permission)

```bash
./build/Dockolate.app/Contents/MacOS/Dockolate --dump --out=/tmp   # one sample + icon PNG
./build/Dockolate.app/Contents/MacOS/Dockolate --dump --mock=8,16,35,88 --out=/tmp
./build/Dockolate.app/Contents/MacOS/Dockolate --procs             # top-3 process lists
./build/Dockolate.app/Contents/MacOS/Dockolate --engines           # engine probe report
./build/Dockolate.app/Contents/MacOS/Dockolate --engines --ports=9000,9001
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

## Common questions

**How do I watch GPU usage on a Mac without `sudo`?**
Dockolate sums `accumulatedGPUTime` over every `AGXDeviceUserClient` instance
from `ioreg`, instead of calling `powermetrics` — so it never prompts for a
password. Total GPU load is on the Dock icon; the top 3 processes by GPU are in
the window.

**How do I see which local AI models are loaded in RAM right now?**
Open the window. Every identified model server is listed with the memory it
actually holds (`ri_phys_footprint`, the Activity Monitor figure), tagged
`running` / `loaded-idle` / `failed` — plus what Ollama or LM Studio have
downloaded but not loaded.

**Is this a menu bar app or a Dock app?**
Both, independently: the Dock icon is the gauge (default on); the menu bar
readout — compact `C12 G40 M63` — is an optional checkbox. With both off you get
a plain window.

**Does it run on Apple Silicon or Intel?**
The build targets `arm64-apple-macosx13.0`. For Intel, change that one target in
`build.sh` to `x86_64-apple-macosx13.0`; nothing else is architecture-specific.

**Does it need root, admin rights, or screen-recording permission?**
No. Everything comes from public APIs — `host_statistics64`,
`host_processor_info`, `proc_pid_rusage`, `proc_pidinfo`, `ioreg`. No privileged
helper, no entitlement, no permission prompt.

**Does any data leave the machine?**
No. HTTP requests only ever go to `127.0.0.1`; there is no telemetry and no
update check.

**A model server on a custom port is not detected.**
Ports are discovered from the ports the identified processes actually listen on.
If a process cannot be identified, declare the port in
`~/Library/Application Support/Dockolate/engines.json` as `{"extraPorts": [12345]}`.

**How is this different from iStat Menus, Stats, or Activity Monitor?**
Those report into the menu bar or a window. Dockolate's premise is that the Dock
is always on screen, so four water-level cells answer "is this machine under
pressure?" from across the room — and it is the only one of the three that
inventories the local AI models actually resident in RAM.

**Why "Dockolate"?**
It sits in the Dock, and the 2×2 icon looks like a scored bar of chocolate.

## Authors

Built by **Autumemory** together with **Hermes** (agent) and **DeepSeek v4.1 flash** (model).
The design decisions, the code, the measurements and these documents came out of that collaboration.

## License

MIT — see [LICENSE](LICENSE).

中文说明见 [README.zh-CN.md](README.zh-CN.md)。
