# Engine protocol (single source of truth)

Dart (`lib/engine/`) and Python (`engine/`) both follow this file. Change it here first.

## 1. Process and transport

- Launch: `<venv yue2>/bin/python <engine>/sidecar.py --data-dir <data dir> [--fake]`.
  Env set by the app: `PYTORCH_ENABLE_MPS_FALLBACK=1`, `HF_HOME=<data>/hf`, `UV_CACHE_DIR=<data>/uv-cache`,
  `UV_PYTHON_INSTALL_DIR=<data>/uv-python`, `HF_TOKEN` removed, `PYTHONUNBUFFERED=1`.
- stdin: requests. stdout: events. One JSON object per line, UTF-8, `\n` terminated. stderr: free-form logs (the app keeps the last 200 lines for error reports, never parses them).
- Unknown fields are ignored by both sides. Every message has a `type`.
- The sidecar runs **one job at a time**. The queue lives in Dart: it sends the next request only after the previous job's `result` or `error`. A request that arrives while busy gets `error {message: "busy"}`.
- Fake mode (`--fake`): Python standard library only. Same events, short timer (each stage ~0.3 s; env `YUE2_FAKE_STEP_SECONDS` overrides), writes a tiny valid `audio.wav` (1-2 s, 48 kHz stereo, sine), `score.abc`, `result.json`.

## 2. Requests (app -> sidecar)

