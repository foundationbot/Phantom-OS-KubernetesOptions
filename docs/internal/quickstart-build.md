# Quick start — build the Phantom-OS .deb packages

> **CONFIDENTIAL.** This document and any corresponding documents shared
> in this drive contain highly sensitive confidential information of
> Foundation, including proprietary technical information that is
> strictly restricted. Please handle in accordance with the NDA, do not
> forward, and limit access to specifically authorized individuals only.

For developers and CI building installable artifacts. Produces three
files a fresh robot needs: one control-plane `.deb` and the image-bundle
pair (a small `.deb` + a multi-GB `.tar.zst` sidecar).

If you are installing on a robot, see `docs/quickstart-install.md` instead.

---

## Before you start

### System requirements

- **Linux build host** (Ubuntu 22.04+ or similar) with docker daemon running.
- **About 50 GB free disk** for the image cache + .deb output.
- **Network + DockerHub authentication** for the private `foundationbot/*` images:
  ```bash
  docker login -u <your-user>
  ```
- **Standard tools**:
  ```bash
  sudo apt install -y docker.io dpkg rsync zstd git python3
  ```

### Source checkout

```bash
git clone git@github.com:foundationbot/Phantom-OS-KubernetesOptions.git
cd Phantom-OS-KubernetesOptions
git switch <branch>     # main for production; or a release branch
```

### Where the image list comes from (host-config by default)

`build-images-deb.sh` builds the bundle for **what a robot actually
deploys**. By default it reads the build host's system host-config
(`/etc/phantomos/host-config.yaml`) and merges its `images:` block over
the manifest scan:

- **Exact deployed tags** — host-config carries the per-host overrides
  (e.g. `positronic-control → foundationbot/phantom-cuda:0.2.48-…`,
  `vr-web → …:<sha>-arm64`), which the manifest scan's in-repo defaults
  would miss. Host-config wins per repo.
- **Every `localhost:5443/*` local image** — `phantom-models`,
  `phantom-policies`, and any stack-specific locals (`psi0-policy`,
  `psi0-sonic`, `phantom-loco`, …) are discovered straight from the
  block; no per-image flags.

**So build on a configured robot** (or any host with the target's
host-config) to get the right set. The `localhost:5443/*` refs must be
present in that host's `docker images` (they're `docker save`d straight
from the daemon — they don't exist on DockerHub); the `foundationbot/*`
refs are pulled. Preview the resolved set without building:

```bash
bash scripts/build-images-deb.sh --arch arm64 --list
```

**Off-robot / CI builds** (no host-config): pass `--no-host-config` to
fall back to a manifest-scan-only build, and supply any local images
explicitly with `--positronic-image` / `--phantom-models-image`. Or
point at a specific file with `--host-config <path>`.

---

## Steps

### 1. Build the control-plane `.deb`

```bash
bash scripts/build-deb.sh
```

Produces `dist/phantomos-k0s-<version>-all.deb`. Contents:

- `scripts/` and `manifests/` under `/opt/Phantom-OS-KubernetesOptions/`.
- A git repository at `/opt/.../.git/` (RFC 0006) — ArgoCD's local-git
  source. About 1 MB packed.
- `packaging/deb/postinst` — warns when an operator hand-modified the
  installed tree between installs.

Version auto-derived from `version.txt` + `git rev-parse --short HEAD`,
with `+dirty` appended if the working tree has uncommitted changes.

### 2. Build the image bundle (`.deb` + sidecar `.tar.zst`)

On a configured robot, no per-image flags are needed — host-config
supplies the full set at exact tags:

```bash
bash scripts/build-images-deb.sh --arch arm64 --no-prompt
```

Useful options:

- `--exclude '<glob>'` (repeatable) — drop refs, e.g.
  `--exclude 'localhost:5443/psi0-*'` to skip the large psi0 models.
- `--list` — print the resolved pullable + local-save set and exit
  (preview before a multi-GB build).
- `--no-host-config` / `--host-config <path>` — see the discovery
  section above.
- `--arch arm64` / `--arch amd64,arm64` — narrow or widen the arches.

Produces **two** artifacts per arch in `dist/`:

- `phantomos-k0s-images-<version>-<arch>.deb` — small (~5–10 KB). Bundle
  manifest YAML + postinst. Tells the robot what tarballs to expect and
  how to import them.
- `phantomos-k0s-images-<version>-<arch>.tar.zst` — multi-GB (tens of GB
  with the CUDA images). Every image tarball, zstd-compressed.

Why two files? See RFC 0007 — the `.deb` `ar` format caps individual
archive members at ~9.3 GB; the phantom-cuda CUDA image alone is far
larger. The sidecar `.tar.zst` escapes the cap.

A `.report.txt` is written next to each `.deb` listing every included
image (with size) and any skipped one (with the reason) — check it after
the build.

### 3. Inspect what's in the bundle (recommended)

```bash
# bundle manifest — what canonical containers the bundle satisfies
mkdir -p /tmp/inspect && dpkg-deb -x dist/phantomos-k0s-images-*-amd64.deb /tmp/inspect
cat /tmp/inspect/var/lib/k0s/images/.phantomos-image-bundle.yaml

# sidecar tarball list (first 25 lines)
tar -I 'zstd -d' -tf dist/phantomos-k0s-images-*-amd64.tar.zst | head -25
```

