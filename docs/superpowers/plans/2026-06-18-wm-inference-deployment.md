# wm-inference k0s Deployment — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy `imu-policy/world-model`'s on-robot inference service into the Phantom-OS k0s `core` stack as a fourth mutually-exclusive "control brain," following the phantom-sonic / phantom-locomotion / positronic paradigm.

**Architecture:** A `wm-inference` DaemonSet in the `positronic` namespace, gated on `foundation.bot/has-wm-inference`, mutually exclusive with positronic/locomotion/sonic. The active `wm-inference` container reads `WM_*` env (host-local `wm-inference-config` ConfigMap via `envFrom`, plus shell-default wrapper for first boot); a `model-loader` init stages TensorRT engines from a data-image; a co-located action-solver container slot is reserved (inert until a Phase-2 image exists). Per-host knobs flow from a `worldModel:` host-config block through a new bootstrap `wm-config` phase. See the design doc: `docs/superpowers/specs/2026-06-18-wm-inference-deployment-design.html`.

**Tech Stack:** Kustomize manifests, Python 3 (`scripts/lib/host-config.py`, pytest), Bash (`scripts/bootstrap-robot.sh`, `scripts/positronic.sh`), k0s/ArgoCD.

**Design deviation flagged:** Config delivery uses the **sonic-style host-local ConfigMap** (not the positronic-style strategic-merge into the Argo app I floated during brainstorming). Rationale in the design doc §6 — `wm_inference_main` reads pure env, so a shell-default wrapper + `envFrom optional` gives the same capability with no bootstrap surgery and no base-CM/ArgoCD conflict. If positronic-style is required instead, swap Phase 4's `wm_config()` for the `image_overrides`/`deployments` merge path and add a base `configmap.yaml`.

**Reference precedents (read before starting):**
- `manifests/base/phantom-sonic/` (multi-container brain Pod + kustomization)
- `scripts/lib/host-config.py` — `DEFAULT_SONIC` / `SONIC_FIELD_TO_ENV` / `cmd_get_phantom_sonic_config_kv` (~L743), `NODE_LABEL_REGISTRY` (~L117), `CONTAINER_TARGETS` (~L1048), mutual-exclusion `enabled_drivers` (~L2749), sonic validation (~L2837)
- `scripts/lib/test_host_config_okvis2x.py` (test style for a new DaemonSet)
- `scripts/bootstrap-robot.sh` — `sonic_config()` (~L2529), flag/skip/dispatch wiring (`--sonic-config` ~L388, `SKIP_SONIC_CONFIG` ~L329/L611/L637, run-list ~L5644)
- `scripts/positronic.sh` — `cmd_sonic*` group (~L595–L755) and dispatch `case "$sub"` (~L1335)

**Conventions:**
- Run python tests with: `python3 -m pytest scripts/lib/test_host_config_wm_inference.py -v` (from repo root).
- Commit messages: **omit any Co-Authored-By / Claude trailer** (per user standing preference).
- Anchor edits by the quoted nearby strings shown — line numbers drift as sonic/okvis entries exist.

---

## Phase 1 — `host-config.py` wiring (TDD core)

The testable heart of the change: node label, image targets, the `worldModel` config block + emitter, and the 4-way mutual exclusion. All covered by a new pytest file modeled on `test_host_config_okvis2x.py`.

### Task 1.1: Failing test — `has-wm-inference` node label is registered

**Files:**
- Create: `scripts/lib/test_host_config_wm_inference.py`

- [ ] **Step 1: Write the failing test**

```python
"""Tests for the wm-inference DaemonSet host-config wiring in host-config.py.

wm-inference is the World-Model on-robot brain (has-wm-inference gated,
default-off), mutually exclusive with positronic/locomotion/sonic. Per-host
knobs come from the worldModel: block, rendered to the wm-inference-config
ConfigMap (KEY=VALUE via get-world-model-config-kv). The tasks: list derives
the parallel WM_TASK_IDS / WM_PREDICTOR_ENGINES CSV env vars.
"""
from __future__ import annotations

import importlib.util
import io
from contextlib import redirect_stdout
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
HOST_CONFIG = HERE / "host-config.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("host_config", HOST_CONFIG)
    assert spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


hc = _load_module()


def _kv(cfg: dict) -> dict[str, str]:
    """Run cmd_get_world_model_config_kv, parse KEY=VALUE lines into a dict."""
    buf = io.StringIO()
    with redirect_stdout(buf):
        rc = hc.cmd_get_world_model_config_kv(cfg)
    assert rc == 0, buf.getvalue()
    out = {}
    for line in buf.getvalue().splitlines():
        if not line.strip():
            continue
        k, _, v = line.partition("=")
        out[k] = v
    return out


def test_has_wm_inference_label_registered():
    labels = {key: default for key, default, _desc in hc.NODE_LABEL_REGISTRY}
    assert labels["foundation.bot/has-wm-inference"] == "false"
```

- [ ] **Step 2: Run it — expect failure**

Run: `python3 -m pytest scripts/lib/test_host_config_wm_inference.py::test_has_wm_inference_label_registered -v`
Expected: FAIL — `KeyError: 'foundation.bot/has-wm-inference'`.

- [ ] **Step 3: Add the node label**

In `scripts/lib/host-config.py`, in `NODE_LABEL_REGISTRY`, insert this entry to preserve the existing alphabetical-by-suffix ordering (after the `has-streamer` / `has-state-estimator` entries, before `has-yovariable`):

```python
    ("foundation.bot/has-wm-inference",
     "false",
     "wm-inference (world-model brain) DaemonSet — mutually exclusive with "
     "has-positronic / has-locomotion / has-sonic"),
```

- [ ] **Step 4: Run it — expect pass**

Run: `python3 -m pytest scripts/lib/test_host_config_wm_inference.py::test_has_wm_inference_label_registered -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/test_host_config_wm_inference.py scripts/lib/host-config.py
git commit -m "feat(wm-inference): register foundation.bot/has-wm-inference node label"
```

### Task 1.2: Image targets — `wm-inference` + `wm-inference-models`

**Files:**
- Modify: `scripts/lib/host-config.py` (`CONTAINER_TARGETS`)
- Test: `scripts/lib/test_host_config_wm_inference.py`

- [ ] **Step 1: Write the failing test**

```python
def test_wm_inference_image_targets_registered():
    assert hc.CONTAINER_TARGETS["wm-inference"]["stack"] == "core"
    assert hc.CONTAINER_TARGETS["wm-inference"]["manifest_image"] == \
        "localhost:5443/wm-inference"
    assert hc.CONTAINER_TARGETS["wm-inference-models"]["stack"] == "core"
    assert hc.CONTAINER_TARGETS["wm-inference-models"]["manifest_image"] == \
        "localhost:5443/wm-inference-models"
```

- [ ] **Step 2: Run it — expect failure**

Run: `python3 -m pytest scripts/lib/test_host_config_wm_inference.py::test_wm_inference_image_targets_registered -v`
Expected: FAIL — `KeyError: 'wm-inference'`.

