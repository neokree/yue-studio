"""Model-set migration (engine/modelset.py) with fake artifacts: no network, no mlx, no torch. Runs on any OS.

  uv run --no-project --with pytest pytest engine/tests -q
"""
import hashlib
import io
import json
import os
import sys
import time
from pathlib import Path

import pytest

ENGINE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ENGINE))
import backends  # noqa: E402
import modelset  # noqa: E402
from modelset import Manifest, MigrationError, Migrator  # noqa: E402

REV_A, REV_B = "a" * 40, "b" * 40


def sha(b):
    return hashlib.sha256(b).hexdigest()


class FakeHub:
    """Remote files + a local cache with the fetcher API. Fault injection: fail_after (files), corrupt (paths)."""

    def __init__(self, root):
        self.root = Path(root)
        self.remote = {}
        self.fetched = []
        self.fail_after = None
        self.corrupt = set()

    def put(self, repo, rev, path, data):
        self.remote[(repo, rev, path)] = data

    def local_path(self, repo, rev, path):
        return self.root / repo.replace("/", "--") / rev / path

    def blob_name(self, repo, rev, path):
        return None  # plain files: the migrator hashes them

    def partial_bytes(self, repo):
        return 0

    def fetch(self, repo, rev, path):
        if self.fail_after is not None and len(self.fetched) >= self.fail_after:
            raise ConnectionError("network went away")
        data = self.remote[(repo, rev, path)]
        if path in self.corrupt:
            data = b"X" * len(data)
        p = self.local_path(repo, rev, path)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)
        self.fetched.append((repo, rev, path))
        return p

    def discard(self, repo, rev, path):
        self.local_path(repo, rev, path).unlink(missing_ok=True)

    def revisions(self, repo):
        d = self.root / repo.replace("/", "--")
        return sorted(p.name for p in d.iterdir()) if d.exists() else []

    def delete_revision(self, repo, rev):
        d = self.root / repo.replace("/", "--") / rev
        n = sum(p.stat().st_size for p in d.rglob("*") if p.is_file())
        modelset.remove_tree(d)
        return n


class FakeRecipe:
    """Writes out/weights.bin = transformed input; can be told to crash mid-build."""

    def __init__(self, version=1):
        self.version, self.builds, self.crash = version, 0, False

    def __call__(self, inputs, out, on_fraction):
        self.builds += 1
        src = (Path(inputs["base"]) / "model.bin").read_bytes()
        (out / "weights.bin").write_bytes(b"Q" + src[::2])
        on_fraction(0.5)
        if self.crash:
            raise RuntimeError("killed during conversion")
        (out / "config.json").write_text('{"bits": 8}')
        on_fraction(1.0)

    def table(self):
        return {"q8": (self, self.version)}


def manifest(rev=REV_A, model=b"weights-v1" * 10, recipe_version=1, set_name="s1", extra=()):
    files = [{"path": "model.bin", "size": len(model), "sha256": sha(model)},
             {"path": "config.json", "size": 2, "git_sha1": hashlib.sha1(b"blob 2\0{}").hexdigest()}]
    return {"schema": 1, "set": set_name, "artifacts": [
        {"id": "base", "kind": "hf", "label": "Base model", "repo": "org/base", "revision": rev, "files": files},
        {"id": "q8", "kind": "derived", "label": "8-bit", "recipe": "q8", "recipe_version": recipe_version,
         "inputs": ["base"], "when": ["mlx"], "size": 60},
        *extra]}


@pytest.fixture
def env(tmp_path):
    hub = FakeHub(tmp_path / "data" / "hf" / "hub")
    for rev, model in ((REV_A, b"weights-v1" * 10), (REV_B, b"weights-v2" * 12)):
        hub.put("org/base", rev, "model.bin", model)
        hub.put("org/base", rev, "config.json", b"{}")
    data = tmp_path / "data"
    (data / "library" / "song1").mkdir(parents=True)
    (data / "library" / "song1" / "audio.flac").write_bytes(b"user song")
    (data / "venvs" / "yue2").mkdir(parents=True)
    other = hub.root / "models--m-a-p--MERT-v2-FullSong" / "snapshots" / "c"
    other.mkdir(parents=True)
    (other / "w").write_bytes(b"unmanaged model")
    return data, hub


