# Terraform bootstraps a k8s cluster into "ArgoCD-managed" state.
# Beyond this file, nothing else should ever be kubectl-applied by hand —
# every subsequent change flows from git through ArgoCD.

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

# 3. Root Application CR (app-of-apps).
#    Using null_resource + local-exec because terraform's native
#    kubernetes_manifest requires the Application CRD to exist at plan
#    time — which it doesn't until the Helm release installs it. The
#    local-exec fires AFTER helm_release, when the CRD is present.
resource "null_resource" "root_application" {
  triggers = {
    manifest_hash   = filesha256("${path.module}/${var.root_app_manifest}")
    kubeconfig_path = local.kubeconfig_path
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = "kubectl --kubeconfig='${local.kubeconfig_path}' apply -f '${path.module}/${var.root_app_manifest}'"
  }

  depends_on = [helm_release.argocd]
}
