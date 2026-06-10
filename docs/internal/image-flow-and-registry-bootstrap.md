# Image flow and local-registry bootstrap

How container images get from a build host onto a robot, where the
local registry fits in, and why "press Enter through the wizard" plus
the current quick-start can produce a cluster full of `ImagePullBackOff`.

This doc is the post-mortem for one such bringup (mk09, 2026-05-09)
plus a plan for the fix.

---

## Two image stores, not one

There are two stores on every robot. Confusing them is the root of
most ImagePullBackOff incidents.

1. **containerd's local image store.** Populated at worker startup
   from `/var/lib/k0s/images/*.tar`. k0s auto-imports anything in
   that directory — no push, no registry round-trip. This is what
   the image `.deb` feeds.
2. **The in-cluster registry pod** at `localhost:5443` (host-network,
   bound to `127.0.0.1`). Plain Distribution `registry:2`, backed by a
   hostPath PV at `/var/lib/registry`. Only populated by an explicit
   `docker push`. The image `.deb` does **not** push anything here.

Containerd's mirror config (`scripts/configure-k0s-containerd-mirror.sh`)
makes containerd consult `localhost:5443` first for `docker.io/*`
pulls, falling through to `registry-1.docker.io` on 404. So images
referenced as `docker.io/foo` (or bare `foo`) can come from either
store. But images referenced as `localhost:5443/foo` can come from
**only** the registry pod — there is no fallthrough.

This matters because two of the workloads — `positronic-control` and
`phantom-models` — are pinned to `localhost:5443/*`. If the registry
pod doesn't have them, nothing else will serve them.

---

## Phase-by-phase: how the local registry actually gets set up

The registry rollout is split across three things, none of which
populate it with content:

| Step                              | Where                                                                                            | What it does                                                                                  |
| --------------------------------- | ------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------- |
| Containerd mirror                 | `scripts/configure-k0s-containerd-mirror.sh`, called by `bootstrap-robot.sh` phase 4 host config | writes `/etc/k0s/containerd.d/hosts/docker.io/hosts.toml` so containerd consults `:5443` first |
| Docker daemon insecure-registries | same script                                                                                      | merges `localhost:5443` into `/etc/docker/daemon.json` so `docker push` to it works           |
| Registry pod                      | `manifests/base/registry/registry.yaml`, deployed by Argo as part of the `core` stack            | Deployment + hostPath PV + Service in the `registry` namespace                                |

Phase 13 (`gitops`) is what triggers Argo to deploy the registry pod.
Once it's Ready, `docker push localhost:5443/<repo>:<tag>` works from
the host shell.

**Nothing in the bootstrap path pushes anything into the registry
pod by default.** Phase 17 (`setup-positronic`, opt-in via
`--setup-positronic --positronic-image <ref>`) is the only
in-tree mechanism that pushes content (positronic-control via
`scripts/positronic.sh push-image`, phantom-models via
`scripts/phantom-models/build.py --all`). It is off by default and
not in the quick-start.

---

## How the two `.deb` packages are built

Both builders live under `scripts/`:

### Control-plane `.deb` — `scripts/build-deb.sh`

Produces `phantomos-k0s-<ver>-all.deb`, an arch-independent package
that drops the repo into `/opt/Phantom-OS-KubernetesOptions/`. No
images. Auto-versioned from `version.txt` + `git rev-parse --short`,
with `+dirty` if the working tree has uncommitted changes.

### Image `.deb` — `scripts/build-images-deb.sh`

Produces one `phantomos-k0s-images-<ver>-<arch>.deb` per requested
arch (default both `amd64` and `arm64`). Each `.deb` ships pre-pulled
docker tarballs into `/var/lib/k0s/images/`, where k0s auto-imports
them at worker startup.

Image discovery (`build-images-deb.sh:191-201`):

```bash
grep -rhE '^\s*image:\s*' manifests/ \
  | sed -E 's/^\s*image:\s*//; s/^["'\'']//; s/["'\'']$//' \
  | grep -v "^localhost:5443/" \
  | grep -v ':PLACEHOLDER$' \
  | grep -v '^$' \
  | sort -u
```

