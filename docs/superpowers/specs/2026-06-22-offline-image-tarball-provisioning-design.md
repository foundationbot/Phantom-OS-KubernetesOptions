# Offline image-tarball provisioning

**Date:** 2026-06-22
**Status:** approved, in implementation
**Branch:** `feat/offline-image-tarball-provisioning`

## Problem

`phantom-models` and `phantom-policies` are locally-built busybox carrier
images pinned to `localhost:5443/*` (no DockerHub upstream, no containerd
mirror fallthrough). Today the only in-tree ways to get them onto a robot
are (a) build them in-place (`build-images-deb.sh` / phase 17
`setup-positronic` for models; nothing for policies) or (b) the full
`phantomos-k0s-images` `.deb` bundle. An operator who has already built the
images on one robot and `docker save`d them to tarballs (operations §3.13)
has no scripted way to load+push them onto other robots and wire the tag
into `host-config.yaml`. This adds that path.

## Requirements

- Optional: a robot that needs none of this sees no behaviour change.
- Accept prebuilt `phantom-models` and `phantom-policies` tarballs only
  (positronic-control keeps its existing `--positronic-image` push path).
- On a TTY, *ask* for the tarball paths; in non-interactive runs act only
  on explicit flags.
- Load + push the tarball's `localhost:5443/*` tag into the in-cluster
  registry, then update `host-config.yaml`'s `images:` block so the
  manifests actually use the loaded tag, and make that change live.

## Components (each single-purpose, disjoint files)

### A. `scripts/load-image-tars.sh` (new)

Scripted form of operations §3.13 step 3. Pure registry op — no
host-config knowledge, usable off-robot.

```
scripts/load-image-tars.sh [--dry-run] <tarball> [<tarball> ...]
```

Per tarball:
1. Validate path readable.
2. Decompress by extension: `.tar` → load directly; `.tar.gz`/`.tgz` →
   `docker load` (native gzip); `.tar.zst` → `zstd -dc | docker load`.
3. Capture loaded ref(s) from `docker load` output
   (`Loaded image: localhost:5443/phantom-models:2026-06-08`).
4. **Guard:** a loaded ref that is not `localhost:5443/*` → warn and skip
   its push (the registry pod only serves that prefix).
5. `docker push <ref>` for each `localhost:5443/*` ref.
6. Print the resulting `localhost:5443/<name>:<tag>` (stdout, parseable)
   so callers can wire the tag.

Preconditions/behaviour: requires `docker`; checks `http://localhost:5443/v2/`
reachable and fails clearly if the registry pod is down. Idempotent.
Exit code = number of failures. Honours `--dry-run`. Output helpers match
`install-image-bundle.sh` style. On `--dry-run`, prints the load/push it
*would* run and (where determinable) the ref, without invoking docker.

Out of scope (YAGNI): does NOT edit `host-config.yaml`.

### B. `scripts/lib/host-config.py` — new `set-image` setter

```
host-config.py <path> set-image <container> <ref>
```

Sets `images.<container>.image: <ref>`, following the comment-preserving
in-place text-edit convention of `cmd_set_positronic_launch_command`
(three cases: key exists → replace value; `images:` block exists without
the key → insert; no `images:` block → append). Validates `<container>`
against `CONTAINER_TARGETS`; rejects a non-`localhost:5443/*` ref for
`phantom-models`/`phantom-policies`. Wire into the `__main__` dispatch
next to the other `set-*` subcommands. Add a pytest in `scripts/lib/`
covering the three insert cases + the validation rejection (TDD).

### C. `scripts/bootstrap-robot.sh` — new phase `load-image-tars`

- Selectable via `--load-image-tars`; flags `--phantom-models-tar <path>`,
  `--phantom-policies-tar <path>`.
- **Placement:** after `gitops` (13), before `image-overrides` (15). Do
  NOT renumber existing phases — add a named function, a `print_plan`
  line, and the skip flag in the same style as the other phases.
- Waits for the `k0s-registry` Deployment to become Available (reuse the
  wait logic from `validate-local-registry.sh`); soft-skip if it never
  comes up (do not fail the whole bootstrap).
- Trigger logic:
  - Non-interactive (`-y`, selected-phases mode, or no TTY): act only on
    the two flags; if neither set, skip silently with an info line.
  - Interactive TTY full bootstrap: prompt per image
    (`phantom-models tarball path? [Enter to skip]`, then policies).
    A flag pre-fills and suppresses the matching prompt.
- For each provided tarball: call `scripts/load-image-tars.sh <tar>`,
  capture the pushed `localhost:5443/<name>:<tag>`, then
  `host-config.py set-image <container> <ref>` (the flag tells it which
  container; the tag comes from the load output).
- Making it live: because the phase runs before `image-overrides`, the
  unchanged `image_overrides` phase injects the new tags into the core
  Argo app — no duplicated injection logic. In a selected-phase run
  (`--load-image-tars` alone, implies `-y`) `image-overrides` won't run,
  so after editing host-config the phase prints:
  *"host-config updated; run `--image-overrides` to apply (automatic in a
  full bootstrap)."*
- Error handling: registry down → soft-skip with guidance; a tarball that
  fails load/push → `fail` that image, continue, report the count.

### D. Docs — `docs/operations.md`

- (Re-)add **§3.13** "Copy a locally-built image to other robots (offline
  tar transfer)" — the manual `docker save`/scp/`docker load`+push flow,
  arch warning, skopeo fallback, registry-tag verification, and the
  offline `/var/lib/k0s/images` auto-import alternative with its caveat.
- Note in §3.13 that step 3 is automated by `scripts/load-image-tars.sh`
  and the `--load-image-tars` bootstrap phase.
- Add `--load-image-tars`, `--phantom-models-tar`, `--phantom-policies-tar`
  to the phase reference table (§4) and the cheat sheet (§5).

## Testing

- `host-config.py set-image`: pytest (three insert cases + rejection).
- `load-image-tars.sh`: `--dry-run` subprocess test (arg parsing,
  extension dispatch, non-`localhost:5443` guard); `shellcheck` clean.
- Manual smoke on `mk11000009` with the two tarballs already pulled.

## Non-goals

- No change to the positronic default-image decision (separate thread).
- No auto-editing of host-config by the standalone script.
- positronic-control tarball provisioning (only models + policies).