With a host-config-driven build the bundle manifest records an entry for
**every deployed container** it can name — both the local images and the
host-config-overridden pullables (`positronic-control`, `dma-bridge`,
`cpp-robot-state-estimator`, `dma-streams`, `phantom-locomotion`,
`phantom-motion-replay`, `vr-web`, `yovariable-server`, plus
`phantom-models`/`phantom-policies` and any psi0 locals). The wizard's
auto-images mode reads these on install to pre-fill **the whole image
override set** — no hand-typing, no release template needed.

`foundationbot/phantom-cuda` backs *two* containers (`positronic-control`
and `dma-bridge`); they're disambiguated by the host-config block keys
(distinct tags → distinct entries). Manifest-scan-only builds
(`--no-host-config`) still record just the repo-unambiguous canonical
containers.

The sidecar also contains the standard infrastructure tarballs not tied
to a container (mongo, nginx, redis, postgres, registry, alpine,
mediamtx, argus.*, nimbus.*) — bundled for offline import, simply not
listed in the manifest.

### 4. Transfer to the robot

```bash
scp dist/phantomos-k0s-*-all.deb           robot:~/
scp dist/phantomos-k0s-images-*-amd64.deb  robot:~/
scp dist/phantomos-k0s-images-*-amd64.tar.zst robot:~/
```

All three files must land on the robot before install. The wrapper
script (`install-image-bundle.sh` on the robot side) auto-discovers the
matching pair from a directory.

### 5. Hand off

Point the robot operator at `docs/quickstart-install.md`. Confirm the
filenames they have match your build's `<version>` and `<arch>` — the
install wrapper refuses to install a `.deb` + sidecar pair whose
filename stems disagree.

---

## Multi-arch builds

```bash
# default: both amd64 and arm64
bash scripts/build-images-deb.sh

# explicit narrow:
bash scripts/build-images-deb.sh --arch arm64
```

Cross-arch image pulls go through `docker pull --platform <arch>` and
require docker buildx (any modern docker has it; no qemu/binfmt needed
since the build only pulls and saves, never executes).

Each arch produces its own `.deb` + `.tar.zst` pair. `localhost:5443/*`
local images (from host-config, or the `--*-image` flags) only attach to
the build whose arch matches the local image; cross-arch local images
are silently skipped per-arch. Since most robots are single-arch, narrow
to `--arch <arch>` matching the build host.

---

## Cache management

Image tarballs are cached at `dist/build/image-cache/<arch>/`. Subsequent
builds reuse the cache for unchanged refs.

To force a re-pull (e.g. a `:latest` tag moved upstream):

```bash
rm dist/build/image-cache/amd64/<sanitized-ref>.tar
bash scripts/build-images-deb.sh ...
```

`localhost:5443/*` local images (from host-config or the `--*-image`
flags) are NOT cached — they're saved fresh from the local docker daemon
on every build, so a rebuild of a local image under the same tag gets
re-bundled correctly.

---

## Reproducibility

The build script writes the `.deb`'s bundle manifest with:

- `builtAt:` — ISO 8601 UTC timestamp of the build.
- `builderVersion:` — same string as the `.deb`'s `Version:` field.
- `arch:` — debian arch string (`amd64` / `arm64`).

The control-plane `.deb`'s embedded `.git/` is committed with a stable
author/email (`phantomos build <phantomos@foundation.bot>`) and the
commit message embeds the build version. Same source → same commit
SHA (modulo timestamp metadata).

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `required tool 'zstd' not found` | `sudo apt install zstd` |
| `--positronic-image <ref> not found in local docker daemon` | `docker pull` or `docker tag` the right image first |
| `pull access denied` against `foundationbot/*` | run `docker login` with the right PAT |
| `ar member size <N> too large` | You're on a pre-RFC-0007 branch. Pull `main` or a release branch ≥ rfc-0006-local-git-source. |
| `dpkg-deb: building package ... failed` (Stage 5) | Check `dist/build/<pkg>-<arch>/` for write permissions; the script removes + recreates this dir per build |

---

## What gets bundled (full list)

The build draws from three sources, merged (later wins per repo):

- **Manifest scan** (`source: manifest-scan`) — every `image:` in
  `manifests/` at its in-repo default tag, minus `*:PLACEHOLDER` and
  `localhost:5443/*` (don't exist upstream / are template placeholders).
  Covers the stack infra: `foundationbot/argus.*`,
  `foundationbot/dma-video`, `foundationbot/nimbus.*`,
  `phantomos-api-server`, `mongo`, `nginx`, `postgres`, `redis`,
  `registry`, `alpine`, `bluenviron/mediamtx`, etc.
- **`packaging/deb-images/extra-images.txt`** (`source: extra-images`) —
  refs not discoverable from `manifests/`, e.g. per-arch dma-ethercat.
- **System host-config** (`source: host-config`, default; disable with
  `--no-host-config`) — the `images:` block at **exact deployed tags**,
  overriding the manifest-scan default for the same repo, plus every
  `localhost:5443/*` local image. This is what makes the bundle match
  the robot it was built on.

`--from-file <list>` replaces the manifest scan + host-config merge with
an explicit list (still augmented by extra-images). `--exclude '<glob>'`
drops refs from the final set.
