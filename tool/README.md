# tool/

- `docker/Dockerfile` (in `../docker`): Ubuntu 24.04 arm64 + Flutter 3.44.3 (git clone, Linux desktop precached) + GTK/Xvfb/GStreamer + pinned uv. Build once:
  `docker build -t yue2-studio-test:3.44.3 docker`. Never per run.
- `tool/test.sh [--only unit|py|e2e]`: runs `fvm flutter test` (60 s), pytest via `uv run --no-project` (20 s), then the e2e in Docker (3 min).
  Prints wall time per layer and fails if a budget is exceeded. The very first e2e run (empty named volumes `yue2-pub-cache`, `yue2-studio-build`) gets a 10 min budget because it compiles the Linux app; reruns are incremental.
- Source is mounted read-only at `/src` and rsynced into `/work`. Screenshots land in `build/e2e-shots/`, the e2e log in `build/e2e.log`.
- `integration_test/app_e2e_test.dart` needs a `linux/` runner in the app, `integration_test` in dev_dependencies, and package name `yue2_studio`.
- Reset the caches: `docker volume rm yue2-pub-cache yue2-studio-build`.
