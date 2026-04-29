# Credentials & operator onboarding

How to get every credential needed to operate this fleet, where each one currently lives, and how to rotate.

This doc complements [REQUIREMENTS.md](../REQUIREMENTS.md) (the prerequisite checklist) and [README.md](../README.md) (the cluster bring-up steps). Those tell you *what kubectl commands to run*; this one tells you *where the secret values come from*.

> **Status**: this is the best snapshot of the credential picture as of the time of writing. Several "owner" / "source" fields are explicitly marked as not known to the writer — chase those down and update this doc when you find out.

## Inventory

| Credential | What it is | Where it lives today | Used by |
|---|---|---|---|
| **DockerHub OAT** | `dckr_oat_*` Organization Access Token for the `foundationbot` Docker Hub org | `/root/.docker/config.json` on each robot; `~/.docker/config.json` on operator laptops; `dockerhub-creds` Secret in `argus`, `dma-video`, `nimbus` namespaces | Every pod that pulls a `foundationbot/*` image |
| **AWS IoT certs** | mTLS cert + private key + CA cert for AWS IoT Core endpoint `c4r067w5awayr.credentials.iot.us-west-1.amazonaws.com` | `/root/episode-agent/` on the robot (3 files: `cert.pem`, `private.key`, `root-CA.crt`); `iot-certs` Secret in `nimbus` namespace (commented out by default) | `nimbus/eg-jobs` for S3 upload via IoT Core |
| **GitHub App private key** | RSA PEM for the `phantom-fleet-argocd` GitHub App | 1Password (after the repo goes private) | ArgoCD on every robot, to mint short-lived installation tokens for git fetches |
| **ArgoCD admin password** | Auto-generated bcrypt password | `argocd-initial-admin-secret` Secret in `argocd` namespace until rotated through the UI | First UI login on each cluster |
| **On-robot kubeconfig** | k0s admin cert/key for the cluster | `/root/.kube/config` (written by `bootstrap-robot.sh`); also `/var/lib/k0s/pki/admin.conf` | Local kubectl on the robot, Terraform |
| **Operator-PC kubeconfig** | Same as on-robot kubeconfig but with `server:` rewritten to the Tailscale IP | `~/.kube/<robot>-config` on the operator's machine | Remote `kubectl` from the operator's PC over Tailscale |
| **Robot SSH** | `~/.ssh/id_ed25519` (operator's existing key, added to the robot's `authorized_keys` by the team) | Operator's laptop | All `ssh root@<robot>` access |

---

## DockerHub OAT

### Background

The `foundationbot` Docker Hub organization holds the private images that pods pull (`foundationbot/argus.*`, `foundationbot/dma-video`, `foundationbot/positronic-control`, etc.). Authentication is via a **Docker Hub Organization Access Token** (OAT) — token format `dckr_oat_*`. The OAT is org-level, not personal.

The OAT in current use **predates this repo**. It was placed on each robot's filesystem (`/root/.docker/config.json`) and on operator laptops (`~/.docker/config.json`) during the Compose-era robot provisioning, and is still what the old Compose stack used. The k0s migration just lifted the same config.json into Kubernetes Secrets — no new token was created. Setup-from-scratch for the OAT was not part of this project, so this doc only covers **recovery** and **distribution** of the existing token.

### Recovery — how to get the current OAT onto a fresh laptop

Pick whichever you can reach first:

```bash
# (a) From a robot you already have SSH access to (preferred)
ssh root@<robot-tailscale-ip> 'cat /root/.docker/config.json' > ~/.docker/config.json
chmod 600 ~/.docker/config.json

# (b) From any cluster's running k8s Secret
KUBECONFIG=~/.kube/<robot>-config kubectl get secret dockerhub-creds -n argus \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > ~/.docker/config.json
chmod 600 ~/.docker/config.json

# (c) Fresh `docker login` against the foundationbot account
#   — only works if you have the foundationbot org login or have been
#   added with permission to mint your own token.
docker login --username foundationbot
```

### Distribution — putting the OAT into a new robot's k8s

After bringing up a fresh cluster (per [README.md](../README.md)), create the pull secret in each namespace:

```bash
ssh root@<robot> 'cat /root/.docker/config.json' > /tmp/dockercfg.json
export KUBECONFIG=~/.kube/<robot>-config

for ns in argus dma-video nimbus; do
  kubectl create secret generic dockerhub-creds -n $ns \
    --from-file=.dockerconfigjson=/tmp/dockercfg.json \
    --type=kubernetes.io/dockerconfigjson
done

rm /tmp/dockercfg.json
```

