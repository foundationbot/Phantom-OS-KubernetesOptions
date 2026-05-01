# Host config templates

Per-host configuration that ArgoCD intentionally does **not** manage.
Files in this tree are templates — they are not deployed by the
`gitops/` app-of-apps and not referenced by any `kustomization.yaml`.

The bootstrap script (`scripts/bootstrap-robot.sh`) reads from and writes
to `/etc/phantomos/` on the host. These templates are the canonical
"copy-this-to-/etc/phantomos/" defaults for each known robot, plus a
generic `_template/` for new robots.

## Layout

```
host-config-templates/
├── README.md                           ← you are here
├── _template/                          ← starting point for a new robot
│   └── operator-ui-pairing.yaml
├── mk09/
│   └── operator-ui-pairing.yaml        ← AI PC: 100.124.202.97
├── ak-007/
│   └── operator-ui-pairing.yaml        ← AI PC: 100.85.53.56
├── mk11-generic/
│   └── operator-ui-pairing.yaml        ← AI PC: 100.85.53.56
└── mk11000010/
    └── operator-ui-pairing.yaml        ← AI PC: TODO (set on first bringup)
```

Each robot directory mirrors the eventual contents of `/etc/phantomos/`
on that machine. Stage B and C of the per-host-config feature add more
files here (image tag overrides, dev hostPath mounts).

## Migrating an existing robot

These templates were generated from the per-robot Kustomize patches
that lived in `manifests/robots/<robot>/patches/operator-ui-env.yaml`
before the AI_PC_URL move. To migrate a robot already running an older
overlay:

```bash
# On the robot, with this repo checked out:
sudo mkdir -p /etc/phantomos
sudo cp host-config-templates/<robot>/operator-ui-pairing.yaml \
        /etc/phantomos/operator-ui-pairing.yaml
sudo bash scripts/bootstrap-robot.sh                   # re-applies the CM
```

`bootstrap-robot.sh --ai-pc-url http://X.X.X.X:5000` will overwrite the
file with a fresh value when you want to re-pair.

## Bringing up a new robot

```bash
sudo bash scripts/bootstrap-robot.sh \
  --robot <name> \
  --ai-pc-url http://<tailscale-ip>:5000
```

The script writes `/etc/phantomos/operator-ui-pairing.yaml` from the
flag value. Use `_template/operator-ui-pairing.yaml` if you want to
hand-place the file before running bootstrap (e.g. on an air-gapped
machine).
