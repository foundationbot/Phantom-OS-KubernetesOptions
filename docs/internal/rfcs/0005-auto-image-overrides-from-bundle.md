# RFC 0005 — Auto image overrides from the bundled image .deb

**Status:** proposed
**Companion:** `docs/image-flow-and-registry-bootstrap.md`,
`docs/test-image-bundle-locally.md`

## Problem

Today the operator types image refs into the wizard for the four
canonical containers (positronic-control, phantom-models,
operator-ui, dma-ethercat). After the section A/B fix in
`image-flow-and-registry-bootstrap.md`, the defaults are sane —
empty for "must be a local build" rows, auto-detected `:qa` for
operator-ui, arch-derived for dma-ethercat — but the operator still
has to type tags for positronic-control and phantom-models on every
fresh bringup. Three failure modes follow:

1. **Typos** — operator types `2026-05-09` as `2026-05-9`, wizard
   accepts (it's syntactically valid), pod `ImagePullBackOff`s.
2. **Forgetting** — operator skips the override (empty), the manifest
   default `:PLACEHOLDER` ships, ImagePullBackOff.
3. **Drift** — fleet-wide `.deb` rolls out a new `phantom-cuda` tag,
   but each robot's host-config still pins the old one until someone
   re-runs the wizard.

Meanwhile, the build host already knows the answer. It just got
told `--positronic-image foundationbot/phantom-cuda:0.2.46-dev.1-cu128`
and `--phantom-models-image localhost:5443/phantom-models:2026-05-09`.
That information dies in the .deb's tarballs and isn't recoverable
from the robot side without lossy filename heuristics or per-tarball
`tar -xOf manifest.json | jq` scans.

## Proposal

The image .deb writes a small **bundle manifest** sidecar that
preserves build-time intent. The wizard reads it. Operators get
correct defaults — and a no-prompt mode — for free.

### Bundle manifest

A new file shipped in the image .deb at:

```
/var/lib/k0s/images/.phantomos-image-bundle.yaml
```

Schema:

```yaml
schemaVersion: 1
builtAt: 2026-05-09T03:18:29Z
builderVersion: 0.0.1+20260509.g1412dd6+dirty
arch: amd64
bundle:
  - container: positronic-control          # canonical_containers key
    ref: foundationbot/phantom-cuda:0.2.46-dev.1-cu128
    tarball: foundationbot-phantom-cuda_0.2.46-dev.1-cu128.tar
    source: flag                           # flag | extra-images | manifest-scan
  - container: phantom-models
    ref: localhost:5443/phantom-models:2026-05-09
    tarball: localhost_5443-phantom-models_2026-05-09.tar
    source: flag
  - container: operator-ui
    ref: foundationbot/argus.operator-ui:qa
    tarball: foundationbot-argus.operator-ui_qa.tar
    source: manifest-scan
  - container: dma-ethercat
    ref: foundationbot/dma-ethercat:main-latest
    tarball: foundationbot-dma-ethercat_main-latest.tar
    source: extra-images
```

`container` is the canonical-container key the wizard recognizes
(`scripts/configure-host.sh` `canonical_containers`). It is the
mapping that breaks the chicken-and-egg between "tarball
filename" and "which canonical container does this satisfy" — the
build host names it explicitly. Tarballs that don't correspond to
any canonical container are simply not listed.

The hidden filename (`.phantomos-image-bundle.yaml`) keeps it out
of `k0s ctr images import`'s scan path (k0s ignores dotfiles in
`/var/lib/k0s/images/`).

### Authoring path (build side)

`scripts/build-images-deb.sh` is extended (one hook in the per-arch
build loop) to assemble the bundle entries as it processes each
image:

- For each image successfully saved into the staging tree, derive
  the canonical container (if any) from a small lookup table that
  mirrors `CONTAINER_TARGETS` in `scripts/lib/host-config.py`.
- Manifest-scan and extra-images.txt entries map by repo
  (e.g. `foundationbot/argus.operator-ui` → `operator-ui`).