Two filters are critical to the bug:

* `^localhost:5443/` is dropped because nothing on DockerHub matches
  that prefix — `docker pull` would 404. Result: positronic-control
  and phantom-models are never bundled in the `.deb`.
* `:PLACEHOLDER$` is dropped because that's a template tag the
  bootstrap is supposed to overwrite. The `dma-ethercat` installer
  Job uses this — its real tag is operator-supplied.

Beyond the manifest scan, `packaging/deb-images/extra-images.txt`
adds refs that aren't discoverable from manifests (per-arch
`dma-ethercat` tags today). Supports `{ARCH}` / `{KERNEL_ARCH}`
template substitution and per-line `# arch:<csv>` filters.

For each ref, the script:
1. Resolves the per-platform digest via `docker buildx imagetools
   inspect` (so cross-arch pulls land on the right manifest).
2. `docker pull --platform linux/<arch>` by digest.
3. `docker tag` back to the original ref so the saved tarball's
   `manifest.json` carries the ref k0s/containerd will look up.
4. `docker save` to `dist/build/image-cache/<arch>/<ref>.tar`.
5. Hardlinks the cached tar into the staging tree, builds the
   `.deb` with `dpkg-deb --build --root-owner-group`.

Failures per image are non-fatal — the `.deb` is still produced
from whatever did succeed, with a `<deb>.report.txt` next to it
listing included + skipped images.

---

## How `configure-host.sh` routes image overrides

The wizard writes `/etc/phantomos/host-config.yaml`. The `images:`
block is a container-keyed override map:

```yaml
images:
  positronic-control:
    image: localhost:5443/positronic-control:<tag>
  phantom-models:
    image: localhost:5443/phantom-models:<tag>
  operator-ui:
    image: foundationbot/argus.operator-ui:<tag>
  dma-ethercat:
    image: foundationbot/dma-ethercat:<tag>
```

`bootstrap-robot.sh` phase 15 (`image_overrides`) reads this via
`scripts/lib/host-config.py get-images-json`, routes each entry to
its owning Argo Application by scanning manifests for the
`manifest_image` find-key (`scripts/lib/host-config.py:362-417`
CONTAINER_TARGETS), then patches each Application's
`spec.source.kustomize.images` field. Kustomize then rewrites every
`image:` reference matching the find-key to the operator-supplied
tag — including any in-manifest defaults.

`dma-ethercat` is special-cased: its image is **not** routed to a
stack's kustomize.images (`scripts/lib/host-config.py:485` —
`CONTAINER_TARGETS["dma-ethercat"]["stack"] is None`). Instead,
phase 12 (`install_dma_ethercat`) sed-substitutes the tag into the
installer Job manifest at apply time
(`scripts/bootstrap-robot.sh:2920`).

### What the wizard offers as defaults

`scripts/configure-host.sh:704-714`:

```bash
canonical_default_repos=(localhost:5443/positronic-control
                         localhost:5443/phantom-models
                         foundationbot/argus.operator-ui
                         foundationbot/dma-ethercat)
canonical_default_tags=("REPLACE-WITH-LOCAL-BUILD-TAG"
                        "REPLACE-WITH-MODEL-BUILD-DATE"
                        "REPLACE-WITH-OPERATOR-UI-COMMIT-SHA"
                        "$dma_ethercat_default_tag")
```

Only `dma-ethercat` has a real default — computed from `uname -m`
(`configure-host.sh:640-659`). The other three are literal
placeholder strings.

### What the wizard does with operator input

`scripts/configure-host.sh:741-744`:

```bash
for i in "${!img_containers[@]}"; do
  new_ref="$(ask "${img_containers[$i]} image" "${img_refs[$i]}" \
             "Full image ref (repo:tag). Empty to skip this container.")"
  img_refs[$i]="$new_ref"
done
```

The `ask` prompt accepts whatever was shown as the default if the
operator just hits Enter, and emits the literal at line 970:

