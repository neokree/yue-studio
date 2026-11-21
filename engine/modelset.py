#!/usr/bin/env python3
"""Model sets: a declarative manifest of model artifacts and the migration that installs it.

  modelset.py migrate --data-dir <dir> [--manifest <models.json>] [--deep]
  modelset.py status  --data-dir <dir> [--manifest <models.json>]

A model set (engine/manifests/models.json) names a version ("set") and its artifacts. Each artifact has an id and a kind:
  hf       files of a Hugging Face repo at a pinned revision, each with size and sha256 (LFS) or git_sha1 (small files);
           stored in the HF cache <data>/hf/hub, where the pipeline loads them with local_files_only.
  derived  built on this machine by a named, versioned recipe from other artifacts (e.g. the 8-bit MLX token weights
           from the official YuE2-3B checkpoint); stored in <data>/models/<id>@<fingerprint12>/.
  "when": ["mlx"] limits an artifact to machines with that capability (here: the MLX engine is selected).

migrate compares what is installed (<data>/models/installed.json) with what the manifest requires and then, in order:
  1. reuses every artifact already present and valid (an existing install adopts its HF files without downloading);
  2. downloads missing files (resumable: partial files continue) and builds missing derived artifacts in a staging dir;
  3. verifies everything (size + hash for new files; derived: recipe check + sha256 recorded in a marker);
  4. switches atomically: installed.json is replaced in one rename, only after the whole new set verified;
  5. only then deletes artifacts no longer referenced: unpinned revisions of managed HF repos, derived dirs of other
     fingerprints, stale staging. Nothing outside <data>/models and <data>/hf/hub/models--<managed repo> is touched,
     so the library (user songs), venvs and the other models are never deleted.
Interrupted at any point, a re-run continues (idempotent): nothing switches or gets deleted before step 4.

Output: JSON lines on stdout, the fetch.py protocol (PROTOCOL.md section 5): {"type":"progress","done","total"} in
bytes, then {"type":"done", ...} or {"type":"error","message"}; plain lines are status text for the setup screen.
Standard library only, except the real HF fetcher (huggingface_hub) and the recipes (mlx), imported lazily.
"""
from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
import shutil
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

SCHEMA = 1
ENGINE_DIR = Path(__file__).resolve().parent
DEFAULT_MANIFEST = ENGINE_DIR / "manifests" / "models.json"
STATE_NAME = "installed.json"
MARKER = ".artifact.json"


class MigrationError(Exception):
    pass


# ---------------------------------------------------------------- manifest

@dataclass
class Artifact:
    raw: dict

    id: str = field(init=False)
    kind: str = field(init=False)

    def __post_init__(self):
        self.id, self.kind = self.raw["id"], self.raw["kind"]
        if self.kind not in ("hf", "derived"):
            raise MigrationError(f"artifact {self.id}: unknown kind {self.kind!r}")
        if self.kind == "hf" and not (self.raw.get("repo") and self.raw.get("revision") and self.raw.get("files")):
            raise MigrationError(f"artifact {self.id}: hf needs repo, revision and files")
        if self.kind == "hf" and len(self.raw["revision"]) != 40:
            raise MigrationError(f"artifact {self.id}: revision must be a pinned 40-char commit sha")
        if self.kind == "derived" and not (self.raw.get("recipe") and "recipe_version" in self.raw):
            raise MigrationError(f"artifact {self.id}: derived needs recipe and recipe_version")

    @property
    def label(self):
        return self.raw.get("label", self.id)

    @property
    def when(self):
        return list(self.raw.get("when", []))

    @property
    def files(self):
        return list(self.raw.get("files", []))

    @property
    def inputs(self):
        return list(self.raw.get("inputs", []))

    @property
    def size(self):
        if self.kind == "hf":
            return sum(int(f["size"]) for f in self.files)
        return int(self.raw.get("size", 0))


