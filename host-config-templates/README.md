# Host config templates

> **New here?** Start with the layman walkthrough at
> [`docs/bringing-up-a-robot.md`](../docs/bringing-up-a-robot.md). This
> file is reference material for the templates themselves.

This directory holds **generic templates only** — schema examples that
get filled in per-host on the device. The repo intentionally carries no
per-robot data; that lives on each robot under `/etc/phantomos/` and
will eventually be served by a fleet control plane (see
[`../docs/rfcs/0001-fleet-control-plane.md`](../docs/rfcs/0001-fleet-control-plane.md)).

The bootstrap script (`scripts/bootstrap-robot.sh`) reads from and writes
to `/etc/phantomos/` on the host. The wizard
(`scripts/configure-host.sh`) walks operators through filling in the
fields interactively.

## Layout

```
host-config-templates/
├── README.md                       ← you are here
└── _template/
    ├── host-config.yaml            ← per-host config schema, with REPLACE-... placeholders
    ├── operator-ui-pairing.yaml    ← the ConfigMap bootstrap renders from aiPcUrl
    └── phantomos-app.yaml.tpl      ← ArgoCD Application CR template (rendered per-host at bringup)
```

## Single source of truth: `host-config.yaml`

`/etc/phantomos/host-config.yaml` on the device holds robot identity, AI
PC pairing, image tag overrides, target git revision, and (optionally)
dev-mode mounts. Bootstrap reads this file and:

- writes `robot:` to `/etc/phantomos/robot`
- renders `/etc/phantomos/operator-ui-pairing.yaml` from `aiPcUrl:`
- renders `/etc/phantomos/phantomos-app.yaml` (the ArgoCD Application CR
  for this host) from `_template/phantomos-app.yaml.tpl` using `robot:`
  + `targetRevision:`
- patches the live `phantomos-<robot>` Application's
  `spec.source.kustomize.images` from the `images:` list
- (if `devMode:` is present) injects a strategic-merge patch into
  `spec.source.kustomize.patches`

## Bringing up a new robot

```bash
sudo bash scripts/configure-host.sh   # interactive wizard, defaults from _template/
sudo bash scripts/bootstrap-robot.sh
```

The wizard offers to chain into bootstrap automatically.

## Bringing up a robot that already exists in the fleet (e.g. mk09)

Until the fleet control plane is in place, operational knowledge of
existing robots' values (AI PC IP, image tags, target revision) lives
in the team runbook — **not** in this repo. To recover or re-image:

```bash
# Option A — copy from a working sibling
ssh <other-mk09-host> "sudo cat /etc/phantomos/host-config.yaml" \
  | sudo tee /etc/phantomos/host-config.yaml
sudo bash scripts/bootstrap-robot.sh

# Option B — fill in interactively from the runbook
sudo bash scripts/configure-host.sh
sudo bash scripts/bootstrap-robot.sh
```

## Schema

See `_template/host-config.yaml` for the annotated reference. In short:

```yaml
robot: <name>                      # required, must match manifests/robots/<name>
aiPcUrl: http://<host>:<port>      # required for operator-ui pairing
targetRevision: main               # optional, ArgoCD branch/tag/SHA to track

# Optional. Per-host kustomize image overrides applied to the live
# ArgoCD Application. Each entry MUST have name + newTag.
images:
  - name: <image-ref>
    newTag: <tag>
    # newName: <renamed-image-ref>   # optional

# Optional. Dev-mode hostPath mounts for positronic-control. Bootstrap
# injects this as a strategic-merge patch into the Application's
# kustomize.patches. Production robots leave this out.
devMode:
  positronic-control:
    source: /absolute/path/to/source
    mounts:
      - {host: /data, container: /data}
    privileged: false
```

## Why no per-robot files in the repo?

ArgoCD treats `spec.source.kustomize.{images,patches}` as state on the
cluster. Without a host-side record, "what's this robot pinned to right
now?" requires `kubectl get app phantomos-<robot> -o yaml`. The host
file gives operators a stable answer that survives cluster wipe + re-
bootstrap (`--reset` preserves `/etc/phantomos/`).

The git tree intentionally does not carry these values. Every robot has
different AI PCs, different locally-built tags, and the fleet will not
be managed by PRs to image tag values. See the RFC link above for the
end-state design.