If `/root/.docker/config.json` doesn't exist on the new robot yet (e.g., it was provisioned without the legacy Compose setup), copy from your operator laptop instead:

```bash
scp ~/.docker/config.json root@<robot>:/root/.docker/config.json
ssh root@<robot> 'chmod 600 /root/.docker/config.json'
```

### Rotation

The current rotation procedure is **not documented**. Rotating the OAT requires:

1. Admin access to the `foundationbot` Docker Hub organization. **Owner of that admin access is not known to the writer of this doc** — ask the team.
2. With admin access: Docker Hub UI → org settings → Access Tokens → revoke the old OAT, generate a new one.
3. Push the new token to every robot's `/root/.docker/config.json` and every operator laptop's `~/.docker/config.json`.
4. Re-create the `dockerhub-creds` Secret in each namespace on every cluster (use the distribution step above).
5. Restart pulls for every workload that needs to re-authenticate. Existing running pods are unaffected; new pulls will use the new token.

### Onboarding a new engineer

1. Existing operator with `foundationbot` admin: add the new engineer to the `foundationbot` Docker Hub organization (or share a personal account login depending on how the team is set up — also undocumented).
2. New engineer: `docker login --username foundationbot` on their laptop, populating `~/.docker/config.json`.
3. From there, the recovery + distribution steps above work.

---

## AWS IoT certs

### Background

`nimbus/eg-jobs` uploads recordings to S3 via AWS IoT Core. It authenticates to IoT Core with an X.509 certificate. The endpoint is hardcoded in [manifests/base/nimbus/eg-jobs.yaml](../manifests/base/nimbus/eg-jobs.yaml):

```
c4r067w5awayr.credentials.iot.us-west-1.amazonaws.com
```

(us-west-1.) Each robot has its certs at `/root/episode-agent/`:

```
/root/episode-agent/cert.pem
/root/episode-agent/private.key
/root/episode-agent/root-CA.crt
```

Like the DockerHub OAT, these files **predate this repo** — they were placed there by the pre-Compose-era robot provisioning. None of this repo's bootstrap creates or fetches them.

### Recovery / distribution

When `eg-jobs` is enabled (the `iot-certs` volume mount is **commented out by default** in `eg-jobs.yaml` — see TODO around line 48):

```bash
KUBECONFIG=~/.kube/<robot>-config kubectl -n nimbus create secret generic iot-certs \
  --from-file=/root/episode-agent/
```

That reads the three files from `/root/episode-agent/` and packs them into a Kubernetes Secret with one key per file. Then uncomment the `iot-certs` volume + volumeMount in `eg-jobs.yaml` and commit/push.

### Provisioning a new robot

For a new robot with no `/root/episode-agent/` directory: a new IoT certificate has to be issued by AWS IoT Core (us-west-1 account), saved to `/root/episode-agent/`, and the IoT thing registered with whatever fleet policy the team uses.

**I am unaware who gives this access.** The AWS account, IoT thing naming convention, and policy configuration are not documented in this repo and were not set up as part of this project. Whoever takes this over will need to find the AWS Console admin and document this section.

### Rotation

Same as provisioning — requires AWS IoT Core admin access, which is not documented.

---

## GitHub App (for the private repo)

See [github-app-auth.md](github-app-auth.md) for the full runbook.

Short version:
- One App registered against the `foundationbot` org, installed only on `Phantom-OS-KubernetesOptions`.
- Three values: App ID, Installation ID, Private Key (PEM).
- App ID + Installation ID are not secret. The Private Key is — store in 1Password.
- ArgoCD on each robot needs a `Repository` Secret in the `argocd` namespace containing all three; ArgoCD mints fresh 1-hour installation tokens from the App.
- Setup must be done on every robot **before** flipping the repo to private.

---

## ArgoCD admin password

ArgoCD generates an initial admin password at install time and stores it in a Secret in the `argocd` namespace.

### Recover the initial password

```bash
KUBECONFIG=~/.kube/<robot>-config kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
echo
```

### Rotation

Log into the ArgoCD UI as `admin` with the recovered password, then change it via Settings → User Info → Update Password. ArgoCD **auto-deletes the `argocd-initial-admin-secret` Secret** once the password is rotated. From that point on, the password is stored bcrypt-hashed in the `argocd-secret` Secret and there is no recovery without bouncing it (see ArgoCD docs for the password reset procedure if locked out).

The current password (post-bootstrap) on each cluster is wherever the operator who first logged in stashed it — **owner unknown**.