def migrate(data, hub, m, recipe, caps=("mlx",), **kw):
    out = io.StringIO()
    mig = Migrator(data, Manifest.from_dict(m), fetcher=hub, recipes=recipe.table(), caps=caps,
                   reporter=modelset.Reporter(out), free_bytes=kw.pop("free_bytes", lambda p: 10**12), **kw)
    summary = mig.run()
    events = [json.loads(l) for l in out.getvalue().splitlines() if l.startswith("{")]
    return summary, events


def user_files_intact(data, hub):
    assert (data / "library" / "song1" / "audio.flac").read_bytes() == b"user song"
    assert (data / "venvs" / "yue2").is_dir()
    assert (hub.root / "models--m-a-p--MERT-v2-FullSong" / "snapshots" / "c" / "w").exists()


def derived_dirs(data):
    return sorted(p.name for p in (data / "models").iterdir() if "@" in p.name)


# ---------------------------------------------------------------- install, idempotence, adoption

def test_fresh_install_downloads_verifies_builds_and_switches(env):
    data, hub = env
    recipe = FakeRecipe()
    summary, events = migrate(data, hub, manifest(), recipe)
    assert summary["set"] == "s1" and summary["previous"] is None
    assert len(hub.fetched) == 2 and recipe.builds == 1
    state = modelset.installed(data)
    assert state["set"] == "s1" and set(state["artifacts"]) == {"base", "q8"}
    d = modelset.artifact_dir(data, "q8")
    assert d is not None and (d / "weights.bin").read_bytes().startswith(b"Q")
    progress = [e for e in events if e["type"] == "progress"]
    assert all(a["done"] <= b["done"] for a, b in zip(progress, progress[1:]))
    assert progress[-1]["done"] == progress[-1]["total"] == 100 + 2 + 60
    user_files_intact(data, hub)


def test_second_run_is_a_no_op(env):
    data, hub = env
    recipe = FakeRecipe()
    migrate(data, hub, manifest(), recipe)
    before = (data / "models" / "installed.json").read_text()
    hub.fetched.clear()
    summary, _ = migrate(data, hub, manifest(), recipe)
    assert hub.fetched == [] and recipe.builds == 1 and summary["downloaded"] == 0 and summary["freed"] == 0
    assert json.loads(before)["artifacts"] == modelset.installed(data)["artifacts"]


def test_existing_install_adopts_its_files_without_downloading(env):
    """An install from before model sets (files in the HF cache, no installed.json) only builds what is new."""
    data, hub = env
    for path in ("model.bin", "config.json"):
        p = hub.local_path("org/base", REV_A, path)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(hub.remote[("org/base", REV_A, path)])
    recipe = FakeRecipe()
    summary, _ = migrate(data, hub, manifest(), recipe)
    assert hub.fetched == [] and recipe.builds == 1 and summary["downloaded"] == 0  # built, not downloaded


class HfLikeHub(FakeHub):
    """Like huggingface_hub: blobs named by the server's hash (cheap check trusts them), a cached file is returned as is."""

    def blob_name(self, repo, rev, path):
        f = next(f for f in manifest(rev=rev)["artifacts"][0]["files"] if f["path"] == path) if rev == REV_A else {}
        return f.get("sha256") or f.get("git_sha1")

    def fetch(self, repo, rev, path):
        p = self.local_path(repo, rev, path)
        return p if p.exists() else super().fetch(repo, rev, path)


def test_adopted_file_corrupt_at_same_size_is_caught_and_fetched_again(env):
    """Adoption hashes once (the cache's blob name is only what the server said); the bad copy is discarded first,
    or the HF fetch hands back the cached bad file."""
    data, _ = env
    hub = HfLikeHub(data / "hf" / "hub")
    hub.remote = env[1].remote
    for path in ("model.bin", "config.json"):
        p = hub.local_path("org/base", REV_A, path)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(hub.remote[("org/base", REV_A, path)])
    model = hub.local_path("org/base", REV_A, "model.bin")
    model.write_bytes(b"Z" * model.stat().st_size)
    summary, _ = migrate(data, hub, manifest(), FakeRecipe())
    assert hub.fetched == [("org/base", REV_A, "model.bin")] and summary["downloaded"] == 100
    assert model.read_bytes() == hub.remote[("org/base", REV_A, "model.bin")]
    hub.fetched.clear()
    model.write_bytes(b"Z" * model.stat().st_size)  # once recorded, the cheap check is trusted again (--deep hashes)
    migrate(data, hub, manifest(), FakeRecipe())
    assert hub.fetched == []


