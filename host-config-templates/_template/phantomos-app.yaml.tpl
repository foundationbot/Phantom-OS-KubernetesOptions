# ArgoCD Application CR template — rendered ONCE PER STACK per-host at
# bringup by scripts/bootstrap-robot.sh. One Application per stack:
# phantomos-<robot>-core, phantomos-<robot>-operator, ... Each rendered
# copy lives at /etc/phantomos/phantomos-app-<stack>.yaml. Not in git.
#
# Substitutions performed by bootstrap (sed):
#   {{ROBOT}}            robot identity (e.g. mk09, mk11000010)
#   {{STACK}}            stack name (core, operator)
#   {{REPO_URL}}         git URL of this repo
#   {{TARGET_REVISION}}  branch/tag/sha to track (from host-config.yaml,
#                        default: main)
#   {{SELF_HEAL}}        true|false. Driven by stacks.<stack>.selfHeal
#                        (when set), else top-level production: field,
#                        else --production / --no-production CLI flag.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: phantomos-{{ROBOT}}-{{STACK}}
  namespace: argocd
  labels:
    app.kubernetes.io/part-of: phantomos-{{ROBOT}}
    phantomos.foundation.bot/stack: {{STACK}}
  # Don't prune Application children when this CR is deleted — manual
  # deletes are usually mistakes during ops, not intentional teardowns.
  # Bootstrap removes the finalizer explicitly when migrating.
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: {{REPO_URL}}
    targetRevision: {{TARGET_REVISION}}
    path: manifests/stacks/{{STACK}}
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: {{SELF_HEAL}}
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
  # Don't reconcile fields populated by the binding controller — without
  # this, ArgoCD strips the runtime-added claimRef.uid back to whatever
  # the manifest declares (just name+namespace), and the bound PVC
  # eventually drops to status.phase: Lost.
  ignoreDifferences:
    - group: ""
      kind: PersistentVolume
      jsonPointers:
        - /spec/claimRef/uid
        - /spec/claimRef/resourceVersion
        - /spec/claimRef/apiVersion
        - /spec/claimRef/kind
    - group: ""
      kind: PersistentVolumeClaim
      jsonPointers:
        - /spec/volumeName
        - /metadata/annotations/pv.kubernetes.io~1bind-completed
        - /metadata/annotations/pv.kubernetes.io~1bound-by-controller
