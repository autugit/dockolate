# Changelog

All notable changes to Dockolate are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is
[semantic](https://semver.org/).

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
- A LaunchAgent instance plus a user `open` started two copies fighting over the
  Dock icon; the later one now activates the earlier one and exits.
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