- [ ] **Step 3: Add the two CONTAINER_TARGETS entries**

In `scripts/lib/host-config.py`, in `CONTAINER_TARGETS`, after the `"dma-bridge"` entry add:

```python
    "wm-inference": {
        # World-Model on-robot brain DaemonSet (foundation.bot/has-wm-inference
        # gated). The wm_inference_main C++ service; published as
        # foundationbot/wm-inference (arm64/Thor TensorRT engines). Base
        # manifest uses the local-registry placeholder; host-config images:
        # supplies the per-host ref. Same indirection as phantom-locomotion.
        "stack": "core",
        "manifest_image": "localhost:5443/wm-inference",
    },
    "wm-inference-models": {
        # Consumed by wm-inference's model-loader initContainer: an immutable
        # data-image carrying the Thor-built engines + PCA + tokenizer +
        # registry, copied into a shared emptyDir at boot. Published as
        # foundationbot/wm-inference-models.
        "stack": "core",
        "manifest_image": "localhost:5443/wm-inference-models",
    },
```

- [ ] **Step 4: Run it — expect pass**

Run: `python3 -m pytest scripts/lib/test_host_config_wm_inference.py::test_wm_inference_image_targets_registered -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/host-config.py
git commit -m "feat(wm-inference): add wm-inference + wm-inference-models image targets"
```

### Task 1.3: `worldModel` config emitter — scalars + tasks → env

**Files:**
- Modify: `scripts/lib/host-config.py` (new constants + `_parse_world_model_tasks` + `cmd_get_world_model_config_kv`)
- Test: `scripts/lib/test_host_config_wm_inference.py`

- [ ] **Step 1: Write the failing tests**

```python
def test_world_model_kv_defaults():
    out = _kv({})  # absent worldModel block -> complete default set
    assert out["WM_CAMERA_ID"] == "0"
    assert out["WM_FRESHNESS_MS"] == "200"
    assert out["WM_BASE_SHA"] == "33cc3ad3ab7cfc92f8eb4cf177ba552680e2def6"
    assert out["WM_TASK_IDS"] == "honda_reach_insert,honda_rehome"
    assert out["WM_PREDICTOR_ENGINES"] == \
        "/wm-models/honda_reach_insert.engine,/wm-models/honda_rehome.engine"


def test_world_model_kv_overrides_and_tasks():
    cfg = {"worldModel": {
        "cameraId": 3,
        "freshnessMs": 150,
        "tasks": [{"id": "pick", "engine": "pick.engine"}],
    }}
    out = _kv(cfg)
    assert out["WM_CAMERA_ID"] == "3"
    assert out["WM_FRESHNESS_MS"] == "150"
    assert out["WM_TASK_IDS"] == "pick"
    assert out["WM_PREDICTOR_ENGINES"] == "/wm-models/pick.engine"


def test_world_model_kv_rejects_unknown_field():
    buf = io.StringIO()
    with redirect_stdout(buf):
        rc = hc.cmd_get_world_model_config_kv({"worldModel": {"bogus": 1}})
    assert rc == 2


def test_world_model_kv_rejects_engine_with_path():
    buf = io.StringIO()
    with redirect_stdout(buf):
        rc = hc.cmd_get_world_model_config_kv(
            {"worldModel": {"tasks": [{"id": "x", "engine": "sub/x.engine"}]}})
    assert rc == 2
```

- [ ] **Step 2: Run them — expect failure**

Run: `python3 -m pytest scripts/lib/test_host_config_wm_inference.py -k world_model -v`
Expected: FAIL — `AttributeError: module ... has no attribute 'cmd_get_world_model_config_kv'`.

- [ ] **Step 3: Implement the constants, parser, and emitter**

In `scripts/lib/host-config.py`, directly after the phantom-sonic block (after `cmd_get_phantom_sonic_config_kv`, ~L801), add:

```python
# ── world-model (wm-inference brain) ───────────────────────────────────────
# Per-host knobs for the wm-inference DaemonSet, rendered into the
# wm-inference-config ConfigMap (envFrom'd by the wm-inference container).
# Scalars map host-config camelCase -> the WM_* env names wm_inference_main's
# loadConfigFromEnv() reads. The tasks: list (id<->engine pairs) derives the
# two PARALLEL CSV vars the binary consumes (WM_TASK_IDS / WM_PREDICTOR_ENGINES).
# Defaults mirror the manifest shell-defaults exactly so a bare (or absent)
# worldModel block renders a working ConfigMap.
DEFAULT_WORLD_MODEL_SCALARS: dict[str, str] = {
    "cameraId":    "0",
    "baseSha":     "33cc3ad3ab7cfc92f8eb4cf177ba552680e2def6",
    "freshnessMs": "200",
}

WORLD_MODEL_FIELD_TO_ENV: dict[str, str] = {
    "cameraId":    "WM_CAMERA_ID",
    "baseSha":     "WM_BASE_SHA",
    "freshnessMs": "WM_FRESHNESS_MS",
}

# Engines are staged by the model-loader init into this in-pod dir.
WM_ENGINE_DIR: str = "/wm-models"

DEFAULT_WORLD_MODEL_TASKS: list[dict[str, str]] = [
    {"id": "honda_reach_insert", "engine": "honda_reach_insert.engine"},
    {"id": "honda_rehome",       "engine": "honda_rehome.engine"},
]


def _parse_world_model_tasks(v: object) -> "tuple[bool, object]":
    """Validate a worldModel.tasks value. Returns (True, [ {id,engine}, ... ])
    on success, or (False, "<error string>") on failure. Each entry must be a
    {id, engine} mapping with non-empty string values; engine must be a bare
    filename (no path) because the emitter prefixes WM_ENGINE_DIR."""
    if not isinstance(v, list) or not v:
        return False, "worldModel.tasks: must be a non-empty list of {id, engine} mappings"
    out: list[dict[str, str]] = []
    for i, item in enumerate(v):
        if not isinstance(item, dict):
            return False, f"worldModel.tasks[{i}]: must be a mapping with id + engine"
        extra = set(item) - {"id", "engine"}
        if extra:
            return False, (f"worldModel.tasks[{i}]: unknown keys {sorted(extra)} "
                           f"(permitted: id, engine)")
        tid, eng = item.get("id"), item.get("engine")
        if not isinstance(tid, str) or not tid:
            return False, f"worldModel.tasks[{i}].id: must be a non-empty string"
        if not isinstance(eng, str) or not eng:
            return False, f"worldModel.tasks[{i}].engine: must be a non-empty string"
        if "/" in eng:
            return False, (f"worldModel.tasks[{i}].engine: must be a bare filename, "
                           f"not a path (got {eng!r})")
        out.append({"id": tid, "engine": eng})
    return True, out


def cmd_get_world_model_config_kv(cfg: dict) -> int:
    """Emit KEY=VALUE lines for the wm-inference-config ConfigMap.

    Operator overrides from the worldModel block layer on top of the defaults
    so the pod always has a complete set of knobs. Scalars emit in the stable
    order of DEFAULT_WORLD_MODEL_SCALARS; the tasks list derives WM_TASK_IDS +
    WM_PREDICTOR_ENGINES last. ASCII, no shell quoting — bootstrap's wm-config
    phase drops each line into a YAML-quoted KEY: "VALUE".
    """
    block = cfg.get("worldModel") or {}
    if not isinstance(block, dict):
        print("error: 'worldModel' must be a mapping", file=sys.stderr)
        return 2

    permitted = set(DEFAULT_WORLD_MODEL_SCALARS) | {"tasks"}
    merged: dict[str, object] = dict(DEFAULT_WORLD_MODEL_SCALARS)
    tasks = DEFAULT_WORLD_MODEL_TASKS
    for k, v in block.items():
        if k not in permitted:
            print(
                f"error: worldModel: unknown field {k!r} (permitted: "
                f"{sorted(permitted)})",
                file=sys.stderr,
            )
            return 2
        if k == "tasks":
            ok, parsed = _parse_world_model_tasks(v)
            if not ok:
                print(f"error: {parsed}", file=sys.stderr)
                return 2
            tasks = parsed  # type: ignore[assignment]
            continue
        if not isinstance(v, (str, int, float)) or isinstance(v, bool):
            print(
                f"error: worldModel.{k}: must be a scalar (str/int/float), "
                f"got {type(v).__name__}",
                file=sys.stderr,
            )
            return 2
        merged[k] = v

    task_ids = ",".join(t["id"] for t in tasks)
    pred_engines = ",".join(f"{WM_ENGINE_DIR}/{t['engine']}" for t in tasks)

    lines = [
        f"{WORLD_MODEL_FIELD_TO_ENV[field]}={merged[field]}"
        for field in DEFAULT_WORLD_MODEL_SCALARS.keys()
    ]
    lines.append(f"WM_TASK_IDS={task_ids}")
    lines.append(f"WM_PREDICTOR_ENGINES={pred_engines}")
    print("\n".join(lines))
    return 0
```

