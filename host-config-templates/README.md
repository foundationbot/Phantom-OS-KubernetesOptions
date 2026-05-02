# Host config templates

Generic, per-device config templates. Not deployed by ArgoCD, not
referenced by any `kustomization.yaml`. The repo carries **no
per-robot data**; this directory only holds the schema reference and
the Application CR template that bootstrap renders per-host.

## What's in here

```
host-config-templates/
├── README.md                       (this file)
└── _template/
    ├── host-config.yaml            ← annotated schema for /etc/phantomos/host-config.yaml
    ├── operator-ui-pairing.yaml    ← reference for the operator-ui pairing CM
    └── phantomos-app.yaml.tpl      ← ArgoCD Application CR template (rendered per-host)
```

The bootstrap script (`scripts/bootstrap-robot.sh`) and the wizard
(`scripts/configure-host.sh`) both read from `_template/` when
generating per-host artifacts under `/etc/phantomos/` on the device.

## Where to start

- New here? Read [`docs/architecture.md`](../docs/architecture.md) for the
  design and [`docs/operations.md`](../docs/operations.md) for the
  operator runbook.
- Bringing up a robot? `sudo bash scripts/configure-host.sh` then
  `sudo bash scripts/bootstrap-robot.sh`. Operations doc above has
  full walkthroughs.
- Want to read the schema? See `_template/host-config.yaml` for the
  annotated example, and the schema section of architecture.md for
  field-by-field documentation.

## Why no per-robot subdirectories?

Earlier stages of this codebase shipped with `mk09/`, `ak-007/`, etc.
under this directory holding pre-filled host-config files for known
robots. Stage E removed them: keeping per-robot data in the repo was
the same anti-pattern the rest of Stage D set out to fix. Operators
SSH to a working sibling robot (or read the team runbook) to see what
values a given robot uses; eventually that record moves into the
fleet control plane (see
[`../docs/rfcs/0001-fleet-control-plane.md`](../docs/rfcs/0001-fleet-control-plane.md)).