def test_progress_ticks_while_a_file_downloads(env):
    data, hub = env

    class Slow(FakeHub):
        def fetch(self, repo, rev, path):
            time.sleep(2.5 if path == "model.bin" else 0)
            return super().fetch(repo, rev, path)

        def partial_bytes(self, repo):
            return 40

    slow = Slow(hub.root)
    slow.remote = hub.remote
    _, events = migrate(data, slow, manifest(), FakeRecipe())
    progress = [e["done"] for e in events if e["type"] == "progress"]
    assert progress.count(40) >= 2  # the 1 s ticker reported the partial file before it finished


def test_staging_left_by_a_dead_build_does_not_count_against_free_space(env):
    data, hub = env
    staging = data / "models" / ".staging" / "q8@dead"
    staging.mkdir(parents=True)
    (staging / "weights.bin").write_bytes(b"x" * 10)
    summary, _ = migrate(data, hub, manifest(), FakeRecipe(),
                         free_bytes=lambda p: 0 if (data / "models" / ".staging").exists() else 10**12)
    assert summary["set"] == "s1"


def test_without_the_capability_the_derived_artifact_is_skipped(env):
    data, hub = env
    recipe = FakeRecipe()
    migrate(data, hub, manifest(), recipe, caps=())
    assert recipe.builds == 0 and set(modelset.installed(data)["artifacts"]) == {"base"}
    assert modelset.artifact_dir(data, "q8") is None


# ---------------------------------------------------------------- upgrade: new first, delete after

def test_upgrade_downloads_new_switches_then_deletes_old(env):
    data, hub = env
    migrate(data, hub, manifest(), FakeRecipe())
    old_dir = modelset.artifact_dir(data, "q8")
    summary, _ = migrate(data, hub, manifest(rev=REV_B, model=b"weights-v2" * 12, recipe_version=2, set_name="s2"),
                         FakeRecipe(version=2))
    assert summary["previous"] == "s1" and summary["set"] == "s2"
    assert hub.revisions("org/base") == [REV_B]
    new_dir = modelset.artifact_dir(data, "q8")
    assert new_dir != old_dir and not old_dir.exists() and derived_dirs(data) == [new_dir.name]
    assert summary["freed"] > 0
    user_files_intact(data, hub)


def test_losing_the_capability_deletes_the_derived_artifact(env):
    data, hub = env
    migrate(data, hub, manifest(), FakeRecipe())
    assert derived_dirs(data)
    migrate(data, hub, manifest(set_name="s1-torch"), FakeRecipe(), caps=())
    assert derived_dirs(data) == []


def test_retired_repo_is_deleted_after_the_switch(env):
    data, hub = env
    hub.put("org/old", REV_A, "x.bin", b"old")
    hub.fetch("org/old", REV_A, "x.bin")
    m = manifest()
    m["retire"] = [{"kind": "hf", "repo": "org/old"}]
    migrate(data, hub, m, FakeRecipe())
    assert hub.revisions("org/old") == []
    user_files_intact(data, hub)


# ---------------------------------------------------------------- interruption and failures never lose the working set

def test_interrupted_download_keeps_old_set_and_resumes(env):
    data, hub = env
    migrate(data, hub, manifest(), FakeRecipe())
    old_state = modelset.installed(data)
    hub.fetched.clear()
    hub.fail_after = 1  # second file of the new revision fails
    with pytest.raises(ConnectionError):
        migrate(data, hub, manifest(rev=REV_B, model=b"weights-v2" * 12, set_name="s2"), FakeRecipe())
    assert modelset.installed(data) == old_state
    assert REV_A in hub.revisions("org/base")
    assert modelset.artifact_dir(data, "q8") is not None
    hub.fail_after = None
    hub.fetched.clear()
    migrate(data, hub, manifest(rev=REV_B, model=b"weights-v2" * 12, set_name="s2"), FakeRecipe())
    assert hub.fetched == [("org/base", REV_B, "config.json")]  # model.bin from the first attempt is reused
    assert hub.revisions("org/base") == [REV_B] and modelset.installed(data)["set"] == "s2"