- [ ] **Step 4: Run them — expect pass**

Run: `python3 -m pytest scripts/lib/test_host_config_wm_inference.py -k world_model -v`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/host-config.py scripts/lib/test_host_config_wm_inference.py
git commit -m "feat(wm-inference): worldModel config block emitter (scalars + tasks->env)"
```

### Task 1.4: Wire the emitter into the CLI dispatch

**Files:**
- Modify: `scripts/lib/host-config.py` (`main()`)
- Test: `scripts/lib/test_host_config_wm_inference.py`

- [ ] **Step 1: Write the failing test**

```python
import subprocess
import sys as _sys


def test_cli_get_world_model_config_kv(tmp_path):
    hc_path = HERE / "host-config.py"
    cfg = tmp_path / "host-config.yaml"
    cfg.write_text("robot: r\nworldModel:\n  cameraId: 2\n")
    res = subprocess.run(
        [_sys.executable, str(hc_path), str(cfg), "get-world-model-config-kv"],
        capture_output=True, text=True)
    assert res.returncode == 0, res.stderr
    assert "WM_CAMERA_ID=2" in res.stdout
    assert "WM_TASK_IDS=honda_reach_insert,honda_rehome" in res.stdout
```

- [ ] **Step 2: Run it — expect failure**

Run: `python3 -m pytest scripts/lib/test_host_config_wm_inference.py::test_cli_get_world_model_config_kv -v`
Expected: FAIL — nonzero return code (`unknown command`).

- [ ] **Step 3: Add the dispatch entry**

In `scripts/lib/host-config.py`, in `main()`, directly after the line:

```python
    if cmd == "get-phantom-sonic-config-kv":
        return cmd_get_phantom_sonic_config_kv(cfg)
```

add:

```python
    if cmd == "get-world-model-config-kv":
        return cmd_get_world_model_config_kv(cfg)
```

- [ ] **Step 4: Run it — expect pass**

Run: `python3 -m pytest scripts/lib/test_host_config_wm_inference.py::test_cli_get_world_model_config_kv -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/host-config.py scripts/lib/test_host_config_wm_inference.py
git commit -m "feat(wm-inference): wire get-world-model-config-kv into host-config CLI"
```

### Task 1.5: Extend mutual exclusion to 4-way + validate the `worldModel` block

**Files:**
- Modify: `scripts/lib/host-config.py` (`validate()` exclusion block ~L2749; add worldModel validation near the sonic validation ~L2837)
- Test: `scripts/lib/test_host_config_wm_inference.py`

- [ ] **Step 1: Write the failing tests**

```python
def _validate(cfg: dict) -> list[str]:
    """Return the list of validation error strings for cfg."""
    return hc.validate_config(cfg) if hasattr(hc, "validate_config") else hc.validate(cfg)


def test_wm_inference_excludes_default_on_positronic():
    cfg = {"robot": "r", "nodeLabels": {
        "foundation.bot/has-wm-inference": "true"}}
    errs = _validate(cfg)
    assert any("has-wm-inference" in e and "has-positronic" in e for e in errs)


def test_wm_inference_ok_when_positronic_disabled():
    cfg = {"robot": "r", "nodeLabels": {
        "foundation.bot/has-positronic": "false",
        "foundation.bot/has-wm-inference": "true"}}
    errs = _validate(cfg)
    assert not any("mutually exclusive" in e or "requires explicitly" in e for e in errs)


def test_wm_and_sonic_mutually_exclusive():
    cfg = {"robot": "r", "nodeLabels": {
        "foundation.bot/has-positronic": "false",
        "foundation.bot/has-sonic": "true",
        "foundation.bot/has-wm-inference": "true"}}
    errs = _validate(cfg)
    assert any("mutually exclusive" in e for e in errs)


def test_validate_rejects_bad_worldmodel_task():
    cfg = {"robot": "r", "worldModel": {
        "tasks": [{"id": "x", "engine": "a/b.engine"}]}}
    errs = _validate(cfg)
    assert any("worldModel.tasks" in e for e in errs)
```

> NOTE: confirm the validate entrypoint name first — `grep -n "^def validate" scripts/lib/host-config.py`. The helper `_validate` above tries `validate_config` then `validate`; if neither matches, adjust to the actual function (it returns/collects an `errors` list). If `validate()` prints instead of returning, call it via the CLI `validate` subcommand with `subprocess` and assert on stderr + return code instead.

- [ ] **Step 2: Run them — expect failure**

Run: `python3 -m pytest scripts/lib/test_host_config_wm_inference.py -k "wm_inference_exclud or wm_and_sonic or wm_inference_ok or worldmodel_task" -v`
Expected: FAIL — exclusion doesn't yet name wm-inference; worldModel block not validated.

- [ ] **Step 3a: Add `has-wm-inference` to the exclusion list**

In `scripts/lib/host-config.py`, in the mutual-exclusion block, after:

```python
            effective_sonic = nl.get("foundation.bot/has-sonic", "false")
```

add:

```python
            effective_wm = nl.get("foundation.bot/has-wm-inference", "false")
