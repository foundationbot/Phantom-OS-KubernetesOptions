# Debian package (phantomos-k0s)

Builds a `.deb` that drops the repo at `/opt/Phantom-OS-KubernetesOptions`
on a fresh Ubuntu/Debian host so the operator can run
`configure-host.sh` and `bootstrap-robot.sh` without first cloning the
repo over the network.

## Build

From the repo root:

```bash
sudo apt install dpkg rsync          # build-host prerequisites
scripts/build-deb.sh                  # writes dist/phantomos-k0s_<ver>_all.deb
```

Override the version or maintainer if needed:

```bash
VERSION=0.2.0 DEB_MAINTAINER="Ops <ops@foundation.bot>" scripts/build-deb.sh
```

When `VERSION` is unset, the script derives it from `version.txt` at
the repo root:

- base from `version.txt` (e.g. `0.1.0`)
- plus `+<utcdate>.g<sha>` when built from a git checkout, for traceability
- plus `+dirty` if the working tree has uncommitted changes

The output filename flattens `.` and `+` to `-` for readability
(e.g. `phantomos-k0s-0-0-1-20260507-g19f774a-dirty-all.deb`), but the
Debian `Version:` field embedded in the package keeps the dots and
pluses (e.g. `0.0.1+20260507.g19f774a+dirty`) so dpkg/apt version
comparison still works correctly.

For a clean tagged release, set `VERSION` explicitly (matches whatever
you put in `version.txt`) so the package version has no suffix:

```bash
VERSION=$(cat version.txt) scripts/build-deb.sh
```

## Install

On the target robot:

```bash
sudo apt install ./phantomos-k0s_<ver>_all.deb
```

`apt` will pull the declared `Depends:` (python3, curl, jq, git, unzip,
ca-certificates) automatically. `Recommends:` (skopeo, docker.io,
pciutils, rsync) install by default unless the operator passes
`--no-install-recommends`.

After install, postinst prints the next-step commands. The repo lives
at `/opt/Phantom-OS-KubernetesOptions` exactly as the README documents.

## What's bundled vs. fetched at runtime

Bundled in the deb:

- `scripts/` - bootstrap, configure-host, lib helpers, ops scripts
- `manifests/` - base + stacks + installers
- `host-config-templates/` - schema + per-robot template skeletons
- `terraform/` - ArgoCD Helm module
- `docs/`, `README.md`, `REQUIREMENTS.md`

Downloaded by `bootstrap-robot.sh` at run time (NOT in the deb):

- k0s itself (`curl https://get.k0s.sh | sh`)
- terraform binary (pinned in `bootstrap-robot.sh`)
- container images (pulled by k0s/containerd as workloads come up)

If you need a fully-offline install, that is a separate "Repo + bundled
k0s binary" track -- not what this package builds.

## Inspecting the produced .deb

```bash
dpkg -I dist/phantomos-k0s_<ver>_all.deb     # control metadata
dpkg -c dist/phantomos-k0s_<ver>_all.deb     # file listing
```

## Uninstall

```bash
sudo apt remove phantomos-k0s        # leaves /etc/phantomos/ alone
sudo apt purge  phantomos-k0s        # same -- this package owns no conffiles
```

`/etc/phantomos/host-config.yaml` and any cluster state are generated
by the scripts at run time, not shipped by the package, so removing
the package never touches them.
