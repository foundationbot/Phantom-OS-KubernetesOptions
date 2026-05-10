# RFC 0007 — Sidecar image data bundle (escape the .deb size cap)

**Status:** sketch
**Companion:** `docs/rfcs/0005-auto-image-overrides-from-bundle.md`
(this is the resolution to RFC 0005's "Known limitation" section)

## Problem

The `.deb` format uses an `ar` archive with a 10-character ASCII
decimal size field, capping each archive member at `9999999999`
bytes (~9.3 GB). When the bundled `data.tar.{xz,gz,zst}` exceeds
that, `dpkg-deb --build` fails with `ar member size <N> too large`
and produces no .deb.

This is hit immediately by realistic CUDA workloads:
`foundationbot/phantom-cuda` alone is ~12 GB content / ~18 GB after
xz compression, blowing through the cap before we even add the
other 20 standard images. Smoke testing of RFC 0005's bundle work
surfaced the failure (see `fix4.sh` first run).

The current workaround — manual `docker save` + `k0s ctr images
import` per huge image — sidesteps the .deb entirely for the giant
images, leaving them outside the bundle manifest and outside any
arch / version / install-state check the postinst would otherwise
do. That's fine for ad-hoc testing but unsuitable for fleet ops.

## Proposal — two artifacts, one source of truth

`scripts/build-images-deb.sh` produces a **pair** of artifacts per
arch:

```
dist/phantomos-k0s-images-<ver>-<arch>.deb        ~30 KB
  /var/lib/k0s/images/.phantomos-image-bundle.yaml
  DEBIAN/postinst
  DEBIAN/control

dist/phantomos-k0s-images-<ver>-<arch>.tar.zst    multi-GB
  foundationbot-phantom-cuda_<tag>.tar
  foundationbot-phantom-models_<tag>.tar
  foundationbot-argus.operator-ui_qa.tar
  ...
```

The `.deb` stays small (manifest + postinst + control). The
`.tar.zst` carries every `*.tar` image, packed with zstd (fast,
good ratio, parallel decompression) and unpacks straight to
`/var/lib/k0s/images/`. The bundle manifest inside the `.deb`
records `tarball: <filename>` for each canonical container; the
sidecar contains exactly those filenames (plus non-canonical
images that aren't in `bundle[]` but still ship — mongo, redis,
nginx, etc.).

`ar`'s size cap doesn't apply to the sidecar — it's a plain tar
file, no archive format limit short of the underlying filesystem.

### Operator workflow

```
# scp both files to the robot:
scp phantomos-k0s-images-0.0.1+...-amd64.deb     robot:~/
scp phantomos-k0s-images-0.0.1+...-amd64.tar.zst robot:~/

# extract data bundle into /var/lib/k0s/images/:
sudo tar -I 'zstd -d -T0' -xf phantomos-k0s-images-0.0.1+...-amd64.tar.zst -C /

# install .deb (postinst verifies the data bundle is present):
sudo dpkg -i phantomos-k0s-images-0.0.1+...-amd64.deb
```

A wrapper convenience script `scripts/install-image-bundle.sh`
takes both files and chains the two steps with a sanity check
that filename versions/arches match.

### Postinst additions (Phase 6 expansion)

The existing `packaging/deb-images/postinst` from RFC 0005 grows
one new responsibility — let's call it Responsibility 0 since it
runs first:

**0. Verify expected tarballs are present.** Read the bundle
manifest, collect the list of `bundle[].tarball` filenames, and
check each exists under `IMAGES_DIR`. If any are missing, exit
with a clear error pointing at the data bundle:

```
error: image data bundle not extracted
  bundle manifest expects N tarball(s) under /var/lib/k0s/images/
  found M; missing K
  install the data bundle first:
    sudo tar -I 'zstd -d -T0' -xf phantomos-k0s-images-<ver>-<arch>.tar.zst -C /
```

`dpkg -i` then rolls back, leaving no half-installed state. The
operator runs the extract command, retries `dpkg -i`, and the
install completes cleanly.

Tarball presence check is the **only** crosscheck needed — we
don't verify checksums or ref-tags against the manifest. The
manifest is signed by the build (implicitly, by being inside a
versioned `.deb`); operators who tamper with extracted tarballs
are responsible for their own state.

Existing responsibilities 1-3 from RFC 0005 stay verbatim:
arch-mismatch refuse, soft-warn-on-missing-manifest (now
basically unreachable since manifest is in the .deb itself),
auto-import when k0scontroller is active.

### Build-script changes

`scripts/build-images-deb.sh` per-arch flow becomes:

```
build_for_arch(arch):
  1. discover/save tarballs into stage_dir/var/lib/k0s/images/
     # (existing logic)
  2. write bundle manifest to stage_dir/var/lib/k0s/images/.phantomos-image-bundle.yaml
     # (Phase 1 of RFC 0005 — already implemented)
  3. tar+zstd the tarballs into dist/<name>-<arch>.tar.zst
     # NEW
  4. remove the tarballs from stage_dir (keep ONLY the .yaml manifest + DEBIAN/)
     # NEW
  5. dpkg-deb --build stage_dir → dist/<name>-<arch>.deb
     # (existing — now produces a small metadata-only .deb)
  6. write report.txt listing both artifacts and sizes
     # (existing — extended)
```

The cache (`dist/build/image-cache/<arch>/`) keeps individual
tarballs as before. Step 3 reads from the cache or from the just-
populated stage directory and produces the sidecar artifact.

A flag controls whether to emit the sidecar:
`--data-bundle <path>` writes the sidecar to a custom location;
`--no-data-bundle` skips it (for operators who want only the
.deb's manifest, e.g. when distributing the data via S3/rsync
separately). Default: emit alongside the .deb in dist/.

## Alternatives considered

### Per-image .debs (the other option from RFC 0005's "Known limitation")

`phantomos-k0s-images-positronic-amd64.deb`,
`phantomos-k0s-images-phantom-models-amd64.deb`, etc. Each fits
under the cap.

- Pro: stays inside dpkg's transaction model (atomic install/
  uninstall, dependency tracking, version constraints).
