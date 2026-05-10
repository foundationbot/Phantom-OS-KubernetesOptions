# Test plan — bundle local images and re-bringup mk09

End-to-end smoke test for the
`docs/image-flow-and-registry-bootstrap.md` fix path on the current
host (mk09, amd64). Two images are already in the local docker
daemon and we'll route them into containerd's local store, then
re-run the wizard + bootstrap with real tags so the cluster comes
up clean.

## Inventory

```
localhost:5443/phantom-models:2026-05-09       (amd64, ~3.8 GB content)
foundationbot/phantom-cuda:0.2.42-dp           (amd64, ~23 GB content)
```

The phantom-models ref is a direct tag override — its repo matches
the manifest's `localhost:5443/phantom-models`, so kustomize emits a
plain retag.

The phantom-cuda ref is a **repo-swap** override for
positronic-control. The manifest references
`localhost:5443/positronic-control`; the kustomize override syntax
`manifest_image=newrepo:newtag` (`scripts/lib/host-config.py:434-442`)
rewrites every reference from `localhost:5443/positronic-control` to
`foundationbot/phantom-cuda:0.2.42-dp`. Containerd then looks
the swapped ref up — and we want it served from local store, not
pulled from DockerHub.

## Two test paths — pick one

### Path A (faster, manual): docker save + k0s import

Skips rebuilding the `.deb`. Saves the two tarballs straight into
`/var/lib/k0s/images/` and imports them into containerd.

```bash
# 1. Save both images as tarballs into k0s's import directory.
#    Filename convention matches build-images-deb.sh:sanitize_filename
#    so a future .deb-install of the same tarball is a no-op.
sudo docker save localhost:5443/phantom-models:2026-05-09 \
  -o /var/lib/k0s/images/localhost-5443-phantom-models_2026-05-09.tar
sudo docker save foundationbot/phantom-cuda:0.2.42-dp \
  -o /var/lib/k0s/images/foundationbot-phantom-cuda_0.2.42-dp.tar

# 2. Import into containerd's k8s.io namespace. k0s only auto-imports
#    at worker startup; doing it explicitly here avoids needing to
#    restart k0scontroller.
sudo k0s ctr -n k8s.io images import \
  /var/lib/k0s/images/localhost-5443-phantom-models_2026-05-09.tar
sudo k0s ctr -n k8s.io images import \
  /var/lib/k0s/images/foundationbot-phantom-cuda_0.2.42-dp.tar

# 3. Verify both images are now visible to containerd.
sudo k0s ctr -n k8s.io images list \
  | grep -E 'phantom-models:2026-05-09|phantom-cuda:0.2.42-dp'
```

### Path B (closer to production): rebuild the image .deb

Exercises the modified `build-images-deb.sh` end-to-end. Slower
because it `docker save`s into the cache and then `dpkg-deb --build`s
the package, but matches what a fleet operator will actually do.

```bash
# 1. Build the image .deb for amd64 only, bundling both local images.
#    (omit --no-prompt to be asked interactively instead)
sudo bash /opt/Phantom-OS-KubernetesOptions/scripts/build-images-deb.sh \
  --arch amd64 \
  --positronic-image foundationbot/phantom-cuda:0.2.42-dp \
  --phantom-models-image localhost:5443/phantom-models:2026-05-09 \
  --no-prompt

# 2. Confirm both local refs appear in the report.
grep -E 'phantom-cuda|phantom-models' \
  /home/whoami/Documents/Phantom-OS-KubernetesOptions/dist/*-amd64.report.txt | tail

# 3. Install the new image .deb (overwrites tarballs in /var/lib/k0s/images/).
sudo dpkg -i /home/whoami/Documents/Phantom-OS-KubernetesOptions/dist/phantomos-k0s-images-*-amd64.deb

# 4. Import the two new tarballs into containerd (same as Path A step 2).
sudo k0s ctr -n k8s.io images import \
  /var/lib/k0s/images/localhost-5443-phantom-models_2026-05-09.tar
sudo k0s ctr -n k8s.io images import \
  /var/lib/k0s/images/foundationbot-phantom-cuda_0.2.42-dp.tar
```

## Re-run the wizard

```bash
sudo bash /opt/Phantom-OS-KubernetesOptions/scripts/configure-host.sh
```

Wizard answers — only the image-override prompts matter for this
test; press Enter through everything else to keep the existing
host-config:

| Prompt | Answer |
|---|---|
| `positronic-control image` | `foundationbot/phantom-cuda:0.2.42-dp` (default is empty after the fix; type the ref) |
| `phantom-models image` | `localhost:5443/phantom-models:2026-05-09` (default is empty after the fix; type the ref) |
| `operator-ui image` | **press Enter** — default is the bundled `:qa` (auto-detected from `/var/lib/k0s/images/foundationbot-argus.operator-ui_qa.tar`) |
| `dma-ethercat image` | accept default `foundationbot/dma-ethercat:main-latest` |