```bash
printf 'images:\n'
for i in "${!img_containers[@]}"; do
  [ -z "${img_refs[$i]}" ] && continue
  printf '  %s:\n' "${img_containers[$i]}"
  printf '    image: %s\n' "${img_refs[$i]}"
done
```

Empty value → row is skipped. Placeholder → row is emitted verbatim.

The validator (`scripts/lib/host-config.py:420 _split_image_ref`)
only checks that a colon is present after the last slash; it accepts
`:REPLACE-WITH-LOCAL-BUILD-TAG` as a syntactically-valid tag.

---

## Root cause: why pods ImagePullBackOff with an "unedited" host-config

Three independent defects compound:

1. **Wizard ships placeholder strings as canonical defaults**
   (`scripts/configure-host.sh:711-713`). The wizard is structured as
   an additive override layer, but its defaults aren't real refs —
   they're "fill me in" markers. There's no signal to the operator
   that pressing Enter writes an unresolvable tag.

2. **Quick-start tells operators to press Enter through the wizard**
   (`docs/quick-start.md`, "image overrides" row). The prompt's own
   help text — "Empty to skip this container" — is the correct path
   for operators who haven't built their own positronic-control,
   but the quick-start contradicts it. The "Common things that bite"
   section at the bottom mentions the failure mode but only as a
   post-hoc fix.

3. **The two `localhost:5443/*` workloads aren't bundled and aren't
   auto-built.** Even if you skip the override, the manifest defaults
   are `:PLACEHOLDER` (the build-images-deb.sh filter ensures these
   are never pulled), and the registry pod is empty. The quick-start
   doesn't mention building them or running `--setup-positronic`.

Failure path on a "press-Enter" run:
1. Operator runs configure wizard, hits Enter through every image
   prompt.
2. Wizard writes `images: { positronic-control: {image: localhost:5443/positronic-control:REPLACE-WITH-LOCAL-BUILD-TAG}, ... }`.
3. Bootstrap phase 15 successfully patches `phantomos-<robot>-{core,operator}` Applications with these literals.
4. Kustomize retags every `localhost:5443/positronic-control` reference to `:REPLACE-WITH-LOCAL-BUILD-TAG`. Same for `phantom-models` and `foundationbot/argus.operator-ui` (which would otherwise have worked because `:qa` is in the bundled `.deb`).
5. Pods start. ImagePullBackOff.

The host-config "looks empty of edits" because the wizard's idea of
a default IS the placeholder — they didn't get rewritten, but they
were never real values to begin with.

---

## Concrete fix plan for `configure-host.sh`

The minimum-change, lowest-risk path:

### A. Stop offering placeholder strings as defaults  *(implemented)*

`scripts/configure-host.sh:704-715`. Change the canonical default
table so:

* If a real default can be derived (operator-ui's `:qa` is in the
  bundled `.deb`; we know the version from `version.txt` or the
  `.deb` report), use it.
* Otherwise, set the default to **empty**. An empty default makes
  the prompt's "Empty to skip this container" path the path of
  least resistance.

Pseudo-diff for the canonical table:

```bash
canonical_default_tags=(
  ""                            # positronic-control: empty until operator opts in
  ""                            # phantom-models:     same
  "qa"                          # operator-ui:        bundled in image .deb
  "$dma_ethercat_default_tag"   # dma-ethercat:       arch-derived
)
```

The `:qa` for operator-ui is fragile (it's a moving tag, baked into
the manifest). Better: derive the default from
`/var/lib/k0s/images/foundationbot-argus.operator-ui_*.tar` if the
image `.deb` is installed, falling back to `qa`.

### B. Reject placeholder strings at validation time  *(implemented)*

`scripts/lib/host-config.py` validator. Add a check in the `images:`
validation pass (around line 1295-1304) that rejects any tag
matching `^REPLACE-WITH-` with an actionable error. That way, even
an old host-config that still carries placeholders fails fast at
bootstrap rather than silently breaking pod images.

