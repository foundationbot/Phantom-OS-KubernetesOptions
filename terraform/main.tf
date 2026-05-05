# Terraform bootstraps a k8s cluster into "ArgoCD-installed" state.
# It only installs the argocd Helm chart — it does NOT apply any
# Application CRs. The per-host Application that points argocd at this
# robot's overlay is rendered + applied by scripts/bootstrap-robot.sh
# from a template + /etc/phantomos/host-config.yaml. The repo carries
# no per-robot Application files; that data is per-device and lives
# outside git (or, eventually, comes from a fleet control plane).

locals {
  kubeconfig_path = pathexpand(var.kubeconfig)
}

provider "kubernetes" {
  config_path = local.kubeconfig_path
}

provider "helm" {
  kubernetes {
    config_path = local.kubeconfig_path
  }
}

# 1. argocd namespace (Helm chart creates CRDs etc. inside it)
resource "kubernetes_namespace" "argocd" {
  metadata {
    name = var.argocd_namespace
    labels = {
      "app.kubernetes.io/part-of" = "argocd"
      "managed-by"                = "terraform"
    }
  }
}

# 2. ArgoCD via the official Helm chart.
#    Replaces the raw-manifest install we did in session B (which needed
#    --server-side to dodge the "annotation too long" CRD quirk). Helm
#    handles CRD creation correctly and makes upgrades trivial.
resource "helm_release" "argocd" {
  name       = "argocd"
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version

  values = [yamlencode({
    server = {
      service = {
        type          = "NodePort"
        nodePortHttp  = var.argocd_http_nodeport
        nodePortHttps = var.argocd_https_nodeport
      }
    }
  })]

  wait           = true
  wait_for_jobs  = true
  timeout        = 600
  atomic         = false
}