```

and in the `enabled_drivers` tuple, after the `("foundation.bot/has-sonic", effective_sonic),` line, add:

```python
                    ("foundation.bot/has-wm-inference", effective_wm),
```

Then update the two error-message string literals in that block to name the fourth label, e.g. change `"foundation.bot/has-sonic are mutually exclusive — "` to:

```python
                        "foundation.bot/has-sonic and "
                        "foundation.bot/has-wm-inference are mutually exclusive — "
```

(The "requires explicitly setting has-positronic: false" branch already generalizes over `enabled_drivers`, so it needs no change.)

- [ ] **Step 3b: Validate the `worldModel` block**

In `validate()`, directly after the phantom-sonic validation block (the one that checks `cfg.get("phantomSonic")` against `DEFAULT_SONIC`, ~L2837), add:

```python
    # worldModel is optional. Reuse the emitter's parsing rules: unknown
    # fields, non-scalar scalars, and malformed tasks all surface as errors.
    wm = cfg.get("worldModel")
    if wm is not None:
        if not isinstance(wm, dict):
            errors.append("'worldModel' must be a mapping")
        else:
            permitted = sorted(set(DEFAULT_WORLD_MODEL_SCALARS) | {"tasks"})
            for k, v in wm.items():
                if k not in permitted:
                    errors.append(
                        f"worldModel: unknown field {k!r} (permitted: {permitted})")
                    continue
                if k == "tasks":
                    ok, parsed = _parse_world_model_tasks(v)
                    if not ok:
                        errors.append(parsed)  # type: ignore[arg-type]
                    continue
                if isinstance(v, bool) or not isinstance(v, (str, int, float)):
                    errors.append(
                        f"worldModel.{k}: must be a scalar (str/int/float), "
                        f"got {type(v).__name__}")
```

> If `validate()`'s error accumulator is named something other than `errors`, match the local name used in that function.

- [ ] **Step 4: Run them — expect pass; then the whole file**

Run: `python3 -m pytest scripts/lib/test_host_config_wm_inference.py -v`
Expected: PASS (all tests).
Then regression-check the sonic/locomotion exclusion still passes:
Run: `python3 -m pytest scripts/lib/ -v`
Expected: PASS (no regressions).

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/host-config.py scripts/lib/test_host_config_wm_inference.py
git commit -m "feat(wm-inference): 4-way brain exclusion + worldModel block validation"
```

---

## Phase 2 — Manifests

### Task 2.1: Create the `wm-inference` base manifest + kustomization

**Files:**
- Create: `manifests/base/wm-inference/wm-inference.yaml`
- Create: `manifests/base/wm-inference/kustomization.yaml`

- [ ] **Step 1: Write `wm-inference.yaml`**

```yaml
# wm-inference — DaemonSet running the World-Model on-robot brain. Ports
# imu-policy/world-model/inference/deploy/daemonset-nvidia.yaml into the fleet
# paradigm. Serves z_ref goal latents to a (Phase-2) action-solver over POSIX
# shm rings (/wm_zref_req, /wm_zref_resp) shared via hostIPC + /dev/shm.
#
# ── Mutual exclusion ───────────────────────────────────────────────────────
# foundation.bot/has-wm-inference gates this DaemonSet. The Pod is the robot's
# "brain" (its future action-solver drives /desired), so it is mutually
# exclusive with positronic-control, phantom-locomotion, and phantom-sonic.
# has-positronic defaults to "true"; migrating a robot to wm-inference requires
# setting has-positronic: "false" (and has-locomotion/has-sonic "false").
# The host-config validator enforces this.
#
# ── Images ─────────────────────────────────────────────────────────────────
# wm-inference runs localhost:5443/wm-inference (published as
# foundationbot/wm-inference, arm64/Thor TensorRT engines); the model-loader
# init runs localhost:5443/wm-inference-models (the immutable engine/PCA/
# tokenizer data-image). Per-robot tags are rewritten by Kustomize from
# host-config.yaml images.wm-inference / images.wm-inference-models.
#
# ── Options ────────────────────────────────────────────────────────────────
# Per-host knobs (camera id, base sha, freshness, task<->engine pairs) come
# from the wm-inference-config ConfigMap rendered by bootstrap's wm-config
# phase from host-config.yaml's worldModel block. The container envFrom's it
# (optional: true) and a shell-default wrapper supplies first-boot defaults so
# the pod starts before the CM is applied. Same lifecycle as
# phantom-sonic-config / phantom-locomotion-config.
#
# ── Action-solver slot ─────────────────────────────────────────────────────
# The z_ref consumer/WBC (Phase 2) will be a co-located container in THIS Pod,
# sharing /dev/shm. No shipping image exists yet (only the bench ping_client),
# so it is documented but not declared. When it lands: add a second container
# here (image localhost:5443/wm-action-solver via a new CONTAINER_TARGETS key),
# append it to WM_CONTAINERS in positronic.sh, and the Pod remains the
# exclusion unit either way.
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: wm-inference
  namespace: positronic
  labels:
    app.kubernetes.io/name: wm-inference
    app.kubernetes.io/part-of: phantomos
    app.kubernetes.io/component: world-model
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: wm-inference
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
  template:
    metadata:
      labels:
        app.kubernetes.io/name: wm-inference
        app.kubernetes.io/component: world-model
    spec:
      # Schedule only on robot nodes that opted in. Chip gate intentionally
      # dropped (matches phantom-locomotion/sonic): the per-host opt-in label +
      # the per-host wm-inference-models image (which carries arch-correct
      # engines) are the contract.
      nodeSelector:
        foundation.bot/robot: "true"
        foundation.bot/has-wm-inference: "true"
      tolerations:
        - operator: Exists
          effect: NoSchedule

      hostNetwork: true
      hostIPC: true
      dnsPolicy: ClusterFirstWithHostNet
      runtimeClassName: nvidia
      imagePullSecrets:
        - name: dockerhub-creds
      terminationGracePeriodSeconds: 15

      initContainers:
        # Stage engines/PCA/tokenizer/registry out of the immutable data-image
        # into a shared emptyDir the main container mounts read-only.
        - name: model-loader
          image: localhost:5443/wm-inference-models:PLACEHOLDER
          imagePullPolicy: IfNotPresent
          command:
            - /bin/sh
            - -c
            - |
              set -e
              cp -a /models/. /wm-models/
              test -f /wm-models/vjepa.engine
              test -f /wm-models/siglip_text.engine
              test -f /wm-models/pca_basisA.bin
              test -f /wm-models/spiece.model
              test -f /wm-models/registry.json
          volumeMounts:
            - name: models
              mountPath: /wm-models
          resources:
            requests: { cpu: "500m", memory: "256Mi" }
            limits:   { cpu: "500m", memory: "256Mi" }

      containers:
        - name: wm-inference
          image: localhost:5443/wm-inference:PLACEHOLDER
          imagePullPolicy: IfNotPresent
          # Shell-default wrapper: per-host WM_* come from the wm-inference-config
          # ConfigMap via envFrom when present; the ${VAR:-default} fallbacks let
          # the pod boot before bootstrap's wm-config phase applies the CM. exec
          # so wm_inference_main becomes PID 1 for clean SIGTERM handling.
          command:
            - /bin/sh
            - -c
            - |
              export WM_CAMERA_ID="${WM_CAMERA_ID:-0}"
              export WM_BASE_SHA="${WM_BASE_SHA:-33cc3ad3ab7cfc92f8eb4cf177ba552680e2def6}"
              export WM_TASK_IDS="${WM_TASK_IDS:-honda_reach_insert,honda_rehome}"
              export WM_PREDICTOR_ENGINES="${WM_PREDICTOR_ENGINES:-/wm-models/honda_reach_insert.engine,/wm-models/honda_rehome.engine}"
              export WM_FRESHNESS_MS="${WM_FRESHNESS_MS:-200}"
              exec /opt/wm-inference/build/wm_inference_main
          envFrom:
            - configMapRef:
                name: wm-inference-config
                optional: true
          env:
            # Static image-contract paths into the staged emptyDir + GPU gating.
            # NOT in the ConfigMap (kept off envFrom so there's no precedence
            # interaction with the per-host overrides).
            - { name: WM_VJEPA_ENGINE,            value: /wm-models/vjepa.engine }
            - { name: WM_SIGLIP_ENGINE,           value: /wm-models/siglip_text.engine }
            - { name: WM_PCA_PATH,                value: /wm-models/pca_basisA.bin }
            - { name: WM_SPM_PATH,                value: /wm-models/spiece.model }
            - { name: WM_REGISTRY,                value: /wm-models/registry.json }
            - { name: WM_READY_FILE,              value: /tmp/wm_ready }
            - { name: WM_METRICS_PATH,            value: /tmp/wm_metrics.json }
            - { name: NVIDIA_VISIBLE_DEVICES,     value: all }
            - { name: NVIDIA_DRIVER_CAPABILITIES, value: all }
          startupProbe:
            exec: { command: ["/bin/sh", "-c", "test -f /tmp/wm_ready"] }
            initialDelaySeconds: 5
            periodSeconds: 10
            failureThreshold: 30
          readinessProbe:
            exec: { command: ["/bin/sh", "-c", "test -f /tmp/wm_ready"] }
            initialDelaySeconds: 5
            periodSeconds: 5
            failureThreshold: 3
          livenessProbe:
            exec:
              command:
                - /bin/sh
                - -c
                - test "$(( $(date +%s) - $(stat -c %Y /tmp/wm_metrics.json 2>/dev/null || echo 0) ))" -lt 40
            initialDelaySeconds: 20
            periodSeconds: 15
            failureThreshold: 3
          securityContext:
            privileged: true   # /dev GPU + camera device nodes
          resources:
            requests: { cpu: "2", memory: 2Gi }
            limits:   { cpu: "4", memory: 4Gi }
          volumeMounts:
            - { name: models,  mountPath: /wm-models, readOnly: true }
            - { name: shm,     mountPath: /dev/shm }
            - { name: dev,     mountPath: /dev }

      volumes:
        - name: models
          emptyDir: {}
        - name: shm
          hostPath: { path: /dev/shm, type: Directory }
        - name: dev
          hostPath: { path: /dev,     type: Directory }
```

