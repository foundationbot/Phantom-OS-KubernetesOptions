# DockerHub pull secret (`dockerhub-creds`)

The DaemonSets and Deployments that pull `foundationbot/*` images from
DockerHub reference a per-namespace `imagePullSecret` named
`dockerhub-creds`. The Secret itself is not in git — the operator creates
it on each robot during bring-up. This doc covers the easiest way to do
that when the robot already has a working `~/.docker/config.json`.

See also: `REQUIREMENTS.md` (the per-namespace list and the
`--docker-password=<PAT>` flow that this doc supersedes when a working
docker login already exists on the host).

---

## TL;DR — copy the working docker config into the cluster

```bash
# Substitute the namespace as needed: phantom, argus, dma-video, nimbus, registry
NS=phantom

k0s kubectl -n "$NS" create secret generic dockerhub-creds \
  --from-file=.dockerconfigjson="$HOME/.docker/config.json" \
  --type=kubernetes.io/dockerconfigjson \
  --dry-run=client -o yaml \
  | k0s kubectl apply -f -
```

The `--dry-run=client | apply -f -` form is idempotent — it creates the
Secret if missing and replaces it if it already exists. No need to delete
first.

Verify:

```bash
k0s kubectl -n "$NS" get secret dockerhub-creds
k0s kubectl -n "$NS" get secret dockerhub-creds \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d
```

The decoded payload should show `"auths"` with
`"https://index.docker.io/v1/"` and an `"auth": "<base64>"` (or
`"username"`/`"password"`) field. If `"auth"` decodes to
`foundationbot:<PAT>`, you're set.

---

## When this approach is the right one

Use the `--from-file` flow when:

- The robot's `docker pull foundationbot/<image>:<tag>` already works
  from the shell. That proves the credentials in
  `~/.docker/config.json` are valid for the repos you need.
- You don't want to copy a PAT through your shell history (the
  `--docker-password=<PAT>` flow does).

Don't use it when:

- The robot uses a credential helper / credstore (Mac keychain,
  `secretservice`, etc.) — the `auths` block in `config.json` will be
  empty and the file will only carry `"credsStore": "<helper>"`. In
  that case the credentials are off-disk and `--from-file` carries
  nothing useful. Fall back to the `--docker-password=<PAT>` flow:

  ```bash
  k0s kubectl -n "$NS" create secret docker-registry dockerhub-creds \
    --docker-server=https://index.docker.io/v1/ \
    --docker-username=foundationbot \
    --docker-password='<PAT>'
  ```

To detect a credstore beforehand:

```bash
grep -E 'credsStore|credHelpers' "$HOME/.docker/config.json" || \
  echo "no credstore — --from-file is safe"
```

---

## After replacing the Secret: kick the failing pods

The kubelet caches pull failures with exponential backoff. After a new
Secret lands, existing `ImagePullBackOff` pods don't immediately retry
with the new credentials. Force a fresh pull by deleting the pods —
the DaemonSet/Deployment recreates them and the kubelet loads the
current Secret:

```bash
# adjust selector for the workload you're fixing
k0s kubectl -n "$NS" delete pod -l app.kubernetes.io/name=yovariable-server
k0s kubectl -n "$NS" delete pod -l app.kubernetes.io/name=phantomos-api-server

k0s kubectl -n "$NS" get pods -w
```

---

## Rotation

When the foundationbot DockerHub PAT rotates:

1. Run `docker login -u foundationbot` on each robot with the new PAT.
   That refreshes `~/.docker/config.json`.
2. Re-run the `kubectl create secret ... | apply -f -` block above for
   each namespace that uses the Secret.
3. Delete the running pods (or wait for the next pull) so the kubelet
   picks up the new credentials.

Namespaces currently using `dockerhub-creds` (per
`grep -rn imagePullSecrets manifests/base/`):

- `argus`
- `dma-video`
- `nimbus`
- `phantom`

The same loop also applies on each fresh-bootstrapped robot — the
secret is part of every namespace's bring-up, not a one-time
fleet-wide step.

---

## Troubleshooting

| Symptom (from `kubectl describe pod` events) | Likely cause | Fix |
|---|---|---|
| `pull access denied` / `insufficient_scope: authorization failed` | No Secret in the namespace, or pod missing `imagePullSecrets:` | Create the Secret, confirm the pod template references it |
| `failed to fetch oauth token: ... 401 Unauthorized` | Secret exists but the PAT is wrong, expired, or lacks scope | Run `docker login -u foundationbot` with the right PAT, then redo `--from-file` |
| `failed to fetch oauth token: ... 429 Too Many Requests` | Rate-limited by DockerHub from too many failed retries | Pause the DaemonSet (set a nodeSelector that no node satisfies), wait 30+ min, restore |
| `failed to resolve reference "foundation.bot/..."` | Image name uses a placeholder registry domain (`foundation.bot/...` instead of `foundationbot/...`) | Fix the image reference in the manifest — this isn't a creds issue |

When in doubt, the fastest "are creds the problem?" check is:

```bash
docker pull foundationbot/<image>:<tag>
```

run on the same host. If that succeeds, the host has working creds in
`~/.docker/config.json`; the kubelet's failure is then either a missing
Secret or a missing `imagePullSecrets:` reference — not a credentials
problem per se.
