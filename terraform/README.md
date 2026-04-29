# Terraform: ArgoCD + GitOps Root Bootstrap

Runs on your local machine. Given an empty k8s cluster (k0s, kind, whatever),
a single `terraform apply` brings it to the "ArgoCD-managed" state:

1. `argocd` namespace
2. ArgoCD installed via the official Helm chart, exposed via NodePort
3. Root Application CR (app-of-apps pattern) applied

From there, **nothing else** on the cluster should be kubectl-applied by hand.
Every change flows through git → ArgoCD.

## Prerequisites

- Terraform >= 1.10
- kubectl in `PATH`
- A kubeconfig pointing at a cluster with cluster-admin access (k0s
  generates one via `sudo k0s kubeconfig admin > ~/.kube/config`)
- The cluster must exist already (this module does **not** provision k0s)

The repo's `scripts/bootstrap-robot.sh` handles all four prerequisites
automatically (installs Terraform binary in phase 2, brings up k0s in
phase 4, writes `/root/.kube/config` from `k0s kubeconfig admin`, then
runs this module in phase 5). Use it on a fresh machine; come back here
manually only when iterating on the Terraform definitions themselves.

## Usage

Default target is ch4 (the Session A POC cluster):

```bash
cd terraform
terraform init
terraform apply
```

For a different cluster:

```bash
terraform apply -var='kubeconfig=~/.kube/robot-prod'
```

To pin the ArgoCD chart version instead of using latest:

```bash
terraform apply -var='argocd_chart_version=7.8.23'
```

## What Terraform **does not** manage

- **k0s itself**: install manually per node (see repo root `README.md`)
- **Workloads**: argus, dma-video, nimbus, hello — ArgoCD handles all of these
- **`dockerhub-creds` Secret**: create manually per namespace (it's a credential; belongs in a secret management tool, not in git)
- **ArgoCD admin password rotation**: default initial secret lives in the cluster

## Outputs

After `apply`, useful info:

```bash
terraform output argocd_ui_https                 # URL for the UI
eval $(terraform output -raw argocd_admin_password_command)   # grab initial admin password
```

## State backend

Local for the POC (`terraform.tfstate` in this directory). Before production:

- Move to S3 + DynamoDB lock, Terraform Cloud, or GCS
- Don't commit state files (already `.gitignore`d)

## Removing everything

```bash
terraform destroy
```

This deletes:
- The root Application (which cascades to all child Applications, which delete all workloads — ArgoCD finalizers handle the cleanup)
- ArgoCD Helm release
- `argocd` namespace

k0s itself and node-level artifacts are untouched — use `k0s reset` for that.