def test_crash_during_build_keeps_old_set_then_recovers(env):
    data, hub = env
    migrate(data, hub, manifest(), FakeRecipe())
    old_dir = modelset.artifact_dir(data, "q8")
    crashing = FakeRecipe(version=2)
    crashing.crash = True
    with pytest.raises(RuntimeError):
        migrate(data, hub, manifest(recipe_version=2, set_name="s2"), crashing)
    assert modelset.installed(data)["set"] == "s1" and modelset.artifact_dir(data, "q8") == old_dir
    assert (data / "models" / ".staging").exists()  # left behind by the crash
    summary, _ = migrate(data, hub, manifest(recipe_version=2, set_name="s2"), FakeRecipe(version=2))
    assert summary["set"] == "s2" and not (data / "models" / ".staging").exists()
    assert not old_dir.exists() and derived_dirs(data) == [modelset.artifact_dir(data, "q8").name]


def test_corrupt_download_fails_verification_and_deletes_nothing(env):
    data, hub = env
    migrate(data, hub, manifest(), FakeRecipe())
    hub.corrupt = {"model.bin"}
    with pytest.raises(MigrationError, match="failed verification"):
        migrate(data, hub, manifest(rev=REV_B, model=b"weights-v2" * 12, set_name="s2"), FakeRecipe())
    assert modelset.installed(data)["set"] == "s1" and REV_A in hub.revisions("org/base")
    assert not hub.local_path("org/base", REV_B, "model.bin").exists()  # discarded, so a retry downloads it again
    hub.corrupt = set()
    migrate(data, hub, manifest(rev=REV_B, model=b"weights-v2" * 12, set_name="s2"), FakeRecipe())
    assert modelset.installed(data)["set"] == "s2"


def test_damaged_derived_artifact_is_rebuilt(env):
    data, hub = env
    recipe = FakeRecipe()
    migrate(data, hub, manifest(), recipe)
    (modelset.artifact_dir(data, "q8") / "weights.bin").write_bytes(b"short")
    migrate(data, hub, manifest(), recipe)
    assert recipe.builds == 2 and (modelset.artifact_dir(data, "q8") / "weights.bin").read_bytes().startswith(b"Q")


def test_not_enough_disk_fails_before_downloading(env):
    data, hub = env
    with pytest.raises(MigrationError, match="free disk space"):
        migrate(data, hub, manifest(), FakeRecipe(), free_bytes=lambda p: 1000)
    assert hub.fetched == [] and modelset.installed(data) is None


def test_unknown_recipe_version_fails_cleanly(env):
    data, hub = env
    with pytest.raises(MigrationError, match="no recipe"):
        migrate(data, hub, manifest(recipe_version=9), FakeRecipe())
    assert modelset.installed(data) is None


def test_a_second_concurrent_migration_is_refused(env):
    data, hub = env
    pytest.importorskip("fcntl")
    import fcntl
    (data / "models").mkdir(parents=True, exist_ok=True)
    with open(data / "models" / ".lock", "w") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        with pytest.raises(MigrationError, match="Another model update"):
            migrate(data, hub, manifest(), FakeRecipe())


def test_state_write_is_atomic(tmp_path, monkeypatch):
    """A crash while writing installed.json leaves the previous file intact (temp file + rename)."""
    path = tmp_path / "models" / "installed.json"
    modelset.write_json_atomic(path, {"set": "old"})
    real_replace = os.replace
    monkeypatch.setattr(modelset.os, "replace", lambda *a: (_ for _ in ()).throw(OSError("power cut")))
    with pytest.raises(OSError):
        modelset.write_json_atomic(path, {"set": "new"})
    monkeypatch.setattr(modelset.os, "replace", real_replace)
    assert json.loads(path.read_text())["set"] == "old"


# ---------------------------------------------------------------- manifest validation and the real manifest