Note: with the section A/B fix from
`docs/image-flow-and-registry-bootstrap.md` in place, the wizard
now (a) auto-clears any seed entries that still carry a
`REPLACE-WITH-*` placeholder tag — you'll see a `warning ... clearing
— re-prompt with canonical default` line on stderr — and (b) the
validator in `host-config.py` rejects placeholder tags outright, so
even an old hand-edited host-config can't slip through.

Confirm the resulting host-config has no placeholder strings:

```bash
grep -E 'REPLACE-WITH|PLACEHOLDER' /etc/phantomos/host-config.yaml \
  && echo "FAIL: still has placeholders" \
  || echo "OK: no placeholders"
```

Expected `images:` block:

```yaml
images:
  positronic-control:
    image: foundationbot/phantom-cuda:0.2.42-dp
  phantom-models:
    image: localhost:5443/phantom-models:2026-05-09
  dma-ethercat:
    image: foundationbot/dma-ethercat:main-latest
```

(no `operator-ui` row.)

## Re-run bootstrap

The cluster is already up, so a targeted re-run is enough — just the
phases that touch image overrides + ArgoCD syncing:

```bash
sudo bash /opt/Phantom-OS-KubernetesOptions/scripts/bootstrap-robot.sh \
  --image-overrides
```

Expected log lines:
- `phase 12: image overrides (inject kustomize.images per stack)`
- `injected: stack=core images=2 ...`  (positronic-control + phantom-models route to core)
- `patched phantomos-mk09-core kustomize.images: ["localhost:5443/positronic-control=foundationbot/phantom-cuda:0.2.42-dp", "localhost:5443/phantom-models:2026-05-09"]`
- No `unrouted` warnings for these two.

If any pods don't recycle on their own (they should, because Argo
sees the spec change and reconciles), nudge them:

```bash
sudo k0s kubectl -n positronic delete pod -l app=positronic-control
```

## Verify

```bash
# 1. Pods that aren't healthy.
sudo k0s kubectl get pods -A | grep -Ev 'Running|Completed'

# 2. The live kustomize.images overrides.
for stack in core operator; do
  echo "== phantomos-mk09-$stack =="
  sudo k0s kubectl -n argocd get application phantomos-mk09-$stack \
    -o jsonpath='{.spec.source.kustomize.images}'; echo
done

# 3. The actual image refs the positronic-control pod ended up with.
sudo k0s kubectl -n positronic get pod -l app=positronic-control \
  -o jsonpath='{.items[0].spec.containers[*].image}{"\n"}{.items[0].spec.initContainers[*].image}{"\n"}'

# 4. Confirm containerd is serving from local store (no recent pulls
#    from registry-1.docker.io for these refs).
sudo k0s kubectl -n positronic describe pod -l app=positronic-control \
  | grep -E 'Successfully pulled|already present'
```

Pass criteria:
1. `(2)` shows `localhost:5443/positronic-control=foundationbot/phantom-cuda:0.2.42-dp` and `localhost:5443/phantom-models:2026-05-09` in the core stack. operator-ui is **not** present (skipped override → manifest `:qa` applies).
2. `(3)` shows the positronic-control container running `foundationbot/phantom-cuda:0.2.42-dp` and the load-models initContainer running `localhost:5443/phantom-models:2026-05-09`.
3. `(4)` events say `Container image "..." already present on machine` rather than `Pulling image "..."` — proves containerd's local store served both refs without going to DockerHub or the registry pod.
4. `(1)` shows nothing positronic / phantom related (everything Running).

## Failure-mode triage

- `ImagePullBackOff` on `phantom-cuda:0.2.42-dp` after the steps above
  → containerd didn't import the tarball cleanly. Re-run the `k0s
  ctr ... images import` for that tar, check `k0s ctr -n k8s.io
  images list | grep phantom-cuda`. If the import says "ok" but the
  list doesn't show the ref, the tarball's `manifest.json` has a
  different tag — `tar -xOf <tar> manifest.json | jq` to inspect, and
  `docker tag` + `docker save` again with the right tag.
- `ImagePullBackOff` on `phantom-models:2026-05-09`
  → same drill. Note that this ref is `localhost:5443/*` so on a miss
  containerd talks to the registry pod (which is empty) — no
  DockerHub fallback. Local-store import is the only path.
- `unrouted` warning in phase 12 for either entry
  → the manifest was changed and `CONTAINER_TARGETS` in
  `scripts/lib/host-config.py:362` is stale. Update the
  `manifest_image` field for the affected container.
- operator-ui pod still pulling `:qa` and failing
  → the bundled tarball didn't import. Confirm with `sudo k0s ctr -n
  k8s.io images list | grep argus.operator-ui`. If empty, restart
  k0scontroller (`sudo systemctl restart k0scontroller`) which forces
  a re-scan of `/var/lib/k0s/images/`, then re-check.

## Cleanup / revert

To restore the previous host-config and re-inject the previous
overrides:

```bash
# Latest .bak file from the wizard's auto-backup:
ls -t /etc/phantomos/host-config.yaml.bak.* | head -1
sudo cp <that-file> /etc/phantomos/host-config.yaml
sudo bash /opt/Phantom-OS-KubernetesOptions/scripts/bootstrap-robot.sh \
  --image-overrides
```

The imported containerd images are harmless to leave in place — they
just take disk. To prune: `sudo k0s ctr -n k8s.io images rm <ref>`.