- `--positronic-image` and `--phantom-models-image` map by flag
  (operator-stated intent — required, since the repo on the flag
  may be a swap like `foundationbot/phantom-cuda` that the lookup
  table couldn't identify).
- Skip images that don't map to any canonical container — they're
  bundled for DockerHub-fallback purposes only and don't need an
  override.
- Write the assembled YAML before `dpkg-deb --build`.

The lookup table is the single source of truth for "this repo
satisfies this container." It already exists in `host-config.py
CONTAINER_TARGETS`. To avoid drift, factor it out into a small
shared YAML file (`packaging/canonical-containers.yaml`) read by
both the build script and `host-config.py`.

### Consumption path (wizard side)

`scripts/configure-host.sh`, in the `images:` block construction
(currently lines 693-744 after the section A/B fix). Authority
order on every wizard run:

1. **Seed wins.** Existing `images.<container>.image` entries in
   `/etc/phantomos/host-config.yaml` are preserved as-is. Operator
   hand-edits and post-deployment image updates are sacred —
   re-running the wizard never overwrites them. (The exception
   is the section-A/B `REPLACE-WITH-*` auto-clear, which is a
   bug-correction not an override.)
2. **Bundle fills the gaps.** For canonical containers without a
   seed entry, use `bundle[].ref` from
   `/var/lib/k0s/images/.phantomos-image-bundle.yaml` (when present
   and arch-matched) as the default.
3. **Section A defaults are last resort.** When neither seed nor
   bundle has an entry: empty for positronic/phantom-models,
   `:qa` for operator-ui (still derived from `/var/lib/k0s/images/`
   filename scan as a backstop for older .debs without the bundle
   manifest), arch-derived for dma-ethercat (preserved as the
   no-bundle fallback path).

Behavior with the default `--auto-images`:

- For each canonical container, if precedence resolves to a real
  ref (seed or bundle), write it straight into host-config without
  prompting.
- For each canonical container that resolves to empty, still skip
  the prompt — empty means "no override, use manifest default."
- Print a one-line summary header: `auto-images: 4 rows (3 from
  bundle 0.0.1+..., 1 from seed)`.

Behavior with `--no-auto-images`:

- Same precedence, but each row's resolved value becomes the
  prompt's pre-filled default. Operator can press Enter to
  accept, type a new ref to override, or clear the line to drop
  the override.

Failure modes:

- Bundle present but `arch` mismatches host (`dpkg
  --print-architecture`): refuse to consult the bundle, fall back
  to seed + section-A defaults, loud-warn. (Postinst should have
  caught this; this is the layer-2 backstop for hand-staged
  tarballs — see "Arch enforcement" below.)
- Bundle present but unparseable (truncated/corrupt YAML): refuse
  to consult, log a `warning:` line, fall back to seed +
  section-A. Don't fail the wizard outright — the operator can
  still configure manually.
- `--auto-images` runs and resolution leaves all four rows empty
  (no seed, no bundle, no `.deb` operator-ui detection): refuse
  to write a host-config with no images: block. Drop into the
  prompt loop instead — better to ask than to ship a guaranteed
  ImagePullBackOff.

### Image .deb postinst (three responsibilities)

The image .deb gains a `packaging/deb-images/postinst` that does
three things, in order. All three are no-ops when the bundle
manifest is absent (older .debs without Phase 1 still install
cleanly).

**1. Arch mismatch hard-refuse.** Reads
`/var/lib/k0s/images/.phantomos-image-bundle.yaml`, compares its
`arch` field to `dpkg --print-architecture`, and exits non-zero on
mismatch — `dpkg -i` aborts and rolls back, so a wrong-arch .deb
never lands tarballs on the wrong robot. Catches: a fleet operator
copying the wrong .deb to a robot via scp + `dpkg -i` (the most
common path). Redundant with dpkg's own `Architecture:` field
check — but louder, with a precise actionable message ("this .deb
was built for arm64; this host is amd64; install the *-amd64.deb"),
and survives `--force-architecture` (the postinst still runs and
still fails).

**2. Auto-import tarballs into containerd when k0s is running.**
This is the critical missing link. k0s only auto-scans
`/var/lib/k0s/images/` at worker startup; tarballs added to a
running k0s sit on disk, invisible to the runtime, until the next
restart or a manual `k0s ctr images import`. That's how robots
end up with mongo/nginx/postgres/redis tarballs on disk but pods
still ImagePullBackOff against private DockerHub.

The postinst detects k0s state and branches:

- If `systemctl is-active k0scontroller` returns `active`: iterate
  every `*.tar` under `/var/lib/k0s/images/` (not just the ones
  the .deb installs — old residual tarballs from prior installs
  too) and run `k0s ctr -n k8s.io images import <path>` on each.
  Idempotent — re-importing an existing image is a no-op in
  containerd.
- If k0s isn't running: skip silently. The next `k0scontroller`
  start will auto-import.
- Always print a one-line summary: `imported 21 tarball(s) into
  containerd` or `k0s not running — tarballs will import at next
  start`.

The import loop is the postinst's slow step (a few seconds per
tarball, dominated by content-store dedup). On a fresh first
install where k0s isn't up yet, the postinst skips it entirely.
On re-installs of a running cluster, this is what the operator
expects — the new tarballs are usable immediately, no `systemctl
restart k0scontroller` required.

**3. Soft-warn when the bundle manifest is absent.** If the .deb
predates Phase 1 (no manifest sidecar), the postinst prints a
single `warning: no image bundle manifest — older .deb format,
arch and import-state checks skipped` and continues. Lets older
.debs install cleanly while flagging the gap so operators see
they're missing the install-time safety net.

### Arch enforcement (wizard-time backstop)

The postinst (responsibility 1) catches the dpkg path. The wizard
checks the same bundle-arch ↔ host-arch comparison whenever it
reads the bundle, with the same hard-refuse semantics. Two layers
because each catches paths the other doesn't:

The wizard layer catches paths that bypass `dpkg` entirely: manual
`docker save` + copy into `/var/lib/k0s/images/` (what `fix.sh`
does for ad-hoc testing), tarballs shipped via a non-dpkg channel
(rsync, S3 fetch, baked into a custom OS image), or
`--force-architecture --force-overwrite` flag combos. Failing here
fails before bootstrap patches Argo with refs that point at the
wrong architecture's binaries.

Both layers print the same error format — "bundle arch=arm64
host arch=amd64" — so triage looks identical regardless of which
layer fired.

### Other validation hooks

- `scripts/validate-local-registry.sh` (run as bootstrap phase 15)
  cross-checks every entry in `host-config.yaml`'s `images:` block
  against `/var/lib/k0s/images/` (any tarball whose RepoTags
  contains the ref). Emits a warning, not an error — operators may
  legitimately want a host-config that pulls from upstream.
- `scripts/lib/host-config.py validate` adds a soft check: when the
  bundle manifest is present and an `images.<container>.image` ref
  doesn't match the bundled ref, emit a `note:` line. Nothing
  rejected — operators can override.

### Sequencing

| Phase | What ships | Useful by itself? |
|---|---|---|
| 1 | `build-images-deb.sh` writes the bundle manifest; nothing else changes | Yes — operators can `cat .phantomos-image-bundle.yaml` to see what's bundled |
| 2 | `canonical-containers.yaml` extracted; both build script and `host-config.py` read from it | Yes — eliminates the duplicated table |
| 3 | `configure-host.sh` reads the bundle manifest and uses `ref`s as prompt defaults | Yes — operator-ui's auto-detect from section A becomes "use the manifest" + falls back to filename scan |
| 4 | `--auto-images` flag and the env var | Yes — fleet automation can run the wizard non-interactively when the .deb is canonical |
| 5 | Validation cross-checks in `validate-local-registry.sh` and `host-config.py validate` | Yes — surfaces drift between host-config and what's actually on disk |
| 6 | `packaging/deb-images/postinst` — three responsibilities: arch check, auto-import-into-containerd-when-k0s-running, soft-warn-on-missing-manifest | Yes — independent of wizard work; the auto-import alone fixes the on-disk-but-not-in-containerd gap that bites every re-install of a running cluster |

Phases 1+3 are the minimum viable change for the wizard work.
Phase 6 should land alongside Phase 1 since both require the
bundle manifest (for arch check) but Phase 6's auto-import
responsibility is independently valuable: it closes the bug where
mongo/nginx/postgres/redis tarballs sit in `/var/lib/k0s/images/`
indefinitely after a re-install, never reaching containerd until
someone restarts k0s. The auto-import is a no-op when the bundle
manifest is missing, so it can ship even before Phase 1 if needed.

## Trade-offs and rejected alternatives

### Tarball scanning instead of a manifest

Read each `/var/lib/k0s/images/*.tar`'s `manifest.json` to recover
RepoTags directly.

- Pro: zero build-side change, retroactively works on existing
  .debs.
- Con: doesn't solve the swap-repo problem
  (`foundationbot/phantom-cuda` could be the operator's intended
  positronic-control image, or it could be something else entirely
  — there's no way to tell from the tarball alone). Forces the
  wizard to maintain a brittle "known swap repos" list per
  canonical container.
- Verdict: viable as a fallback for old .debs, but not as the
  primary mechanism. The bundle manifest is strictly more
  expressive at trivial build cost.

### Pre-write the host-config from the .deb's postinst

Have the image .deb's postinst write/update
`/etc/phantomos/host-config.yaml`'s `images:` block directly.

- Pro: zero wizard change, even more automatic.
- Con: violates layering — the image .deb shouldn't know about
  host-level config. Conflicts with operator hand-edits. Hard to
  reason about during partial upgrades (image .deb installed but
  control .deb is older). Postinst failure modes are nasty.
- Verdict: rejected. The wizard is the right place for this.

### Argo-side auto-discovery

Have ArgoCD pre-sync hook scan containerd's local store and patch
`spec.source.kustomize.images` directly, eliminating the wizard's
involvement entirely.

- Pro: GitOps-native, no per-host wizard state.
- Con: ArgoCD scanning containerd is a significant new capability;
  needs RBAC, a CRD or annotation contract, and ordering against
  Argo's own image update controllers. Way out of scope for
  closing the immediate gap.
- Verdict: rejected for now. Possible long-term direction once the
  fleet has more than ~10 robots and per-host wizard-driven config
  becomes operationally heavy.

## Resolved decisions

(Originally posed as open questions; resolved during RFC review.)

### `--auto-images` is on by default in both TTY and non-TTY runs

When the bundle manifest is present and parses, the wizard skips
the four image prompts and writes their `images:` rows directly
from `bundle[].ref`. Operator opts out with `--no-auto-images`
(then the four prompts run with the bundle's `ref`s as
pre-filled defaults).

**Pros:** matches operator intent in the 99% case (the fleet ops
team picked the bundled refs at .deb build time precisely so that
robots get them); turns first-bringup into "press enter through the
wizard" without any image-related input; eliminates typo class.

**Cons:** deviates from `confirm()`'s established split (interactive
defaults to "ask", non-interactive defaults to "accept"); operators
who used to type tags and got proprioception about what shipped
will lose that. Both are acceptable: this is image-selection, not a
policy decision, and the wizard prints a one-line summary
("auto-images: 4 rows from bundle 0.0.1+...") so the operator still
sees what landed.

The `--no-auto-images` escape hatch is documented in the wizard's
`--help` and surfaces in the wizard's pre-prompt header. Setting
`PHANTOMOS_AUTO_IMAGES=0` is equivalent for environments that
template wizard invocations.

### Drop the `uname -m`-derived `dma-ethercat` default when the bundle is present

`configure-host.sh:640-659` currently derives the dma-ethercat
default tag from `uname -m`
(`aarch64`→`main-latest-aarch64`, `x86_64`→`main-latest`). With
the bundle manifest, the bundled tag is what's actually on disk
and what containerd will serve locally — by definition correct
for this host's arch (the postinst arch check ensures it).

**Pros of dropping the `uname -m` derivation when the manifest is present:**
- One source of truth (the manifest), no drift between two
  arch-detection paths.
- Removes the silly possibility of "manifest says X, uname says Y,
  defaults disagree."
- Survives CI naming-convention changes (e.g. amd64 moves from
  `main-latest` to `main-latest-amd64`) without a code change —
  the bundle reflects whatever CI actually published.

**Cons of dropping it:**
- Wizard runs on a robot whose .deb is missing the bundle (older
  install, manual `fix.sh` staging) lose the auto-default and fall
  back to whatever the seed had. Mitigation: keep the `uname -m`
  derivation as the *secondary* default, used when the manifest is
  absent. Effectively a fallback, not a removal.
- The `dma_ethercat_wrong_tags` auto-correct (also at
  `configure-host.sh:640-659`) still has to live somewhere — it's
  for sanitizing *seed entries* from a stale host-config (e.g.
  moving an arm64 host-config to an amd64 robot), which is a
  separate use case from "default for fresh row." Keep it, untouched.

Decision: bundle wins when present, `uname -m` derivation is the
fallback when absent, `dma_ethercat_wrong_tags` is preserved
verbatim as the seed-correction layer.

### Canonical containers extracted to `packaging/canonical-containers.yaml`

Three places currently hold parts of the same table —
`CONTAINER_TARGETS` in `scripts/lib/host-config.py:362`,
`canonical_containers`/`canonical_default_repos` in
`scripts/configure-host.sh:698`, and an implicit "what does this
repo satisfy" lookup that the build script (Phase 1 of this RFC)
will need. Factor them into one YAML:

```yaml
# packaging/canonical-containers.yaml
containers:
  positronic-control:
    manifest_image: localhost:5443/positronic-control
    stack: core
    swap_repos: [foundationbot/phantom-cuda]
  phantom-models:
    manifest_image: localhost:5443/phantom-models
    stack: core
  operator-ui:
    manifest_image: foundationbot/argus.operator-ui
    stack: operator
  dma-ethercat:
    manifest_image: foundationbot/dma-ethercat
    stack: null            # routed by phase 9 sed-substitution, not kustomize
```

**Pros:**
- One file to edit when adding a new canonical container
  (today: three places, easy to forget one — and the host-config.py
  comment about CONTAINER_TARGETS being stale is exactly this).
- The build script (Phase 1) gets a clean way to ask "which
  canonical container does this repo satisfy" — by reading
  `manifest_image` plus `swap_repos`. No special-case wiring.
- Externalized data is testable without exercising the wizard.
- Survives reorganization of either Python or Bash side
  independently.

**Cons:**
- New file to keep schema-compatible. Mitigation: add a small
  `validate-canonical-containers.sh` that asserts every key the
  Python and Bash sides expect is present.
- Bash needs `python3 -c 'import yaml; ...'` to read it. Already
  done elsewhere in the wizard, no new dependency.
- One more parse step at every wizard run (~10 ms). Negligible.

**Important constraint surfaced during review:** the
canonical-containers file is a **schema**, not a deployment source
of truth. It tells the wizard "these are the canonical containers
and how to find them in manifests." It does NOT carry image refs
or tags. The deployment source of truth is
`/etc/phantomos/host-config.yaml` — and stays so even after
operators hand-update images.

The wizard's authority order on re-runs becomes:

1. **Seed (existing `host-config.yaml`)** — wins absolutely. If
   the operator updated `images.positronic-control.image` to a
   newer tag (say, after a manual `docker load` + `k0s ctr import`
   cycle to push a hot-fix), re-running the wizard preserves that.
   The wizard is explicit about this in the prompt's default
   value.
2. **Bundle manifest** — fills defaults only for canonical rows
   that aren't in the seed. New install: bundle defaults populate
   everything. Re-install after `dpkg -i` of a newer .deb but no
   wizard re-run yet: bundle reflects the newer .deb but the seed
   still wins on re-run (operator must explicitly clear the row
   in the wizard or hand-edit host-config to take the bundle's
   newer tag).
3. **`canonical-containers.yaml` + Section A defaults** — last
   resort, only when neither seed nor bundle has an entry.

This means a workflow like:
- `docker load < new-positronic.tar`
- `k0s ctr -n k8s.io images import new-positronic.tar`
- `vim /etc/phantomos/host-config.yaml`  (bump the tag)
- `bootstrap-robot.sh --image-overrides`

never goes through the wizard at all. Re-running the wizard later
preserves the operator's edit. The bundle manifest is consulted
only for arch-check and as a default *source* — never as an
override.

## Validation plan

Once phases 1+3 ship:

1. Build a fresh .deb with `--positronic-image foo:bar
   --phantom-models-image baz:qux`, install it, run the wizard,
   confirm the four prompts pre-fill from the bundle, and the
   host-config matches the bundle.
2. Build a .deb without the local-image flags, install it, run
   the wizard, confirm positronic-control + phantom-models prompts
   show empty defaults (section A behavior).
3. Build an arm64 .deb, attempt to install on an amd64 host,
   confirm the postinst arch-mismatch error fires and `dpkg -i`
   rolls back. Then bypass dpkg by staging the arm64 tarballs
   manually (the `fix.sh` pattern) and run the wizard, confirm the
   wizard's arch-mismatch error fires.
4. Hand-edit host-config to disagree with the bundle, run
   `validate-local-registry.sh`, confirm the drift warning fires.
5. Run with `--auto-images` on a TTY, confirm the four image
   prompts are skipped and the host-config lands correctly.
6. Postinst auto-import: on a running k0s cluster with the
   previous .deb's tarballs already imported, install a new
   .deb that adds `mongo:7-replacement` (a fresh image not yet
   in containerd). After `dpkg -i` completes, run `k0s ctr -n
   k8s.io images list | grep mongo` and confirm the new tarball
   is in containerd's local store *without* a `systemctl restart
   k0scontroller`. Then re-run `dpkg -i` of the same .deb and
   confirm idempotency (no errors, no duplicate import work).
7. Postinst skip-on-fresh: stop k0s (`systemctl stop
   k0scontroller`), `dpkg -i` the .deb, confirm postinst prints
   `k0s not running — tarballs will import at next start` and
   exits 0. Start k0s, confirm tarballs auto-import.

## Out of scope

- Building positronic-control / phantom-models from source as part
  of bringup. Operator still does that on their build host.
- Pushing positronic-control / phantom-models to the in-cluster
  registry pod (they live in containerd's local store after the
  bundle import, which is what kubelets pull from — see
  `image-flow-and-registry-bootstrap.md` "Two image stores").
- Replacing the wizard with a fully declarative input file. That's
  a separate, larger conversation about how host-config is
  authored across a fleet.

## Known limitation — `.deb` ar size cap (resolved by RFC 0007)

Surfaced during smoke testing of this RFC: the `.deb` format uses an
`ar` archive whose member size field is 10 ASCII decimal digits,
capping each member at `9999999999` bytes (~9.3 GB). When the
combined image bundle's `data.tar.{xz,gz,zst}` exceeds that cap,
`dpkg-deb --build` fails with `ar member size <N> too large` and no
.deb is produced.

Real-world impact: bundling a CUDA-class workload's main image
(e.g. `foundationbot/phantom-cuda` at ~12 GB content, ~18 GB after
xz with the rest) blows past the cap. The `.deb` doesn't build at
all — there's no graceful failure mode, just a hard `dpkg-deb` error.

The bundle-manifest writer (Phase 1 of this RFC) is unaffected —
it generates the YAML correctly regardless of size. The cap is
purely on the .deb packaging step.

**Resolution: RFC 0007.** Split the build into two artifacts: a
small metadata `.deb` (containing the bundle manifest + postinst)
plus a sidecar `<name>-<arch>.tar.zst` (containing the image
tarballs). The sidecar isn't subject to ar's size cap. The
postinst gains a Responsibility 0 that verifies the operator has
extracted the sidecar before install, and fails fast with a clear
extract-the-sidecar-first error if not.

Until RFC 0007 ships, operators with images that exceed the cap
should use the manual path documented in
`image-flow-and-registry-bootstrap.md`: `docker save` the giant
image directly into `/var/lib/k0s/images/`, `k0s ctr images
import` it, and add a corresponding entry to
`/etc/phantomos/host-config.yaml`'s `images:` block by hand. The
wizard's `--auto-images` mode will read the (smaller) .deb's
bundle manifest for the rest.
