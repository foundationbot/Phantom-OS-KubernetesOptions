variable "kubeconfig" {
  description = "Path to kubeconfig for target cluster. Default targets ch4 (the Session A POC cluster)."
  type        = string
  default     = "~/.kube/ch4-config"
}

variable "argocd_chart_version" {
  # Pinned to 9.5.11 — ships ArgoCD server v3.3.9, which matches the argocd
  # CLI version that bootstrap-robot.sh's _install_argocd_cli currently
  # downloads (latest release). Earlier 7.x line shipped server v2.x and
  # caused gRPC-version mismatches with v3 CLIs. SA names and key values
  # (dex.enabled, redisSecretInit.enabled, server.service.nodePortHttp/s)
  # verified against this chart version's values.yaml. Bump within 9.x;
  # verify SA names + values keys on major bumps (9.x → 10.x).
  description = "argo-cd Helm chart version. SA names + key values verified against 9.5.11."
  type        = string
  default     = "9.5.11"
}

variable "argocd_namespace" {
  type    = string
  default = "argocd"
}

variable "argocd_http_nodeport" {
  type    = number
  default = 30081
}

variable "argocd_https_nodeport" {
  type    = number
  default = 30443
}

