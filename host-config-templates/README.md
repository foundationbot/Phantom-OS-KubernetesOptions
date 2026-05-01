# Host config templates

> **New here?** Start with the layman walkthrough at
> [`docs/bringing-up-a-robot.md`](../docs/bringing-up-a-robot.md). This
> file is reference material for the templates themselves.

Per-host configuration that ArgoCD intentionally does **not** manage.
Files in this tree are templates — they are not deployed by the
`gitops/` app-of-apps and not referenced by any `kustomization.yaml`.

The bootstrap script (`scripts/bootstrap-robot.sh`) reads from and writes
to `/etc/phantomos/` on the host. These templates are the canonical
"copy-this-to-/etc/phantomos/" defaults for each known robot, plus a
generic `_template/` for new robots.

## Single source of truth: `host-config.yaml`

Each robot's directory contains a `host-config.yaml` describing its
identity, AI PC pairing, and image tag overrides. Bootstrap reads this
file and:

- writes `robot:` to `/etc/phantomos/robot`
- renders `/etc/phantomos/operator-ui-pairing.yaml` from `aiPcUrl:`
- patches the live `phantomos-<robot>` Argo Application's
  `spec.source.kustomize.images` from the `images:` list

The matching `operator-ui-pairing.yaml` template is kept as a fallback
for partial migrations (Stage A only).

## Layout

```
host-config-templates/
├── README.md                          ← you are here
├── _template/
│   ├── host-config.yaml               ← starting point for a new robot
│   └── operator-ui-pairing.yaml
├── mk09/
│   ├── host-config.yaml               ← canonical mk09 config
│   └── operator-ui-pairing.yaml
├── ak-007/
│   ├── host-config.yaml
│   └── operator-ui-pairing.yaml
├── mk11-generic/
│   ├── host-config.yaml
│   └── operator-ui-pairing.yaml
└── mk11000010/
    ├── host-config.yaml
    └── operator-ui-pairing.yaml
```

## Migrating an existing robot

```bash
# On the robot, with this repo checked out:
sudo bash scripts/bootstrap-robot.sh \
  --host-config host-config-templates/<robot>/host-config.yaml
```

That single command:
1. installs `host-config-templates/<robot>/host-config.yaml` to
   `/etc/phantomos/host-config.yaml`,
2. resolves the robot identity, persists it,
3. renders + applies the operator-ui pairing ConfigMap,
4. injects per-host image tags into the Argo Application,
5. triggers a sync.

## Bringing up a new robot

```bash
sudo cp host-config-templates/_template/host-config.yaml \
        /etc/phantomos/host-config.yaml
sudo $EDITOR /etc/phantomos/host-config.yaml      # set robot, aiPcUrl, image tags
sudo bash scripts/bootstrap-robot.sh
```

Or pass everything via flags on a fresh machine:

```bash
sudo bash scripts/bootstrap-robot.sh \
  --robot <name> \
  --ai-pc-url http://<tailscale-ip>:5000
```

In that case bootstrap will not inject image overrides (no
host-config.yaml on disk), and the overlay's `images:` block in
`manifests/robots/<robot>/kustomization.yaml` is the active source. Add
a `host-config.yaml` later when you want per-host image control.

## Schema

```yaml
robot: <name>                      # required, must match manifests/robots/<name>
aiPcUrl: http://<host>:<port>      # required for operator-ui pairing

# Optional. List of kustomize image overrides applied to the live Argo
# Application. Each entry MUST have name + newTag. newName is optional.
images:
  - name: <image-ref>
    newTag: <tag>
    # newName: <renamed-image-ref>   # optional
```

## Why a paper-trail file in `/etc/phantomos/`?

ArgoCD treats `spec.source.kustomize.images` as state on the cluster.
Without a host-side record, "what's mk09 paired with right now / what
tags did we pin?" requires `kubectl get app phantomos-mk09 -o yaml` and
parsing live state. The host file gives operators a stable answer that
survives cluster wipe + re-bootstrap (`--reset` preserves
`/etc/phantomos/`).

The git tree intentionally does **not** carry these values — every
robot has different AI PCs, different locally-built tags, and the
fleet is managed via SSH and bootstrap, not via PRs to image tag
values.
