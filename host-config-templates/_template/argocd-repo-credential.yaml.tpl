# Template for /etc/phantomos/argocd-repo-credential.yaml.
#
# Copy to the canonical path (mode 0600, owner root:root) and replace the
# placeholders. NEVER commit the filled file to git; bootstrap will refuse
# to apply it from inside a git work tree.
#
#   sudo install -m 0600 -o root -g root \
#       argocd-repo-credential.yaml /etc/phantomos/argocd-repo-credential.yaml
#
# Two variants — keep ONE block, delete the other.
apiVersion: v1
kind: Secret
metadata:
  name: phantomos-kos-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://github.com/foundationbot/Phantom-OS-KubernetesOptions
  # ---- Variant A: GitHub App (preferred) -------------------------------
  githubAppID: "REPLACE-WITH-APP-ID"
  githubAppInstallationID: "REPLACE-WITH-INSTALLATION-ID"
  githubAppPrivateKey: |
    -----BEGIN RSA PRIVATE KEY-----
    REPLACE-WITH-PRIVATE-KEY-LINES
    -----END RSA PRIVATE KEY-----
  # ---- Variant B: fine-grained PAT (fallback) --------------------------
  # username: x-access-token
  # password: REPLACE-WITH-PAT
