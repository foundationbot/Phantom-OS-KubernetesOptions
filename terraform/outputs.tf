output "argocd_ui_https" {
  description = "ArgoCD UI URL (accept self-signed cert)"
  value       = "https://<node-ip>:${var.argocd_https_nodeport}"
}

output "argocd_admin_password_command" {
  description = "Command to fetch the initial admin password (admin is the username)"
  value       = "kubectl --kubeconfig='${local.kubeconfig_path}' -n ${var.argocd_namespace} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}

output "root_application_name" {
  value = "root"
}

output "next_steps" {
  value = <<-EOT
    Cluster bootstrapped. ArgoCD is running and the root Application is applied.
    From here every workload comes from git — edit files under manifests/ or
    apps/ and push. ArgoCD reconciles within 3 min (or trigger immediate with
    `kubectl annotate application <name> argocd.argoproj.io/refresh=hard`).
  EOT
}
