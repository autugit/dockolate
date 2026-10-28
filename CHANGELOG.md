# Changelog

All notable changes to Dockolate are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is
[semantic](https://semver.org/).

## [Unreleased]

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
  Flash-Next, Swift-Qwen, mlx_lm/mlx_vlm servers), image/video (ComfyUI, SwarmUI,
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

### Fixed — engine rows for two-layer engines (Splash 1.4)

- **A model whose weights live in a child process was reported as an idle shell.**
  Each engine row took its memory and activity from whichever process *listens* on
  the port. Splash 1.4 serves HTTP from a small Python parent (≈0.4 GB) and runs the
  model in an `engine/splash serve-native` child (27–40 GB, all the GPU work), so the
  row read **「挂载待机 / 0.41 GB」** while the machine sat at 60–85 % GPU decoding —
  and `splash` was not in the process-name hints at all, so the child was never
  scanned to begin with.
- Fix: `splash` added to the process hints; every engine row now aggregates memory
  and CPU/GPU activity across the holder's **process tree** (`ppid` read via
  `PROC_PIDTBSDINFO`), and descendants of a claimed holder are skipped instead of
  being listed a second time.
- Verified live (2026-10-23, Apple Silicon): row went from `挂载待机 0.41 GB` to
  `正在运行 35.51 GB` with `splash` showing 85 % GPU. Cross-check: the app's own
  top-memory list read 35.12 GB for the child, and 0.41 + 35.12 = 35.53 matches the
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