@dataclass
class Manifest:
    set: str
    artifacts: list
    retire: list

    @classmethod
    def from_dict(cls, d):
        if d.get("schema") != SCHEMA:
            raise MigrationError(f"unsupported model manifest schema {d.get('schema')!r}")
        arts = [Artifact(a) for a in d.get("artifacts", [])]
        ids = [a.id for a in arts]
        if len(ids) != len(set(ids)):
            raise MigrationError("duplicate artifact id in manifest")
        for a in arts:
            for i in a.inputs:
                if i not in ids or ids.index(i) > ids.index(a.id):
                    raise MigrationError(f"artifact {a.id}: input {i} must be listed before it")
        return cls(d["set"], arts, list(d.get("retire", [])))

    @classmethod
    def read(cls, path):
        return cls.from_dict(json.loads(Path(path).read_text(encoding="utf-8")))

    def required(self, caps):
        """Artifacts this machine needs (all of an artifact's "when" capabilities present), inputs included."""
        by_id = {a.id: a for a in self.artifacts}
        wanted = {a.id for a in self.artifacts if all(c in caps for c in a.when)}
        for a in reversed(self.artifacts):
            if a.id in wanted:
                wanted.update(a.inputs)
        return [by_id[i] for i in [a.id for a in self.artifacts] if i in wanted]


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def fingerprint(artifact, input_fingerprints):
    """Identity of an artifact's content: its spec (minus display fields) plus its inputs' identities."""
    spec = {k: v for k, v in artifact.raw.items() if k not in ("label", "size", "when")}
    return hashlib.sha256(canonical({"spec": spec, "inputs": input_fingerprints}).encode()).hexdigest()


# ---------------------------------------------------------------- files

def sha256_file(path, on_bytes=None):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(8 << 20):
            h.update(chunk)
            if on_bytes:
                on_bytes(len(chunk))
    return h.hexdigest()


def git_sha1_file(path):
    h = hashlib.sha1()
    h.update(b"blob %d\0" % os.path.getsize(path))
    with open(path, "rb") as f:
        while chunk := f.read(8 << 20):
            h.update(chunk)
    return h.hexdigest()