- [ ] **Step 2: Write `kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
# wm-inference DaemonSet — gated on foundation.bot/has-wm-inference. Mutually
# exclusive with positronic-control, phantom-locomotion, and phantom-sonic
# (host-config validator enforces). See wm-inference.yaml for full design notes.
resources:
  - wm-inference.yaml
```

- [ ] **Step 3: Validate the kustomization builds**

Run: `kubectl kustomize manifests/base/wm-inference` (or `kustomize build manifests/base/wm-inference`)
Expected: emits the DaemonSet YAML, no errors.

- [ ] **Step 4: Dry-run schema check**

Run: `kubectl kustomize manifests/base/wm-inference | kubectl apply --dry-run=client -f -`
Expected: `daemonset.apps/wm-inference created (dry run)`, no schema errors.
(If no cluster is reachable, `kubectl apply --dry-run=client` still validates schema offline.)

- [ ] **Step 5: Commit**

```bash
git add manifests/base/wm-inference/
git commit -m "feat(wm-inference): base DaemonSet manifest + kustomization"
```

### Task 2.2: Add `wm-inference` to the core stack

**Files:**
- Modify: `manifests/stacks/core/kustomization.yaml`

- [ ] **Step 1: Add the resource**

In `manifests/stacks/core/kustomization.yaml`, under `resources:`, after the `phantom-sonic` line (or after the last `../../base/...` entry), add:

```yaml
  - ../../base/wm-inference
```

- [ ] **Step 2: Validate the whole core stack still builds**

Run: `kubectl kustomize manifests/stacks/core | grep -c "kind: DaemonSet"`
Expected: count increased by 1 vs before; no build errors.
Also confirm the new DS is present:
Run: `kubectl kustomize manifests/stacks/core | grep -A2 "name: wm-inference"`
Expected: shows the wm-inference DaemonSet.

- [ ] **Step 3: Commit**

```bash
git add manifests/stacks/core/kustomization.yaml
git commit -m "feat(wm-inference): include wm-inference in the core stack"
```

---

## Phase 3 — Bootstrap `wm-config` phase

Mirror `sonic_config()`. The phase renders `/etc/phantomos/wm-inference-config.yaml` from `worldModel` and applies it; host-resident, ArgoCD-unmanaged, `--reset`-preserved.

### Task 3.1: Add the `wm-config` phase plumbing (flag, skip, dispatch)

**Files:**
- Modify: `scripts/bootstrap-robot.sh`

- [ ] **Step 1: Add the opt-in flag parse**

In `scripts/bootstrap-robot.sh`, after the line `--sonic-config)      SELECTED_PHASES+=(sonic-config); shift ;;` add:

```bash
    --wm-config)         SELECTED_PHASES+=(wm-config); shift ;;
```

- [ ] **Step 2: Add the SKIP default**

After the line `SKIP_SONIC_CONFIG=0` add:

```bash
SKIP_WM_CONFIG=0
```

- [ ] **Step 3: Default-off when running a selected subset**

In the block that sets each `SKIP_*=1` when `SELECTED_PHASES` is non-empty (where `SKIP_SONIC_CONFIG=1` is set, ~L611), add alongside it:

```bash
  SKIP_WM_CONFIG=1
```

- [ ] **Step 4: Re-enable when explicitly selected**

In the `for _p in "${SELECTED_PHASES[@]}"` case (where `sonic-config) SKIP_SONIC_CONFIG=0 ;;` is, ~L637) add:

```bash
      wm-config)         SKIP_WM_CONFIG=0 ;;
```

- [ ] **Step 5: Syntax check + commit**

Run: `bash -n scripts/bootstrap-robot.sh`
Expected: no output (syntax OK).

```bash
git add scripts/bootstrap-robot.sh
git commit -m "feat(wm-inference): add --wm-config bootstrap phase plumbing"
```