```python
if isinstance(img, str):
    _, tag = _split_image_ref(img)  # already validated above
    if tag.startswith("REPLACE-WITH-"):
        errors.append(
            f"images.{cname}.image: tag {tag!r} is a wizard placeholder; "
            f"either set a real tag or remove the entry to use the "
            f"manifest default"
        )
```

### C. Detect locally-built images and offer them as defaults

`scripts/configure-host.sh`, in the section that builds
`canonical_default_*` arrays. For positronic-control and
phantom-models specifically, scan:

* `/var/lib/k0s/images/` for tarballs whose name matches the repo
  (`localhost:5443-positronic-control_*.tar`, etc. — but the build
  script doesn't currently bundle those, so this path lights up
  only after the build script is updated, see below).
* The local registry: `curl -s http://localhost:5443/v2/positronic-control/tags/list` (only works once the registry pod is up — fine for re-runs, no-op on first install).
* The local docker daemon: `docker images localhost:5443/positronic-control --format '{{.Tag}}' | head -1`.

Use the most recent tag found as the default; if nothing is found,
default to empty (B above + the prompt's existing skip path).

### D. Rewrite the quick-start image-overrides row

`docs/quick-start.md`. The row currently reads:

> **image overrides** | Press Enter to accept seed defaults; bump tags only when you know you need a specific build.

Replace with:

> **image overrides** | For positronic-control and phantom-models, type a real tag if you've built one locally, or leave **empty** (just press Enter on the empty default) to skip the override and use the bundled `.deb` defaults. For operator-ui and dma-ethercat the wizard's default is correct — press Enter to accept.

Plus a new "Before you start" entry: "If you maintain your own
positronic-control / phantom-models images, build and tag them under
`localhost:5443/...` on the build host before running
`scripts/build-images-deb.sh` (see step E below)."

### E. Bundle locally-built positronic-control + phantom-models

`scripts/build-images-deb.sh`. Add `--positronic-image <ref>` and
`--phantom-models-image <ref>` flags + interactive prompts that
take a local docker ref, verify it exists in the local daemon, and
`docker save` it directly into the staging tarball without going
through `docker pull`. Skip per-arch when the local image's
architecture doesn't match the build arch.

This closes the loop end-to-end: a `.deb` built with
`--positronic-image localhost:5443/positronic-control:<tag>` ships a
tarball that k0s imports into containerd at startup, and the wizard
in (C) finds that tag in `/var/lib/k0s/images/` and offers it as
the default.

(This change is implemented in the same PR as this doc; see the
`build-images-deb.sh` diff.)

### Sequencing

(A) and (B) are independent and small — ship them together as the
immediate fix. **Both landed together with this doc.** (C) depends
on (E) being available to be useful for positronic-control and
phantom-models, but (C) can land first against the registry-pod /
docker-daemon paths and grow the `/var/lib/k0s/images/` path once
(E) is in. (D) follows once (A) changes the default behavior so the
doc matches reality.

---

## Verification

To check what's actually in the live cluster's overrides on a
running robot:

```bash
sudo k0s kubectl -n argocd get application phantomos-<robot>-core \
  -o jsonpath='{.spec.source.kustomize.images}'; echo
sudo k0s kubectl -n argocd get application phantomos-<robot>-operator \
  -o jsonpath='{.spec.source.kustomize.images}'; echo

# Pods that aren't Running/Completed:
sudo k0s kubectl get pods -A | grep -Ev 'Running|Completed'

# What's in containerd's local store (imported from the .deb):
sudo k0s ctr -n k8s.io images list | grep -E 'argus|positronic|phantom|dma'

# What's in the registry pod (only positronic-control / phantom-models
# get pushed here):
curl -s http://localhost:5443/v2/_catalog
```

If `kustomize.images` contains `REPLACE-WITH-*`, the wizard wrote
placeholders and phase 15 patched them in. Edit
`/etc/phantomos/host-config.yaml` to remove the offending entries
(or set real tags) and re-run `bootstrap-robot.sh --image-overrides`.