- Pro: operator can install just the subsets they need
  (phantom-models without phantom-cuda, e.g.).
- Con: N artifacts to manage instead of 2.
- Con: bundle-manifest fragments per .deb need a merge step on
  the robot side; the wizard's bundle reader becomes "scan
  /var/lib/k0s/images/ for *.bundle.yaml fragments and merge."
  Not hard but extra moving parts.
- Con: every release of a single image is a new .deb to ship,
  even if everything else is unchanged. With sidecar, the entire
  fleet image set is one tar.zst per release.

Verdict: rejected for now. Sidecar is operationally simpler. Per-
image .debs become attractive only when fleet ops needs per-image
versioning (e.g. canary positronic-control with stable
phantom-models) — not a current use case.

### OCI artifacts pushed to a registry

Push the bundle as an OCI artifact (using `oras` or similar) to
the in-cluster registry pod or an external registry. Pods pull
the artifact's blobs; the manifest acts as an index.

- Pro: native to the container ecosystem, scales to thousands of
  robots, deduplicated layers.
- Pro: no scp/rsync — robots pull on demand.
- Con: requires a reachable registry. Air-gapped robots break.
- Con: registry-side auth/rotation/maintenance.
- Con: significant departure from "two files scp'd to robot" simplicity.

Verdict: out of scope. Compelling at fleet scale (>100 robots),
overkill for the current problem.

### Squashfs / loop-mount

Ship the giant image bundle as a squashfs file, loop-mount it
into `/var/lib/k0s/images/`. Read-only but sized only by the
filesystem.

- Pro: no extraction step (mount is instant).
- Con: requires a loop device + mount manage, breaks "this is
  just files" mental model.
- Con: read-only image bundle prevents ad-hoc additions (the
  manual `docker save` workflow we use for testing).

Verdict: rejected. Tar.zst is conceptually cheaper.

## Implementation plan

Three small phases, sequenced for safety:

### Phase 1 — `build-images-deb.sh` produces the sidecar