---

## On-robot kubeconfig

Generated automatically by [scripts/bootstrap-robot.sh](../scripts/bootstrap-robot.sh) phase 4. Equivalent manual command:

```bash
mkdir -p /root/.kube
sudo k0s kubeconfig admin > /root/.kube/config
chmod 600 /root/.kube/config
```

The k0s admin kubeconfig is regenerated from the cluster CA each time `k0s kubeconfig admin` runs, so it's safe to re-run.

---

## Operator-PC kubeconfig (the `~/.kube/<robot>-config` pattern)

To run `kubectl` from your laptop against a remote robot over Tailscale:

```bash
# 1. Pull the on-robot kubeconfig down
scp root@<robot-tailscale-ip>:/root/.kube/config ~/.kube/<robot>-config

# 2. Rewrite the server: line. The on-robot kubeconfig points at
#    localhost or the robot's local LAN IP. Your laptop can't reach
#    those — replace with the robot's Tailscale IP.
sed -i.bak 's|server: https://[^:]*:6443|server: https://<tailscale-ip>:6443|' ~/.kube/<robot>-config
rm ~/.kube/<robot>-config.bak

# 3. Lock it down
chmod 600 ~/.kube/<robot>-config
```

Use it via `KUBECONFIG=~/.kube/<robot>-config kubectl ...` (preferred when juggling multiple robots) or merge into your default config (`~/.kube/config`) with `kubectl config view --merge --flatten`.

### Naming convention

- mk09 → `~/.kube/mk09-config`
- ak-007 → `~/.kube/ak-007-config`

Tailscale IPs (from prior sessions, double-check current state):
- mk09: `100.124.202.97`

---

## SSH access to robots

Robots accept the operator's existing SSH public key (`~/.ssh/id_ed25519.pub`), added to `/root/.ssh/authorized_keys` by the team.

### Onboarding a new engineer

1. New engineer sends their public key (`cat ~/.ssh/id_ed25519.pub`) to whoever administers the robots.
2. Admin appends it to `/root/.ssh/authorized_keys` on each robot the new engineer needs access to.
3. New engineer connects: `ssh root@<robot-tailscale-ip>`.

Fallback: root password can also be used at the console for emergency recovery; password is **not** documented here. It exists in operator memory / informal notes only.

---

## "I just got this repo, what do I do" — onboarding walkthrough

For an engineer who has nothing but a laptop and read access to this repo:

1. **Get on the team Tailnet** (out of scope for this repo — ask the team admin).
2. **Get your SSH key onto the robots** (above).
3. **Get DockerHub access**: be added to the `foundationbot` org by an admin, then `docker login` on your laptop. Your `~/.docker/config.json` now has the OAT.
4. **Pull the kubeconfig** for each robot you'll operate:
   ```bash
   scp root@<robot-tailscale-ip>:/root/.kube/config ~/.kube/<robot>-config
   sed -i.bak 's|server: https://[^:]*:6443|server: https://<tailscale-ip>:6443|' ~/.kube/<robot>-config
   chmod 600 ~/.kube/<robot>-config
   ```
5. **Verify**: `KUBECONFIG=~/.kube/<robot>-config kubectl get nodes` should return `Ready`.
6. **Get the GitHub App private key from 1Password** if you need to rotate or troubleshoot ArgoCD's git auth (see [github-app-auth.md](github-app-auth.md)).

That's it for read-write operator access. If you also need to bring up a *new* robot from scratch, follow [README.md](../README.md) Steps 1–N and [REQUIREMENTS.md](../REQUIREMENTS.md) checklist.

---

## Known gaps (for whoever maintains this)

- [ ] **Owner of the `foundationbot` Docker Hub org** — needed for OAT rotation and for adding new engineers.
- [ ] **AWS IoT Core admin** — needed for issuing certs to new robots.
- [ ] **AWS account number / IoT thing naming convention / IoT policy** — for understanding the cert/identity model.
- [ ] **Whether each robot needs a unique IoT thing** or whether certs are shared across the fleet.
- [ ] **Where the rotated ArgoCD admin password goes** after first login — should be a vault entry per cluster.
- [ ] **Robot root password** — should be in 1Password, not in operator memory.
- [ ] **Long-term plan for secrets management.** REQUIREMENTS.md and architecture-decision-argocd-topology.md both reference External Secrets Operator + AWS Secrets Manager as a future iteration. Whoever takes this over should decide whether to commit to that path or pick a different one (e.g., sealed-secrets in git, sops, Doppler).
