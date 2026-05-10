# Quick start — build the Phantom-OS .deb packages

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

### Locally-built images

For full robot bringup the image bundle ships two images not on
DockerHub:

- **positronic-control** — built from the foundationbot positronic-control
  source repo. Typically tagged something like
  `foundationbot/phantom-cuda:0.2.46-dev.2-production-cu128` (the
  "phantom-cuda" repo name is a swap-repo alias; the manifest reference
  is `localhost:5443/positronic-control`).
- **phantom-models** — built via `scripts/phantom-models/build.py`,
  tagged like `localhost:5443/phantom-models:2026-05-09`.

Both must be present in `docker images` before step 2 below. Verify:

```bash
docker images foundationbot/phantom-cuda:<tag>
docker images localhost:5443/phantom-models:<tag>
```

The build script fails fast with a clear error if either is missing.

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

```bash
bash scripts/build-images-deb.sh \
  --arch amd64 \
  --positronic-image foundationbot/phantom-cuda:<tag> \
  --phantom-models-image localhost:5443/phantom-models:<tag>
```

Produces **two** artifacts in `dist/`:

- `phantomos-k0s-images-<version>-amd64.deb` — small (~10 KB). Just the
  bundle manifest YAML + postinst. Tells the robot what tarballs to
  expect and how to import them.
- `phantomos-k0s-images-<version>-amd64.tar.zst` — multi-GB (~15-18 GB
  on a typical fleet). All image tarballs (foundationbot/*, mongo,
  nginx, postgres, redis, plus the two `--*-image` refs).

Why two files? See RFC 0007 — the `.deb` `ar` format caps individual
archive members at ~9.3 GB; the phantom-cuda CUDA image alone is ~12 GB.
The sidecar `.tar.zst` escapes the cap.

Add `--no-prompt` to run non-interactively (CI). Add `--arch arm64` or
`--arch amd64,arm64` to build for Jetson hosts.

### 3. Inspect what's in the bundle (recommended)

```bash
# bundle manifest — what canonical containers the bundle satisfies
mkdir -p /tmp/inspect && dpkg-deb -x dist/phantomos-k0s-images-*-amd64.deb /tmp/inspect
cat /tmp/inspect/var/lib/k0s/images/.phantomos-image-bundle.yaml

# sidecar tarball list (first 25 lines)
tar -I 'zstd -d' -tf dist/phantomos-k0s-images-*-amd64.tar.zst | head -25
```

Bundle manifest should have four canonical entries:

| container | source | comes from |
|---|---|---|
| `positronic-control` | `flag` | `--positronic-image` |
| `phantom-models` | `flag` | `--phantom-models-image` |
| `operator-ui` | `manifest-scan` | grep of `manifests/` |
| `dma-ethercat` | `extra-images` | `packaging/deb-images/extra-images.txt` |

The sidecar will contain ~21-22 tarballs (the four above plus standard
infrastructure images: mongo, nginx, redis, postgres, registry, alpine,
mediamtx, argus.*, dma-streams, nimbus.*, yovariable-server, plus
phantomos-api-server).

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
bash scripts/build-images-deb.sh \
  --positronic-image <amd64-ref> \
  --phantom-models-image <amd64-ref>

# explicit narrow:
bash scripts/build-images-deb.sh --arch arm64 [...]
```

Cross-arch image pulls go through `docker pull --platform <arch>` and
require docker buildx (any modern docker has it; no qemu/binfmt needed
since the build only pulls and saves, never executes).

Each arch produces its own `.deb` + `.tar.zst` pair. The local-image
flags (`--positronic-image`, `--phantom-models-image`) only attach to
the build whose arch matches the local image; cross-arch local images
are silently skipped per-arch.

---

## Cache management

Image tarballs are cached at `dist/build/image-cache/<arch>/`. Subsequent
builds reuse the cache for unchanged refs.

To force a re-pull (e.g. a `:latest` tag moved upstream):

```bash
rm dist/build/image-cache/amd64/<sanitized-ref>.tar
bash scripts/build-images-deb.sh ...
```

The two `--*-image` flags' tarballs are NOT cached — they're saved fresh
from the local docker daemon on every build (so a rebuild of phantom-cuda
under the same tag gets re-bundled correctly).

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

The build script's manifest scan finds and bundles:

- **From `manifests/`** (`source: manifest-scan` in the bundle):
  `foundationbot/argus.{auth,company,gateway,operator-ui,user}:qa`,
  `foundationbot/dma-video:main`, `foundationbot/dma-streams:main-latest`,
  `foundationbot/nimbus.s3_dynamo_athena{,-jobs}:main`,
  `foundationbot/phantomos-api-server:V-...`,
  `foundationbot/yovariable-server:V-...`,
  `mongo:7`, `nginx:latest`, `postgres:16`, `redis:7-alpine`,
  `registry:2`, `alpine:3.19`, `bluenviron/mediamtx:latest`.
- **From `packaging/deb-images/extra-images.txt`** (`source: extra-images`):
  per-arch dma-ethercat (`main-latest-aarch64` on arm64,
  `main-latest` on amd64).
- **From `--positronic-image`** (`source: flag`): operator-built.
- **From `--phantom-models-image`** (`source: flag`): operator-built.

Only the first set is filtered against the manifest's `image:` tag —
that's where the `*:PLACEHOLDER` and `localhost:5443/*` exclusions
apply (those images either don't exist upstream or are template
placeholders).
