variable "kubeconfig" {
  description = "Path to kubeconfig for target cluster. Default targets ch4 (the Session A POC cluster)."
  type        = string
  default     = "~/.kube/ch4-config"
}

variable "argocd_chart_version" {
  description = "argo-cd Helm chart version (from https://github.com/argoproj/argo-helm). Null = latest."
  type        = string
  default     = null
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

variable "root_app_manifest" {
  description = "Path to the root ArgoCD Application CR manifest, relative to this terraform module."
  type        = string
  default     = "../gitops/root-app.yaml"
}
