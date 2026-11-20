# tool/

- `docker/Dockerfile` (in `../docker`): Ubuntu 24.04 arm64 + Flutter 3.44.3 (git clone, Linux desktop precached) + GTK/Xvfb/GStreamer + pinned uv. Build once:
  `docker build -t yue2-studio-test:3.44.3 docker`. Never per run.
- `tool/test.sh [--only unit|py|e2e]`: runs `fvm flutter test` (60 s), pytest via `uv run --no-project` (20 s), then the e2e in Docker (180 s budget).
  Prints wall time per layer and fails if a budget is exceeded. Measured: e2e 47-56 s warm (test body ~32 s), ~57 s with an empty build volume.
- The named volume `yue2-studio-build` is the whole `/work` copy: the source is mounted read-only at `/src` and `rsync -a --checksum --delete` syncs it, so unchanged files keep their mtime and `.dart_tool`, `build/` and `linux/flutter/ephemeral` survive (incremental Linux build). Cold run: `docker volume rm yue2-studio-build`.
- Python 3.12 is baked into the image (`/opt/seed/uv-python`) and symlinked into the fresh data dir, so setup does not download it; `tool/e2e-uv.sh` (YUE2_STUDIO_UV in the e2e) sleeps 2.5 s in the venv step so the "installing" screenshot is a real in-progress state. Fake engine steps are `YUE2_FAKE_STEP_SECONDS=0.5`.
- `integration_test/app_e2e_test.dart` needs a `linux/` runner in the app, `integration_test` in dev_dependencies, and package name `yue2_studio`.
- Reset the caches: `docker volume rm yue2-pub-cache yue2-studio-build`. Changing docker/Dockerfile needs a one-off `docker build -t yue2-studio-test:3.44.3 docker`.