### Task 3.2: Implement `wm_config()` and call it

**Files:**
- Modify: `scripts/bootstrap-robot.sh`

- [ ] **Step 1: Add the `wm_config` function**

In `scripts/bootstrap-robot.sh`, immediately after the `sonic_config()` function's closing brace (~L2602), add:

```bash
# ---- phase: wm-config (wm-inference-config ConfigMap) ----------------

# Per-host wm-inference options file. Holds a ConfigMap manifest the
# wm-inference container reads via envFrom. Same host-resident,
# ArgoCD-unmanaged, --reset-preserved lifecycle as the sonic/locomotion CMs.
WM_FILE="${WM_FILE:-/etc/phantomos/wm-inference-config.yaml}"
WM_NS="positronic"
WM_CM_NAME="wm-inference-config"

_write_wm_file() {
  local kv_text="${1?_write_wm_file: kv_text required}"
  mkdir -p "$(dirname "$WM_FILE")"
  {
    cat <<EOF
# Generated by scripts/bootstrap-robot.sh — do not hand-edit.
# Re-run bootstrap with --wm-config to change these values.
apiVersion: v1
kind: ConfigMap
metadata:
  name: $WM_CM_NAME
  namespace: $WM_NS
data:
EOF
    local line key value
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      key="${line%%=*}"
      value="${line#*=}"
      printf '  %s: "%s"\n' "$key" "$value"
    done <<<"$kv_text"
  } > "$WM_FILE"
  chmod 0644 "$WM_FILE"
}

wm_config() {
  if [ "${SKIP_WM_CONFIG:-0}" = 1 ]; then
    phase "phase: wm-config  (skipped)"
    return
  fi
  phase "phase: wm-config (wm-inference-config ConfigMap)"

  local hc="$HOST_CONFIG_FILE"
  if [ "$DRY_RUN" = 1 ] && [ ! -r "$hc" ] && [ -n "$HOST_CONFIG_INPUT" ] && [ -r "$HOST_CONFIG_INPUT" ]; then
    hc="$HOST_CONFIG_INPUT"
  fi

  local kv_text=""
  if [ -r "$hc" ]; then
    kv_text=$(python3 "$HOST_CONFIG_HELPER" "$hc" get-world-model-config-kv 2>/dev/null || true)
  fi
  if [ -z "$kv_text" ]; then
    # Helper failed (no host-config, validation error, etc.) — fall back to the
    # documented defaults so the pod still starts. Keep in sync with
    # DEFAULT_WORLD_MODEL_* in scripts/lib/host-config.py and the manifest's
    # shell-defaults.
    kv_text="WM_CAMERA_ID=0
WM_BASE_SHA=33cc3ad3ab7cfc92f8eb4cf177ba552680e2def6
WM_FRESHNESS_MS=200
WM_TASK_IDS=honda_reach_insert,honda_rehome
WM_PREDICTOR_ENGINES=/wm-models/honda_reach_insert.engine,/wm-models/honda_rehome.engine"
  fi

  local cam_line cam
  cam_line=$(printf '%s\n' "$kv_text" | grep -m1 '^WM_CAMERA_ID=' || true)
  cam="${cam_line#WM_CAMERA_ID=}"

  if [ "$DRY_RUN" = 1 ]; then
    info "DRY-RUN  write $WM_FILE  WM_CAMERA_ID=$cam"
    info "DRY-RUN  kubectl apply -f $WM_FILE"
    return
  fi

  if [ ${#KUBECTL[@]} -eq 0 ]; then
    fail "no kubectl/k0s available — cannot apply wm-inference ConfigMap"
    return
  fi

  if ! "${KUBECTL[@]}" get ns "$WM_NS" >/dev/null 2>&1; then
    if ! "${KUBECTL[@]}" create ns "$WM_NS" >/dev/null; then
      fail "could not create ns/$WM_NS"
      return
    fi
    info "created ns/$WM_NS"
  fi

  _write_wm_file "$kv_text"
  pass "wrote $WM_FILE  WM_CAMERA_ID=$cam"

  if ! "${KUBECTL[@]}" apply -f "$WM_FILE" >/dev/null; then
    fail "kubectl apply -f $WM_FILE"
    return
  fi
  pass "$WM_CM_NAME applied to $WM_NS"

  if "${KUBECTL[@]}" -n "$WM_NS" get ds wm-inference >/dev/null 2>&1; then
    if "${KUBECTL[@]}" -n "$WM_NS" rollout restart ds/wm-inference >/dev/null; then
      pass "rolled out wm-inference DaemonSet to pick up new options"
    else
      fail "rollout restart ds/wm-inference"
    fi
  else
    info "ds/wm-inference not present yet — gitops phase will create it with the new CM in scope"
  fi
}
```

- [ ] **Step 2: Call it in the run list**

In the phase run list at the bottom (where `sonic_config ; guard` is, ~L5644), add immediately after it:

```bash
wm_config          ; guard
```

- [ ] **Step 3: Document the flag in the header comment**

In the per-phase flag comment block near the top (where `--sonic-config` is documented, ~L55), add a sibling line:

```bash
#   --wm-config          render+apply the wm-inference-config ConfigMap
#                        (camera id, base sha, freshness, task<->engine
#                        pairs; sourced from host-config worldModel block).
```

- [ ] **Step 4: Syntax check + dry-run**