def write_json_atomic(path, value):
    """Write to a temp file in the same dir, fsync, rename over: readers see the old or the new file, never half."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(value, f, indent=2, sort_keys=True)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)
    with contextlib.suppress(OSError):  # make the rename itself durable
        fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)


def remove_tree(path):
    path = Path(path)
    if path.is_symlink() or path.is_file():
        path.unlink(missing_ok=True)
    elif path.exists():
        shutil.rmtree(path)


def tree_bytes(path):
    path = Path(path)
    if path.is_file():
        return path.stat().st_size
    return sum(p.stat().st_size for p in path.rglob("*") if p.is_file() and not p.is_symlink())


# ---------------------------------------------------------------- HF fetcher (real); tests pass a fake with the same API

class HfFetcher:
    """Files of pinned HF revisions in an HF cache dir (the layout huggingface_hub and the pipeline use)."""

    def __init__(self, cache_dir):
        self.cache = Path(cache_dir)

    def _repo_dir(self, repo):
        return self.cache / ("models--" + repo.replace("/", "--"))

    def local_path(self, repo, revision, path):
        return self._repo_dir(repo) / "snapshots" / revision / path

    def blob_name(self, repo, revision, path):
        """Name of the blob a snapshot file points to: its sha256 (LFS) or git sha1, as the server reported it."""
        p = self.local_path(repo, revision, path)
        return Path(os.path.realpath(p)).name if p.is_symlink() else None

    def partial_bytes(self, repo):
        blobs = self._repo_dir(repo) / "blobs"
        return sum(p.stat().st_size for p in blobs.glob("*.incomplete")) if blobs.exists() else 0

    def fetch(self, repo, revision, path):
        os.environ.setdefault("HF_HUB_DISABLE_XET", "1")  # plain HTTP grows <blob>.incomplete: resumable + measurable
        from huggingface_hub import hf_hub_download
        return Path(hf_hub_download(repo, path, revision=revision, cache_dir=str(self.cache)))

    def discard(self, repo, revision, path):
        """Remove a bad file (snapshot link and its blob) so the next fetch downloads it again."""
        p = self.local_path(repo, revision, path)
        target = Path(os.path.realpath(p)) if p.is_symlink() else None
        p.unlink(missing_ok=True)
        if target is not None:
            target.unlink(missing_ok=True)

    def revisions(self, repo):
        snaps = self._repo_dir(repo) / "snapshots"
        return sorted(p.name for p in snaps.iterdir() if p.is_dir()) if snaps.exists() else []

    def delete_revision(self, repo, revision):
        """Delete one cached revision; blobs still used by another revision stay. Returns bytes freed."""
        from huggingface_hub import scan_cache_dir
        info = scan_cache_dir(self.cache)
        for r in info.repos:
            if r.repo_id == repo and r.repo_type == "model":
                if any(rev.commit_hash == revision for rev in r.revisions):
                    strategy = info.delete_revisions(revision)
                    strategy.execute()
                    return strategy.expected_freed_size
        remove_tree(self._repo_dir(repo) / "snapshots" / revision)  # not in the scan (half-written): drop the dir
        return 0


# ---------------------------------------------------------------- recipes

def _recipe_yue2_ar_mlx_q8(inputs, out, on_fraction):
    sys.path.insert(0, str(ENGINE_DIR))
    import mlx_convert
    src = inputs["yue2-3b"]
    mlx_convert.convert(src, out, on_progress=on_fraction)
    mlx_convert.check(out)


RECIPES = {"yue2-ar-mlx-q8": (_recipe_yue2_ar_mlx_q8, 1)}


# ---------------------------------------------------------------- migration

class Reporter:
    """Byte progress as JSON lines (thread-safe), plus plain status lines."""

    def __init__(self, out=None):
        self.out = out or sys.stdout
        self.lock = threading.Lock()
        self.total = self.done = 0
        self.live = lambda: 0  # bytes in flight (partial downloads), added to done

    def event(self, **ev):
        with self.lock:
            self.out.write(json.dumps(ev) + "\n")
            self.out.flush()

    def status(self, text):
        with self.lock:
            self.out.write(text + "\n")
            self.out.flush()

    def progress(self):
        self.event(type="progress", done=min(self.done + self.live(), self.total), total=self.total)


class Migrator:
    def __init__(self, data_dir, manifest, *, fetcher=None, recipes=None, caps=(), reporter=None, deep=False,
                 free_bytes=None):
        self.data = Path(data_dir)
        self.manifest = manifest
        self.models = self.data / "models"
        self.state_path = self.models / STATE_NAME
        self.fetcher = fetcher or HfFetcher(self.data / "hf" / "hub")
        self.recipes = RECIPES if recipes is None else recipes
        self.caps = set(caps)
        self.r = reporter or Reporter()
        self.deep = deep
        self.free_bytes = free_bytes or (lambda p: shutil.disk_usage(p).free)

    # -- state

    def load_state(self):
        try:
            state = json.loads(self.state_path.read_text(encoding="utf-8"))
            if state.get("schema") == SCHEMA and isinstance(state.get("artifacts"), dict):
                return state
        except (OSError, ValueError):
            pass
        return {"schema": SCHEMA, "set": None, "artifacts": {}}

    # -- verification

    def _hf_file_ok(self, a, f, hashed):
        """Is this pinned file present and intact? hashed: compute the hash (new download, or --deep)."""
        repo, rev, path = a.raw["repo"], a.raw["revision"], f["path"]
        p = self.fetcher.local_path(repo, rev, path)
        if not p.exists() or p.stat().st_size != int(f["size"]):
            return False
        want_sha256, want_sha1 = f.get("sha256"), f.get("git_sha1")
        if not hashed:  # cheap identity: the cache names blobs by the hash the server reported
            blob = self.fetcher.blob_name(repo, rev, path)
            if blob is not None and blob in (want_sha256, want_sha1):
                return True
            # no blob link (plain dir): fall through and hash
        if want_sha256:
            return sha256_file(p) == want_sha256
        if want_sha1:
            return git_sha1_file(p) == want_sha1
        return True

    def _derived_dir(self, a, fp):
        return self.models / f"{a.id}@{fp[:12]}"

    def _derived_ok(self, a, fp, hashed=False):
        d = self._derived_dir(a, fp)
        try:
            marker = json.loads((d / MARKER).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return False
        if marker.get("fingerprint") != fp:
            return False
        for name, rec in marker.get("files", {}).items():
            p = d / name
            if not p.is_file() or p.stat().st_size != rec["size"]:
                return False
            if hashed and sha256_file(p) != rec["sha256"]:
                return False
        return bool(marker.get("files"))

    # -- work

    def plan(self, recorded=None):
        """[(artifact, fingerprint, missing files or None for derived-to-build or [] when present)].
        recorded: {id: fingerprint} of the switched state; files of an hf artifact not in it (adopted from an older
        install) are hashed once, so a corrupt cached file is caught before it is recorded as installed."""
        required = self.manifest.required(self.caps)
        fps, plan = {}, []
        for a in required:
            fp = fingerprint(a, {i: fps[i] for i in a.inputs})
            fps[a.id] = fp
            if a.kind == "hf":
                hashed = self.deep or (recorded is not None and recorded.get(a.id) != fp)
                missing = [f for f in a.files if not self._hf_file_ok(a, f, hashed=hashed)]
                plan.append((a, fp, missing))
            else:
                plan.append((a, fp, [] if self._derived_ok(a, fp, hashed=self.deep) else None))
        return plan

    def _fetch_hf(self, a, missing):
        repo, rev = a.raw["repo"], a.raw["revision"]
        self.r.status(f"Downloading {a.label}")
        self.r.live = lambda: self.fetcher.partial_bytes(repo)
        stop = threading.Event()

        def tick():  # progress while a file downloads, not only when it ends (a 7 GB file is one file)
            while not stop.wait(1.0):
                self.r.progress()

        threading.Thread(target=tick, daemon=True).start()
        try:
            for f in missing:
                if self.fetcher.local_path(repo, rev, f["path"]).exists():  # present but bad: or the fetch returns it
                    self.fetcher.discard(repo, rev, f["path"])
                self.fetcher.fetch(repo, rev, f["path"])
                self.r.live = lambda: 0
                self.r.done += int(f["size"])
                self.r.progress()
                self.r.live = lambda: self.fetcher.partial_bytes(repo)
        finally:
            stop.set()
            self.r.live = lambda: 0
        self.r.status(f"Verifying {a.label}")
        bad = [f["path"] for f in missing if not self._hf_file_ok(a, f, hashed=True)]
        for path in bad:
            self.fetcher.discard(repo, rev, path)
        if bad:
            raise MigrationError(f"{a.label}: downloaded file failed verification ({', '.join(bad)}); try again")

    def _input_path(self, artifact_id, plan):
        for a, fp, _ in plan:
            if a.id == artifact_id:
                if a.kind == "hf":
                    return self.fetcher.local_path(a.raw["repo"], a.raw["revision"], "")
                return self._derived_dir(a, fp)
        raise MigrationError(f"input {artifact_id} is not part of the plan")

    def _build_derived(self, a, fp, plan):
        recipe = self.recipes.get(a.raw["recipe"])
        if recipe is None or recipe[1] != a.raw["recipe_version"]:
            raise MigrationError(f"{a.label}: this engine has no recipe {a.raw['recipe']} v{a.raw['recipe_version']}")
        build, _ = recipe
        staging_root = self.models / ".staging"
        remove_tree(staging_root)  # a previous run died mid-build: start that build over
        staging = staging_root / self._derived_dir(a, fp).name
        staging.mkdir(parents=True)
        self.r.status(f"Preparing {a.label}")
        base, size = self.r.done, a.size

        def on_fraction(x):
            self.r.done = base + int(size * min(max(x, 0.0), 1.0))
            self.r.progress()

        build({i: self._input_path(i, plan) for i in a.inputs}, staging, on_fraction)
        files = {}
        for p in sorted(staging.rglob("*")):
            if p.is_file():
                files[str(p.relative_to(staging))] = {"size": p.stat().st_size, "sha256": sha256_file(p)}
        if not files:
            raise MigrationError(f"{a.label}: recipe produced no files")
        write_json_atomic(staging / MARKER, {"id": a.id, "fingerprint": fp, "recipe": a.raw["recipe"],
                                             "recipe_version": a.raw["recipe_version"], "files": files,
                                             "created": time.strftime("%Y-%m-%dT%H:%M:%S%z")})
        final = self._derived_dir(a, fp)
        if final.exists():  # same fingerprint but failed verification: move aside, delete after the switch
            trash = self.models / ".trash"
            trash.mkdir(parents=True, exist_ok=True)
            os.replace(final, trash / f"{final.name}.{os.getpid()}")
        os.replace(staging, final)
        remove_tree(staging_root)
        if not self._derived_ok(a, fp, hashed=True):
            raise MigrationError(f"{a.label}: built artifact failed verification")
        self.r.done = base + size
        self.r.progress()

    def _entry(self, a, fp):
        if a.kind == "hf":
            return {"kind": "hf", "repo": a.raw["repo"], "revision": a.raw["revision"], "fingerprint": fp,
                    "path": str(self.fetcher.local_path(a.raw["repo"], a.raw["revision"], "")),
                    "files": {f["path"]: {"size": int(f["size"])} for f in a.files}}
        d = self._derived_dir(a, fp)
        return {"kind": "derived", "recipe": a.raw["recipe"], "recipe_version": a.raw["recipe_version"],
                "fingerprint": fp, "path": str(d.relative_to(self.data))}

    def _check_disk(self, need):
        self.data.mkdir(parents=True, exist_ok=True)
        free = self.free_bytes(self.data)
        margin = 1_000_000_000
        if free is not None and free < need + margin:
            raise MigrationError(f"Not enough free disk space: {need / 1e9:.1f} GB needed (+1 GB margin), "
                                 f"{free / 1e9:.1f} GB free")

    def collect_garbage(self, state, old_state):
        """Delete what the switched set no longer references. Only inside models/ and managed HF repos."""
        freed = 0
        keep_dirs = {Path(e["path"]).name for e in state["artifacts"].values() if e["kind"] == "derived"}
        if self.models.exists():
            for p in self.models.iterdir():
                if p.name in (".staging", ".trash"):
                    freed += tree_bytes(p)
                    remove_tree(p)
                elif p.is_dir() and "@" in p.name and (p / MARKER).exists() and p.name not in keep_dirs:
                    self.r.status(f"Removing unused {p.name.split('@')[0]}")
                    freed += tree_bytes(p)
                    remove_tree(p)
        pinned = {}
        for e in state["artifacts"].values():
            if e["kind"] == "hf":
                pinned.setdefault(e["repo"], set()).add(e["revision"])
        repos = set(pinned)
        repos.update(e["repo"] for e in old_state.get("artifacts", {}).values() if e.get("kind") == "hf")
        repos.update(a.raw["repo"] for a in self.manifest.artifacts if a.kind == "hf")
        repos.update(r["repo"] for r in self.manifest.retire if r.get("kind", "hf") == "hf")
        for repo in sorted(repos):
            for rev in self.fetcher.revisions(repo):
                if rev not in pinned.get(repo, ()):
                    self.r.status(f"Removing unused {repo} {rev[:7]}")
                    freed += self.fetcher.delete_revision(repo, rev) or 0
        return freed

    def run(self):
        self.models.mkdir(parents=True, exist_ok=True)
        with self._lock():
            old_state = self.load_state()
            remove_tree(self.models / ".staging")  # a build that died (e.g. disk full): its space counts as free again
            self.r.status("Checking models")
            plan = self.plan({k: e.get("fingerprint") for k, e in old_state["artifacts"].items()})
            download_bytes = sum(int(f["size"]) for a, _, m in plan if a.kind == "hf" and m for f in m)
            todo_bytes = download_bytes + sum(a.size for a, _, m in plan if a.kind == "derived" and m is None)
            self.r.total, self.r.done = max(todo_bytes, 1), 0
            self.r.progress()
            if todo_bytes:
                self._check_disk(todo_bytes)
            for a, fp, missing in plan:
                if a.kind == "hf" and missing:
                    self._fetch_hf(a, missing)
                elif a.kind == "derived" and missing is None:
                    self._build_derived(a, fp, plan)
            # Everything required is present and verified: switch in one rename.
            state = {"schema": SCHEMA, "set": self.manifest.set,
                     "artifacts": {a.id: self._entry(a, fp) for a, fp, _ in plan},
                     "switched": time.strftime("%Y-%m-%dT%H:%M:%S%z")}
            write_json_atomic(self.state_path, state)
            self.r.done = self.r.total
            self.r.progress()
            try:
                freed = self.collect_garbage(state, old_state)
            except Exception as exc:  # the new set is live; leftovers are retried by the next run
                self.r.status(f"Cleanup postponed ({type(exc).__name__}: {exc})")
                freed = 0
            return {"set": self.manifest.set, "artifacts": sorted(state["artifacts"]), "downloaded": download_bytes,
                    "freed": freed, "previous": old_state.get("set")}

    @contextlib.contextmanager
    def _lock(self):
        try:
            import fcntl
        except ImportError:  # pragma: no cover (not macOS/Linux)
            yield
            return
        with open(self.models / ".lock", "w") as f:
            try:
                fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                raise MigrationError("Another model update is running") from None
            try:
                yield
            finally:
                fcntl.flock(f, fcntl.LOCK_UN)


# ---------------------------------------------------------------- what the engine reads

def installed(data_dir):
    """The switched model state, or None before the first migration."""
    try:
        state = json.loads((Path(data_dir) / "models" / STATE_NAME).read_text(encoding="utf-8"))
        return state if state.get("schema") == SCHEMA else None
    except (OSError, ValueError):
        return None


def artifact_dir(data_dir, artifact_id):
    """Absolute dir of an installed derived artifact whose marker matches the switched state, else None."""
    state = installed(data_dir)
    entry = (state or {}).get("artifacts", {}).get(artifact_id)
    if not entry or entry.get("kind") != "derived":
        return None
    d = Path(data_dir) / entry["path"]
    try:
        marker = json.loads((d / MARKER).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return d if marker.get("fingerprint") == entry["fingerprint"] else None


def capabilities(data_dir):
    sys.path.insert(0, str(ENGINE_DIR))
    import backends
    return {"mlx"} if backends.select_engine(config=backends.engine_config(data_dir))["ar"] == "mlx" else set()


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("command", choices=("migrate", "status"))
    ap.add_argument("--data-dir", required=True)
    ap.add_argument("--manifest", default=os.environ.get("YUE2_STUDIO_MODELS_MANIFEST") or str(DEFAULT_MANIFEST))
    ap.add_argument("--deep", action="store_true", help="hash every present file instead of trusting size + blob name")
    args = ap.parse_args(argv)
    reporter = Reporter()
    try:
        manifest = Manifest.read(args.manifest)
        caps = capabilities(args.data_dir)
        m = Migrator(args.data_dir, manifest, caps=caps, reporter=reporter, deep=args.deep)
        if args.command == "status":
            plan = m.plan()
            print(json.dumps({"installed": (installed(args.data_dir) or {}).get("set"), "required": manifest.set,
                              "caps": sorted(caps),
                              "todo": [a.id for a, _, miss in plan if miss is None or miss]}))
            return 0
        summary = m.run()
        reporter.event(type="done", **summary)
        return 0
    except Exception as exc:
        reporter.event(type="error", message=f"{exc}" if isinstance(exc, MigrationError) else f"{type(exc).__name__}: {exc}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