| type | fields |
|---|---|
| `generate` | `job` (string id chosen by app), `out` (absolute dir, created by sidecar), `style`, `lyrics`, `cot` (`full` \| `melody` \| `off`), `seed` (int), `abc` (optional string: a cover score) |
| `transcribe` | `job`, `audio` (absolute path: wav/flac/mp3/ogg), `out` (absolute dir), `mode` (`full` = Close, melody + chords \| `melody` = Free, melody only) |
| `stems` | `job`, `audio` (absolute path), `out` (absolute dir: the song's `stems/` folder) |
| `cancel` | `job` |
| `shutdown` | (none) sidecar exits 0 after the current step |

## 3. Events (sidecar -> app)

| type | fields |
|---|---|
| `ready` | `version` (1), `fake` (bool). Sent once, after start; the model is NOT loaded yet (loads lazily on first generate, reported as stage `load`). |
| `progress` | `job`, `stage`, `done` (int), `total` (int or null), `audio` (additive, optional: song length in seconds read from the finished score, bars x meter / tempo, within ~4% of the real length; only on the first `semantic` event of a song whose score the engine wrote; the `GenerationEstimator` uses it instead of its guess from the lyrics) |
| `result` | `job`, `dir` (absolute), `audio` (file name inside dir, generate only: `audio.flac` real, `audio.wav` fake), `seed` (int, generate only), `duration` (seconds, float, generate only), `engine` (real generate only, additive: `{"ar": "mlx-q8"\|"mlx-bf16"\|"torch", "nar": "mlx-bf16"\|"torch", "ar_weights": "artifact"\|"load-time"\|null}`, see "Engines"), `timings` (generate only, additive: `{"load","abc","semantic","nar","vae"}` wall seconds per stage, floats; 0 for a stage that did not run, e.g. `load` when the model was already loaded, `abc` when `cot=off` or `abc` was given; for the `GenerationEstimator`) |
| `error` | `job` (null if not tied to a job), `message`, `cancelled` (bool, true when the job ended because of `cancel`) |

Stages, in order:
- generate: `load` (total null, only when the pipeline is not loaded yet), `abc` (token count, total null; skipped when `cot=off` or `abc` given), `semantic` (token count, total null), `nar` (done/total), `vae` (done/total).
- transcribe: `transcribe` (total null; one event when it starts, one per ~2 s heartbeat with elapsed seconds in `done`).
- stems: `stems` (same heartbeat as transcribe). Result `dir` = `out`, holding `drums`, `bass`, `other`, `vocals`, `guitar`, `piano` (`.flac` real, at the input's sample rate; `.wav` fake). Real mode runs `stems.py` (Demucs htdemucs_6s, MPS) as a child process in the yue2 venv; it writes `<out>.partial` and renames it, so `out` exists only when complete. On < 32 GB Macs the YuE2 pipeline is unloaded first, as for transcribe. Measured: 145 s song in 13 s, peak 4.4 GB, M4 Pro.
- Token-count stages emit at most one event per 25 tokens.

Fake mode emits `timings` too: measured wall time of its own (short) stages.

Measured real durations for a 70 s song on an M4 Pro (to animate progress when total is null): load ~20 s first time, abc 17 s, semantic 55 s, nar 80 s, vae 4 s. Transcribe ~63 s.

### Memory (additive)

On Macs with less than 32 GB of memory (sysctl `hw.memsize`; env `YUE2_STUDIO_MEM_GB` overrides it, for tests), the sidecar unloads the YuE2 pipeline before running a `transcribe` job (drop the reference, `gc.collect()`, `torch.mps.empty_cache()` when available). The next `generate` loads it again lazily, so it emits the `load` stage (and a non-zero `timings.load`) as on first use. With 32 GB or more nothing is unloaded. Measured: SheetSage2 alone peaks at ~15 GB and the resident YuE2 pipeline takes ~9.7 GB, so 24 to 32 GB Macs would swap. The protocol is otherwise unchanged; the app does not need to do anything.

### Offline guarantee (real mode)

After setup the sidecar never touches the network. `Yue2Backend` sets `HF_HUB_OFFLINE=1` itself (the app does not need to), loads `m-a-p/YuE2-3B` and `m-a-p/YuE2-Vae` with `local_files_only=True` at the exact revisions pinned in the manifest (`YUE2_STUDIO_MANIFEST`, else `<engine>/manifests/real.json`), and `sheetsage_wrap.py` does the same for SheetSage2 and for MERT (the revision pinned in SheetSage2's config). A missing model therefore fails with an `error` ("Run setup again"), it never downloads. The `fetch.py` setup steps are the only network users, and they must run WITHOUT `HF_HUB_OFFLINE`.

### Engines (real mode)

`Yue2Backend` picks the engine once per sidecar process (`backends.select_engine`, logged on stderr):

- Token loop (abc + semantic): **MLX with 8-bit weights** (`mlx_ar.py`) or the upstream PyTorch loop.
- Acoustic velocity (nar): **MLX in bf16** (`mlx_nar.py`, never quantized) or upstream PyTorch. The acoustic prefill, the VAE and every other step stay upstream PyTorch.
- `auto` (default) = MLX on Apple Silicon with >= 24 GB memory and `mlx` installed; else PyTorch. Switch: env `YUE2_STUDIO_ENGINE` = `auto` | `mlx` | `torch` (or `{"engine": ...}` in `<data>/engine.json`; env wins). `YUE2_STUDIO_NAR_ENGINE` / `"nar_engine"` override the acoustic stage alone. An explicit `mlx` where MLX cannot run, or an MLX load failure, falls back to PyTorch instead of failing.
- Quality defaults are unchanged in both engines (32 ODE steps, same sampling, same seeds: sampling stays upstream PyTorch on CPU).

### Engine code layout

`sidecar.py` only does the protocol (parsing, one-job-at-a-time, cancel, events). The engine is a `Backend` in `backends.py` (`load`, `generate(request, on_progress, cancelled) -> result fields`, `transcribe(...)`): `FakeBackend` and `Yue2Backend`. Swap or add a class there to change engine; the protocol does not change.

## 4. Output folder

`generate` writes into `out`: the audio file, `score.abc`, `result.json` (engine output, untouched). `transcribe` writes `score.abc` into `out`. The app owns `meta.json` in the same library folder; the sidecar never touches it.

## 5. Setup manifest

A manifest is JSON: `{"name", "bytes" (total download estimate, for the free-disk check), "steps": [...]}`. Steps run in order; each has `id`, `kind`, `label` (shown in UI). A step is done when `<data>/setup-state.json` lists its id; finished steps are skipped on resume.

| kind | fields | how the app runs it |
|---|---|---|
| `python` | `version` | `uv python install <version>` |
| `venv` | `name`, `python`, `packages` (list, may be empty), `requirements` (optional path relative to data dir), `no_deps` (optional list) | `uv venv <data>/venvs/<name> --python <python>` then `uv pip install --python <venv> ...`, then `uv pip install --no-deps --python <venv> <no_deps>` (packages whose declared dependencies would replace pinned ones: demucs pulls a torchaudio for another torch; torchaudio is only imported, never used for I/O). |
| `hf` | `repo`, `revision`, `bytes`, `local_dir` (optional, relative to data dir; else HF cache in `<data>/hf`), `venv` (venv whose python runs the fetcher) | `<venv>/bin/python <engine>/fetch.py --repo .. --revision .. [--local-dir ..]` which prints JSON lines `{"type":"progress","done":bytes,"total":bytes}` then `{"type":"done"}` or `{"type":"error","message"}`. Resumable (huggingface_hub keeps partial files). |
| `url` | `url`, `sha256`, `bytes`, `dest` (relative to data dir), `venv` | `<venv>/bin/python <engine>/fetch.py --url .. --sha256 .. --size <bytes> --dest <data>/<dest>`: same JSON lines as `hf`; resumes `<dest>.part` with an HTTP Range request, renames only after the hash matches; a good file already at `dest` is kept. Used for the Demucs checkpoint (`models/demucs/hub/checkpoints/`, read through `TORCH_HOME`, so the engine never downloads). |
| `models` | `manifest` (file in `engine/manifests/`), `venv`, `bytes` | `<venv>/bin/python <engine>/modelset.py migrate --data-dir <data> --manifest <engine>/manifests/<manifest>`: same JSON lines as `hf` (`done` carries `set`). |

Manifests live in `engine/manifests/`: `fake.json` (python + venv, no packages, no models), `real.json` and `models.json`.

### Model set (`models.json`, `modelset.py`)

`models.json` declares the models the engine needs: `{"schema": 1, "set": <version>, "artifacts": [...], "retire": [repos]}`. Each artifact has an `id` and either:

- `kind: "hf"`: `repo`, a 40-character `revision`, `files` (`path`, `size`, `sha256` for LFS files or `git_sha1` for small files). Files live in the HF cache `<data>/hf/hub`.
- `kind: "derived"`: `recipe` (with its version), `inputs` (artifact ids) and `when` (capabilities: `mlx` = this machine selects the MLX engine). Built into `<data>/models/<id>@<fingerprint>/` with a `.artifact.json` marker. The fingerprint covers the recipe, its version and the inputs, so a new recipe or new inputs gives a new directory.

`modelset.py migrate` (also `status [--deep]`): lock `<data>/models/.lock` -> plan against `<data>/models/installed.json` -> free-disk check -> download missing files (resumable) and verify each new file's hash (a corrupt file is discarded) -> build derived artifacts in `models/.staging`, then rename -> write `installed.json` atomically -> only then delete what nothing references: old derived directories, staging leftovers, and revisions of repos the set manages or retires. A cleanup error never fails the migration. It never touches `library/` or anything outside `models/` and the managed repos. Running it again is a no-op. To change models later, edit `models.json` (new `set`, new revisions or artifacts) and give the setup step a new id (`models-<set>`): existing installs then migrate on the next launch.

The engine reads the pinned revisions and the derived directories from `installed.json` (`backends.pinned_revisions`, `modelset.artifact_dir`).

## 6. App paths (Dart)

| what | default | override env (tests) |
|---|---|---|
| data dir | `~/Library/Application Support/YuE2 Studio` | `YUE2_STUDIO_DATA_DIR` |
| uv binary | bundled asset copied to `<data>/bin/uv` (chmod +x) | `YUE2_STUDIO_UV` |
| engine scripts | bundled assets copied to `<data>/engine/` | `YUE2_STUDIO_ENGINE_DIR` |
| manifest | `<engine>/manifests/real.json` | `YUE2_STUDIO_MANIFEST` |
| fake sidecar | off | `YUE2_STUDIO_FAKE=1` adds `--fake` |

Library: `<data>/library/<id>/` with engine artifacts + `meta.json` `{id, title, liked, createdAt (ISO-8601), status (queued|generating|done|failed), kind (song|cover), request {style, lyrics, cot, seed, abc?}, audio (file name or null), duration (s or null), error (string or null)}`. List = directory scan, newest first by createdAt.
