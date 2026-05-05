# RFC 0001 — Fleet control plane (decouple repo from per-device deployment)

**Status:** Draft
**Author:** TBD
**Created:** 2026-05-01

## Problem

Stages A through F (shipped on `feat/per-host-pairing-and-robot-id` and
`feat/per-stack-applications`) moved per-device knowledge — robot identity,
AI PC pairings, image tag overrides, hostPath mounts — out of git and into
`/etc/phantomos/host-config.yaml` on each device. The repo is a library
now: identical on every robot, per-host data lives only on the device.
Stage F additionally split the umbrella Application into per-stack children
(`phantomos-<robot>-core`, `phantomos-<robot>-operator`) and replaced the
narrow `devMode:` schema with the general `deployments:` schema.

That works for tens of robots; it does not work for a million. The remaining
gap: the operator must still SSH to a device to edit its `host-config.yaml`,
and the canonical record of "what's on mk09" is whatever happens to be on
the disk in `/etc/phantomos/` right now. At fleet scale per-device data must
live in a **fleet control plane** that is queried by hardware identity at
bringup; the device pulls its config rather than holding it.

## Goals

1. The repo no longer references any specific robot. No host-config templates
   per robot. No branch named after a robot. No `manifests/robots/<name>/`.
   Overlays parameterized by host-config, not by name.
2. Devices identify themselves via **robot serial** (read from
   `/sys/class/dmi/id/product_serial` or equivalent on aarch64). Bootstrap
   queries the fleet control plane with this serial; control plane returns
   the rendered host-config + Application CR.
3. Operators manage the fleet through the control plane (UI / API / Terraform
   provider), not through PRs to this repo.
4. Existing devices migrate without an outage.

## Non-goals (for this RFC)

- Choice of control-plane runtime (Postgres + API service vs. Argo
  ApplicationSet vs. Kubernetes operator). Compared in a sibling RFC.
- Exact serial-to-config schema. Driven by control-plane choice.
- Runtime provisioning of new devices (PXE, image pipelines). Out of scope.

## Proposed shape

### Robot identity = serial

```
$ cat /sys/class/dmi/id/product_serial      # x86_64 dev boxes
PFXXXXX

$ cat /sys/firmware/devicetree/base/serial-number  # aarch64 robots
1234567890ABCDEF
```

Bootstrap reads this once and treats it as the canonical hwid. The current
`robot:` field in `host-config.yaml` (e.g. `mk09`) becomes a logical name
returned by the control plane, not something an operator types.

### Control plane API (sketch)

```
GET /v1/devices/{serial}/host-config
   200: text/yaml — rendered host-config.yaml
   404: device not registered

GET /v1/devices/{serial}/phantomos-app
   200: text/yaml — rendered Argo Application CR

POST /v1/devices/{serial}/heartbeat
   body: { kernel, uptime, k0s_version, app_status }
   200: ack
```

The control plane authenticates devices via mTLS (cert provisioned at imaging
time) or Tailscale identity, depending on chosen runtime.

### Bootstrap on the device

```bash
sudo bash scripts/bootstrap-robot.sh --fleet-api https://fleet.foundation.bot
```

Internally:
1. Read serial.
2. `curl --cert <device-cert> https://fleet.../v1/devices/<serial>/host-config -o /etc/phantomos/host-config.yaml`
3. `curl ... /phantomos-app | kubectl apply -f -`
4. Run the existing pairing / image-overrides / dev-mounts phases against
   the host-config we just fetched.

`--host-config <path>` (Stage D's input) remains as a fallback for
disconnected/dev environments and for offline imaging.

### Migration

- **Phase 0 (already done — Stages A–F).** Repo carries no per-robot data.
  Per-robot values live in each device's `/etc/phantomos/host-config.yaml`.
  Team runbook holds the canonical record while we get the control plane up.
  Per-stack Applications, image overrides via `kustomize.images` injection,
  hostPath mounts via `kustomize.patches` injection. See
  [docs/architecture.md](../architecture.md) for the post-Phase-0 design.
- **Phase 1 (this RFC's implementation):** stand up the control plane.
  Bulk-register existing robots in it (read each device's
  `/etc/phantomos/host-config.yaml`, POST to the API, key by serial).
- **Phase 2:** robots opt in by adding `--fleet-api` to their bootstrap
  command. Existing `--host-config` flow keeps working.
- **Phase 3:** retire the runbook's per-robot config table — control
  plane is the only source of truth. `host-config-templates/_template/`
  in the repo stays as the schema reference.
- **Phase 4:** parameterize `manifests/stacks/<name>/` overlays via
  Kustomize components selected by the rendered Application CR. Eventual
  goal: a single generic overlay tree, fully driven by per-host config.

## Open questions

1. **Control plane runtime.** Three serious candidates:
   a. Custom service (Postgres + Go/Node API). Most flexible, most code to own.
   b. Argo CD ApplicationSet with cluster generators. Devices are remote
      "clusters"; ApplicationSet enumerates them and spawns per-device
      Applications. Less code, but couples us to Argo and requires inbound
      reachability of every device from the central Argo.
   c. Kubernetes operator (`Robot` CRD on a central management cluster) that
      reconciles per-device manifests via SSH/agent. Mid-complexity.
2. **Cert provisioning.** How do new robots get a device cert? PKI on the
   imaging pipeline? Short-lived tokens at first boot?
3. **Offline operation.** A robot that loses its uplink — does it keep
   running on the last cached host-config until reachable, or fail-loud?
   First answer is almost certainly "keep running."
4. **Audit trail.** Today a `git log` answers "what changed about mk09?" In
   the new world, control plane needs an equivalent — append-only history
   of host-config and Application CR snapshots per device.
5. **Image registry strategy at scale.** `localhost:5443` works per-device
   but means every robot rebuilds its locally-built images. Likely needs a
   CDN-backed registry mirror or content-addressable distribution.

## What this RFC does NOT change

- The shape of the manifests under `manifests/`. Overlays are still
  Kustomize. ArgoCD still applies them.
- The bootstrap script's per-host phases (pairing, image overrides, dev
  mounts). Those keep working — they just consume a host-config the
  control plane sent rather than one the operator typed.
- Stage A–D semantics. This RFC is the next step beyond, not a redesign of
  what we already shipped.

## Decision needed

Before implementing:

- [ ] Pick control plane runtime (a / b / c).
- [ ] Define `robot serial` extraction across the device families we ship.
- [ ] Sign off on the API surface above (or revise).
- [ ] Agree on a migration timeline for the four existing robots.

Once the runtime is picked, file follow-up RFCs for:
- API/schema details
- Cert / identity provisioning
- Cache and offline behaviour
- Audit / event log