Run: `bash -n scripts/bootstrap-robot.sh`
Expected: no output.
Run (dry-run the single phase against a sample host-config):
```bash
cat > /tmp/wm-hc.yaml <<'YAML'
robot: testbot
worldModel:
  cameraId: 4
  tasks:
    - {id: pick, engine: pick.engine}
YAML
DRY_RUN=1 bash scripts/bootstrap-robot.sh --host-config /tmp/wm-hc.yaml --wm-config 2>&1 | grep -i "wm-config\|WM_CAMERA_ID"
```
Expected: shows `phase: wm-config ...` and `DRY-RUN write /etc/phantomos/wm-inference-config.yaml WM_CAMERA_ID=4`.
(Flags/var names for the dry-run invocation may differ — mirror exactly how the repo's docs invoke `--sonic-config` dry-runs; the assertion is that the wm-config phase fires and reads `WM_CAMERA_ID=4`.)

- [ ] **Step 5: Commit**

```bash
git add scripts/bootstrap-robot.sh
git commit -m "feat(wm-inference): wm-config bootstrap phase renders wm-inference-config CM"
```

---

## Phase 4 — `positronic.sh` convenience commands

Add a `wm` subcommand group mirroring `sonic`.

### Task 4.1: Add the `wm` group + dispatch

**Files:**
- Modify: `scripts/positronic.sh`

- [ ] **Step 1: Add the config constants**

In `scripts/positronic.sh`, near the sonic constants (`SONIC_NAMESPACE` / `SONIC_APP_LABEL` / `SONIC_CONTAINERS`, ~L38), add:

```bash
# wm-inference DaemonSet (World-Model brain) — one pod in the positronic
# namespace. The `wm` subcommand group wraps kubectl with the right ns/label.
WM_NAMESPACE="${WM_NAMESPACE:-positronic}"
WM_APP_LABEL="${WM_APP_LABEL:-app.kubernetes.io/name=wm-inference}"
WM_CONTAINERS="wm-inference"   # action-solver appended here when it ships
```

- [ ] **Step 2: Add the `wm` command functions**

After the `cmd_sonic()` dispatch function (~L755), add:

```bash
# ---------- subcommand: wm (wm-inference) ---------------------------------
_wm_pod() {
  $KUBECTL -n "$WM_NAMESPACE" get pod -l "$WM_APP_LABEL" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

_wm_valid_container() {
  case " $WM_CONTAINERS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

cmd_wm_status() {
  require_kubectl
  bold "DaemonSet ($WM_NAMESPACE/wm-inference)"
  if ! $KUBECTL -n "$WM_NAMESPACE" get ds wm-inference >/dev/null 2>&1; then
    fail "DaemonSet wm-inference not found in $WM_NAMESPACE — not deployed"
    info "is foundation.bot/has-wm-inference=true on this node? (mutually exclusive with has-positronic/has-locomotion/has-sonic)"
    return 1
  fi
  $KUBECTL -n "$WM_NAMESPACE" get ds wm-inference -o wide 2>/dev/null | sed 's/^/    /'
  local pod; pod="$(_wm_pod)"
  if [ -z "$pod" ]; then
    warn "no wm-inference pod scheduled yet"
    return 0
  fi
  $KUBECTL -n "$WM_NAMESPACE" get pod "$pod" -o wide 2>/dev/null | sed 's/^/    /'
  $KUBECTL -n "$WM_NAMESPACE" get pod "$pod" -o jsonpath='{range .status.containerStatuses[*]}    {.name}{"  ready="}{.ready}{"  restarts="}{.restartCount}{"\n"}{end}' 2>/dev/null
}

cmd_wm_logs() {
  require_kubectl
  local container="" follow="" previous=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -f|--follow)   follow="-f"; shift ;;
      --previous)    previous="--previous"; shift ;;
      -h|--help)     echo "wm logs [<container>] [-f|--follow] [--previous]   (container: $WM_CONTAINERS)"; return 0 ;;
      *)             container="$1"; shift ;;
    esac
  done
  local pod; pod="$(_wm_pod)"
  [ -n "$pod" ] || die "no wm-inference pod found (label=$WM_APP_LABEL ns=$WM_NAMESPACE)"
  local args=(-n "$WM_NAMESPACE" logs "$pod")
  if [ -n "$container" ]; then
    _wm_valid_container "$container" || die "unknown container: $container (one of: $WM_CONTAINERS)"
    args+=(-c "$container")
  fi
  [ -n "$follow" ]   && args+=("$follow")
  [ -n "$previous" ] && args+=("$previous")
  exec $KUBECTL "${args[@]}"
}

cmd_wm_exec() {
  require_kubectl
  local container="$1"; shift || true
  [ -n "$container" ] || container="wm-inference"
  _wm_valid_container "$container" || die "unknown container: $container (one of: $WM_CONTAINERS)"
  [ "${1:-}" = "--" ] && shift
  local pod; pod="$(_wm_pod)"
  [ -n "$pod" ] || die "no wm-inference pod found (label=$WM_APP_LABEL ns=$WM_NAMESPACE)"
  if [ $# -eq 0 ]; then
    exec $KUBECTL -n "$WM_NAMESPACE" exec -it "$pod" -c "$container" -- /bin/sh
  fi
  exec $KUBECTL -n "$WM_NAMESPACE" exec -it "$pod" -c "$container" -- "$@"
}

cmd_wm_restart() {
  require_kubectl
  $KUBECTL -n "$WM_NAMESPACE" rollout restart ds/wm-inference && ok "restarted ds/wm-inference"
}

cmd_wm() {
  local action="${1:-status}"; shift || true
  case "$action" in
    status)  cmd_wm_status  "$@" ;;
    logs)    cmd_wm_logs    "$@" ;;
    exec)    cmd_wm_exec    "$@" ;;
    restart) cmd_wm_restart "$@" ;;
    -h|--help|help)
      echo "wm <action> [args...]   actions: status | logs [<c>] [-f] | exec [<c>] [-- cmd] | restart"
      echo "                        containers: $WM_CONTAINERS" ;;
    *) die "unknown wm action: $action (status|logs|exec|restart)" ;;
  esac
}
```

- [ ] **Step 3: Wire the dispatch**

In the main `case "$sub" in` block (~L1335), after the `sonic) cmd_sonic "$@" ;;` line add:

```bash
  wm)             cmd_wm             "$@" ;;
```

- [ ] **Step 4: Add to the help text**

In `cmd_help()` (~L204, near the `sonic <action>` help line) add:

```bash
  wm <action> [args...]        Helpers for the wm-inference DaemonSet
                               (World-Model brain). status | logs | exec |
                               restart. 'wm --help' for details.
```

- [ ] **Step 5: Syntax check, dry-run, commit**

Run: `bash -n scripts/positronic.sh`
Expected: no output.
Run: `bash scripts/positronic.sh --dry-run wm restart` (or `wm --help`)
Expected: prints the rollout-restart kubectl line / help without error.

```bash
git add scripts/positronic.sh
git commit -m "feat(wm-inference): positronic.sh wm subcommand group (status/logs/exec/restart)"
```

---

## Phase 5 — Documentation

### Task 5.1: Document the host-config surface in the template

**Files:**
- Modify: `host-config-templates/_template/host-config.yaml`

- [ ] **Step 1: Document the node label**

In the `nodeLabels:` block, after the `foundation.bot/has-sonic` line, add:

```yaml
  # wm-inference DaemonSet (World-Model brain; mutually exclusive with
  # has-positronic / has-locomotion / has-sonic)
  foundation.bot/has-wm-inference: 'false'
```

- [ ] **Step 2: Document the two image keys**

In the `images:` "Known containers" comment block, after the `phantom-motion-replay` entry, add:

```
#   wm-inference           core stack — World-Model inference DaemonSet
#                          (has-wm-inference gated). manifest uses
#                          localhost:5443/wm-inference; published as
#                          foundationbot/wm-inference (arm64/Thor engines).
#   wm-inference-models    core stack — wm-inference's model-loader init.
#                          Immutable data-image with engines/PCA/tokenizer/
#                          registry. manifest uses localhost:5443/wm-inference-models.
```

- [ ] **Step 3: Document the `worldModel:` block + 4-way exclusion**

After the `phantomSonic:` documentation block, add a `worldModel:` section:

```yaml
# Per-host wm-inference config (the World-Model brain, gated on
# foundation.bot/has-wm-inference). Bootstrap phase wm-config renders
# /etc/phantomos/wm-inference-config.yaml from this block — a ConfigMap the
# wm-inference container consumes via envFrom. Same host-resident,
# ArgoCD-unmanaged, --reset-preserved lifecycle as phantom-sonic-config; a
# bare or absent worldModel block still renders a working ConfigMap (the
# manifest carries matching shell-defaults).
#
# Fields (all optional; defaults shown):
#   cameraId:    0          # WM_CAMERA_ID  (0..5 board/eye index)
#   baseSha:     33cc3ad3…  # WM_BASE_SHA   (sha1(base ckpt)[:40])
#   freshnessMs: 200        # WM_FRESHNESS_MS
#   tasks:                  # id<->engine pairs; engine is a BARE filename
#                           # (staged under /wm-models by the model-loader).
#                           # Derives WM_TASK_IDS + WM_PREDICTOR_ENGINES.
#     - {id: honda_reach_insert, engine: honda_reach_insert.engine}
#     - {id: honda_rehome,       engine: honda_rehome.engine}
#
# worldModel:
#   cameraId: 0
#   tasks:
#     - {id: honda_reach_insert, engine: honda_reach_insert.engine}
#     - {id: honda_rehome,       engine: honda_rehome.engine}
```

Also update the existing mutual-exclusion note (where it says positronic/locomotion/sonic) to include `has-wm-inference` as a fourth competing brain.

- [ ] **Step 4: Validate the template still parses**

Run: `python3 scripts/lib/host-config.py host-config-templates/_template/host-config.yaml validate`
Expected: validation passes (no errors) — or matches the repo's expected baseline for the template.

- [ ] **Step 5: Commit**

```bash
git add host-config-templates/_template/host-config.yaml
git commit -m "docs(wm-inference): document worldModel block, image keys, 4-way exclusion in template"
```

### Task 5.2: Runbook section in operations.md

**Files:**
- Modify: `docs/operations.md`

- [ ] **Step 1: Add a wm-inference section**

Mirror the structure of the existing phantom-sonic runbook section (added in PR #67). Cover: what it is (World-Model brain), how to enable it (set `has-wm-inference: 'true'` + `has-positronic: 'false'` etc., set `worldModel` + `images.wm-inference`/`wm-inference-models`, run `bootstrap --wm-config`), and the convenience commands:

```markdown
## wm-inference (World-Model brain)

The `wm-inference` DaemonSet runs the World-Model on-robot inference service
(`imu-policy/world-model/inference`). It is one of the mutually-exclusive
"control brains" — enabling it requires disabling positronic/locomotion/sonic.

**Enable on a robot** (`/etc/phantomos/host-config.yaml`):

    nodeLabels:
      foundation.bot/has-positronic: 'false'
      foundation.bot/has-locomotion: 'false'
      foundation.bot/has-sonic: 'false'
      foundation.bot/has-wm-inference: 'true'
    images:
      wm-inference:        { image: foundationbot/wm-inference:<tag> }
      wm-inference-models: { image: foundationbot/wm-inference-models:<tag> }
    worldModel:
      cameraId: 0
      tasks:
        - {id: honda_reach_insert, engine: honda_reach_insert.engine}
        - {id: honda_rehome,       engine: honda_rehome.engine}

Then: `sudo bash scripts/bootstrap-robot.sh --image-overrides --wm-config`
(re-run the relevant phases; ArgoCD syncs the DaemonSet).

**Operate:**

    bash scripts/positronic.sh wm status
    bash scripts/positronic.sh wm logs -f
    bash scripts/positronic.sh wm exec -- nvidia-smi
    bash scripts/positronic.sh wm restart
```

- [ ] **Step 2: Commit**

```bash
git add docs/operations.md
git commit -m "docs(wm-inference): operations runbook section"
```

---

## Phase 6 — Integration validation

### Task 6.1: Full-stack build + validate round-trip

**Files:** none (verification only)

- [ ] **Step 1: Core stack builds with wm-inference present**

Run: `kubectl kustomize manifests/stacks/core | kubectl apply --dry-run=client -f -`
Expected: all resources validate, including `daemonset.apps/wm-inference (dry run)`.

- [ ] **Step 2: End-to-end host-config round-trip (enabled robot)**

```bash
cat > /tmp/wm-enabled.yaml <<'YAML'
robot: wmbot
aiPcUrl: http://10.0.0.2:5000
nodeLabels:
  foundation.bot/has-positronic: 'false'
  foundation.bot/has-locomotion: 'false'
  foundation.bot/has-sonic: 'false'
  foundation.bot/has-wm-inference: 'true'
images:
  wm-inference:        { image: foundationbot/wm-inference:v1.0.0 }
  wm-inference-models: { image: foundationbot/wm-inference-models:v1.0.0 }
worldModel:
  cameraId: 2
  tasks:
    - {id: pick, engine: pick.engine}
YAML
python3 scripts/lib/host-config.py /tmp/wm-enabled.yaml validate
python3 scripts/lib/host-config.py /tmp/wm-enabled.yaml get-world-model-config-kv
python3 scripts/lib/host-config.py /tmp/wm-enabled.yaml get-images-json
```
Expected: `validate` passes; KV shows `WM_CAMERA_ID=2`, `WM_TASK_IDS=pick`, `WM_PREDICTOR_ENGINES=/wm-models/pick.engine`; images JSON contains the wm-inference + wm-inference-models rewrites.

- [ ] **Step 3: Negative case — exclusion fires**

```bash
cat > /tmp/wm-bad.yaml <<'YAML'
robot: wmbot
nodeLabels:
  foundation.bot/has-wm-inference: 'true'
YAML
python3 scripts/lib/host-config.py /tmp/wm-bad.yaml validate; echo "rc=$?"
```
Expected: nonzero rc; error names `has-wm-inference` and tells the operator to set `has-positronic: "false"`.

- [ ] **Step 4: Full python test sweep (no regressions)**

Run: `python3 -m pytest scripts/lib/ -v`
Expected: all pass, including the existing sonic/locomotion/okvis/SE tests.

- [ ] **Step 5: Final commit (if any verification tweaks were needed)**

```bash
git add -A
git commit -m "test(wm-inference): integration validation round-trip" || echo "nothing to commit"
```

---

## Self-Review (completed at authoring)

- **Spec coverage:** every design section maps to a task — manifests (Ph2), node label/images/config/exclusion in host-config.py (Ph1), bootstrap phase (Ph3), positronic.sh (Ph4), template + ops docs (Ph5), integration (Ph6). The action-solver "slot" is documented-only in 2.1 per the design (no image yet).
- **Type/name consistency:** `worldModel` (block) → `wm-inference-config` (CM) → `WM_*` env → `get-world-model-config-kv` (CLI) → `wm_config()`/`--wm-config` (bootstrap) → `wm` (positronic.sh) → `wm-inference`/`wm-inference-models` (image keys) used identically across all phases. Engine values are bare filenames everywhere; `/wm-models/` is prefixed only in the emitter and the manifest defaults.
- **Open flags surfaced:** (a) config-delivery deviates from the brainstorm summary to sonic-style — called out at top + design §6; (b) `validate()` entrypoint name must be confirmed in Task 1.5 Step 1; (c) exact dry-run invocation flags for bootstrap mirror the repo's `--sonic-config` examples.
