variable "kubeconfig" {
  description = "Path to kubeconfig for target cluster. Default targets ch4 (the Session A POC cluster)."
  type        = string
  default     = "~/.kube/ch4-config"
}

variable "argocd_chart_version" {
  # Pinned to 7.6.12 (stable 7.x line, released 2024-10). SA names and key
  # values (dex.enabled, redisSecretInit.enabled) were verified against this
  # version's values.yaml. Bump within 7.x; verify SA names on major bumps.
  description = "argo-cd Helm chart version (from https://github.com/argoproj/argo-helm). SA names and key values (dex.enabled, redisSecretInit.enabled) verified against 7.6.12."
  type        = string
  default     = "7.6.12"
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