def test_manifest_rejects_unpinned_revisions_and_bad_inputs():
    m = manifest()
    m["artifacts"][0]["revision"] = "main"
    with pytest.raises(MigrationError, match="pinned"):
        Manifest.from_dict(m)
    m = manifest()
    m["artifacts"][1]["inputs"] = ["missing"]
    with pytest.raises(MigrationError, match="input"):
        Manifest.from_dict(m)
    with pytest.raises(MigrationError, match="schema"):
        Manifest.from_dict({**manifest(), "schema": 99})


def test_fingerprint_changes_with_spec_and_inputs_not_with_labels():
    a = Manifest.from_dict(manifest()).artifacts[1]
    b = Manifest.from_dict(manifest(recipe_version=2)).artifacts[1]
    relabeled = Manifest.from_dict(manifest()).artifacts[1]
    relabeled.raw["label"] = "renamed"
    assert modelset.fingerprint(a, {"base": "x"}) == modelset.fingerprint(relabeled, {"base": "x"})
    assert modelset.fingerprint(a, {"base": "x"}) != modelset.fingerprint(b, {"base": "x"})
    assert modelset.fingerprint(a, {"base": "x"}) != modelset.fingerprint(a, {"base": "y"})


def test_shipped_models_manifest_is_valid_and_pinned():
    m = Manifest.read(ENGINE / "manifests" / "models.json")
    by_id = {a.id: a for a in m.artifacts}
    assert set(by_id) == {"yue2-3b", "yue2-vae", "yue2-3b-ar-mlx-q8"}
    for a in (by_id["yue2-3b"], by_id["yue2-vae"]):
        weights = [f for f in a.files if f["path"] == "model.safetensors"]
        assert weights and len(weights[0]["sha256"]) == 64 and weights[0]["size"] > 10**8
    q8 = by_id["yue2-3b-ar-mlx-q8"]
    assert q8.inputs == ["yue2-3b"] and q8.when == ["mlx"] and q8.raw["recipe"] in modelset.RECIPES
    assert modelset.RECIPES[q8.raw["recipe"]][1] == q8.raw["recipe_version"]
    real = json.loads((ENGINE / "manifests" / "real.json").read_text())
    ids = [s["id"] for s in real["steps"]]
    step = next(s for s in real["steps"] if s["kind"] == "models")
    assert step["id"].endswith(m.set) and ids.index(step["id"]) > ids.index(next(i for i in ids if i.startswith("venv-yue2")))
    assert step["bytes"] == sum(a.size for a in m.artifacts)
    assert real["bytes"] == sum(s.get("bytes", 0) for s in real["steps"])


def test_cli_reports_errors_as_one_json_line(tmp_path, capsys):
    bad = tmp_path / "m.json"
    bad.write_text('{"schema": 7}')
    assert modelset.main(["migrate", "--data-dir", str(tmp_path), "--manifest", str(bad)]) == 1
    lines = [json.loads(l) for l in capsys.readouterr().out.splitlines() if l.startswith("{")]
    assert lines == [{"type": "error", "message": "unsupported model manifest schema 7"}]


# ---------------------------------------------------------------- what the engine reads

def test_backend_reads_pins_and_artifact_from_the_switched_state(env):
    data, hub = env
    m = manifest()
    m["artifacts"][1]["id"] = backends.AR_ARTIFACT_ID
    migrate(data, hub, m, FakeRecipe())
    assert backends.pinned_revisions(data) == {"org/base": REV_A}
    b = backends.Yue2Backend.__new__(backends.Yue2Backend)
    b.data = data
    assert b.ar_artifact() == modelset.artifact_dir(data, backends.AR_ARTIFACT_ID)
    (b.ar_artifact() / modelset.MARKER).write_text("{}")  # marker no longer matches: fall back to load-time
    assert b.ar_artifact() is None


def test_backend_pins_before_any_migration_come_from_the_shipped_manifests(tmp_path):
    pins = backends.pinned_revisions(tmp_path)
    assert pins["m-a-p/YuE2-3B"] == "8f24312f187763b9854adeec87e437e2b03bbff1"
    assert pins["m-a-p/YuE2-Vae"] == "152733a19ad43aa67e367f9b5503ef8075bb5126"