After the existing tarball-staging loop, before `dpkg-deb --build`:

- `tar --use-compress-program='zstd -T0 -19' -cf <dist>/<name>-<arch>.tar.zst -C $stage_dir/var/lib/k0s/images/ .`
- Move the `.tar` files out of `stage_dir/var/lib/k0s/images/` (keep only the `.phantomos-image-bundle.yaml`).
- `dpkg-deb --build` then produces a small .deb.
- Report.txt lists both artifacts.

Roughly +30 lines in the per-arch builder.

### Phase 2 — postinst gains Responsibility 0 (presence check)

`packaging/deb-images/postinst`: between the soft-warn-on-missing-
manifest path and the arch-mismatch check, add a tarball-presence
verifier. Reads `bundle[].tarball` filenames, checks each exists
in `$IMAGES_DIR`. On any missing, prints the actionable error and
exits 2 (dpkg rolls back).

Roughly +30 lines.

### Phase 3 — `scripts/install-image-bundle.sh` wrapper

Convenience for operators: takes the .deb and the .tar.zst as
args (or auto-discovers them in a directory), verifies version/
arch match between filenames, runs the tar extract, runs `dpkg
-i`. Ships in the control-plane .deb so it lands at
`/opt/Phantom-OS-KubernetesOptions/scripts/install-image-bundle.sh`.

Roughly 50 lines.

### Documentation updates (alongside Phase 1)

- `docs/quick-start.md`: update the "What you'll need" + step 1
  to mention the sidecar `.tar.zst`.
- `docs/rfcs/0005-...md`: replace "Known limitation" section with
  a pointer to RFC 0007 as the resolution.
- `docs/image-flow-and-registry-bootstrap.md`: a short paragraph
  in "How the two `.deb` packages are built" explaining the
  sidecar split.

## Validation

1. Build a small .deb (no `--positronic-image`) — sidecar should
   contain ~21 tarballs, .deb stays a few KB. Operator extracts
   sidecar, `dpkg -i`, postinst imports cleanly.
2. Build a giant .deb with `--positronic-image phantom-cuda` —
   confirms the size cap is escaped (sidecar is ~18 GB tar.zst,
   .deb is still ~30 KB).
3. `dpkg -i` without first extracting the sidecar — postinst
   should fail-fast with the actionable error, dpkg should roll
   back, no half-installed state.
4. `dpkg -i` after extracting only PART of the sidecar (delete
   one tarball before install) — same fail-fast.
5. Re-install of an already-installed bundle — idempotent.
6. Wrapper script: `install-image-bundle.sh phantomos-...-amd64.deb` 
   discovers the sibling .tar.zst, extracts, installs.
   Mismatched version/arch in filenames → wrapper refuses to proceed.

## Open questions

1. **Compression level for zstd.** `-19` is "ultra" mode and slow
   on the build host but produces the smallest output. `-3` is
   default-fast. Container layers are mostly already-compressed,
   so any level past ~-9 yields diminishing returns. Lean: `-9`
   (fast enough on a build host, ~10% smaller than `-3`).
2. **Should the sidecar be GPG-signed?** The .deb already isn't
   today. Punt to whatever distribution mechanism the fleet uses
   (apt repo signing, S3 bucket policies, etc.).
3. **Where does `--data-bundle <path>` write to by default?**
   Currently dist/. CI may want a separate output dir for sidecar
   artifacts (S3 upload pipeline). Just make it configurable.
4. **Wrapper script name and home.** Lean:
   `scripts/install-image-bundle.sh`. Or piggyback on
   `bootstrap-robot.sh` with a new `--install-image-bundle <path>`
   flag? First option is simpler and discoverable.

## Out of scope

- Multi-volume `.deb` itself (some debian tooling supports this
  via debhelper hooks). More complex than the sidecar approach,
  same end result.
- Using `oras` / OCI distribution. Real but separate direction.
- Per-image release cadence (different versions of phantom-cuda
  vs. phantom-models in the same fleet). The sidecar is one
  monolithic blob per build; per-image cadence wants the per-
  image .deb shape from RFC 0005's "Known limitation".
