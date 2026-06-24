#!/usr/bin/env bash
# diagnose-positronic.sh
#
# Investigates why the positronic-control pod is unhappy and (optionally)
# applies the per-robot overlay. Run from the repo root.
#
#   bash scripts/diagnose-positronic.sh           # report only
#   APPLY=1 bash scripts/diagnose-positronic.sh   # report + apply overlay
#
# Reports:
#   1. Pod status + recent events
#   2. Image availability (containerd local store + dockerhub-creds)
#   3. Rendered overlay's image references
#   4. Whether any :PLACEHOLDER strings survived the render
#
# Suggests the next concrete step based on what's wrong.

set -u -o pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
NAMESPACE="${NAMESPACE:-positronic}"
APP_LABEL="${APP_LABEL:-app=positronic-control}"
PULL_SECRET="${PULL_SECRET:-dockerhub-creds}"

# positronic-control lives in the `core` stack. The OVERLAY env var
# can override (e.g. point at a custom kustomize tree) but the default
# is no longer per-robot.
OVERLAY="${OVERLAY:-${REPO}/manifests/stacks/core}"

# kubectl resolution — robot has only `k0s kubectl`, laptops may have either.
KUBECTL=""
if command -v kubectl >/dev/null 2>&1; then
  KUBECTL="kubectl"
elif command -v k0s >/dev/null 2>&1 && k0s kubectl version --client >/dev/null 2>&1; then
  KUBECTL="k0s kubectl"
else
  echo "error: neither kubectl nor 'k0s kubectl' is available" >&2
  exit 2
fi

bold()  { printf '\n\033[1m%s\033[0m\n' "$1"; }
indent(){ sed 's/^/    /'; }
ok()    { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn()  { printf '  \033[33m!\033[0m %s\n' "$1"; }
fail()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }

# Track findings so we can decide the suggestion at the end.
problems=()

# --- 1. Pod ----------------------------------------------------------------

bold "1. Pod status (${NAMESPACE} / ${APP_LABEL})"
$KUBECTL -n "$NAMESPACE" get pod -l "$APP_LABEL" 2>&1 | indent || true

bold "2. Recent pod events"
events=$($KUBECTL -n "$NAMESPACE" describe pod -l "$APP_LABEL" 2>/dev/null \
         | awk '/^Events:/,0' | head -25 || true)
if [ -z "$events" ]; then
  warn "no events available — pod may not exist yet"
else
  echo "$events" | indent
fi

# --- 3. Image availability -------------------------------------------------
# Images are pulled from DockerHub (foundationbot/*). Two things make a
# pull succeed: the dockerhub-creds Secret is present in this namespace,
# and (for offline/air-gapped robots) the image was pre-imported into
# containerd's local store from a phantomos-k0s-images .deb.

bold "3. Pull-secret presence (${NAMESPACE}/${PULL_SECRET})"
if $KUBECTL -n "$NAMESPACE" get secret "$PULL_SECRET" >/dev/null 2>&1; then
  ok "${PULL_SECRET} present in ${NAMESPACE}"
else
  fail "${PULL_SECRET} missing in ${NAMESPACE} — DockerHub pulls of foundationbot/* will fail"
  problems+=("missing-pull-secret")
fi

bold "Local containerd image store (foundationbot/positronic-control, phantom-models)"
if command -v k0s >/dev/null 2>&1; then
  if imgs=$(k0s ctr -n k8s.io images list -q 2>/dev/null); then
    for img in positronic-control phantom-models; do
      match=$(printf '%s\n' "$imgs" | grep -E "foundationbot/${img}(:|@)" || true)
      if [ -n "$match" ]; then
        printf '%s\n' "$match" | indent
      else
        warn "foundationbot/${img}: not in containerd store (will pull from DockerHub)"
      fi
    done
  else
    warn "could not list containerd images (k0s ctr unavailable)"
  fi
else
  warn "k0s not on PATH — skipping containerd image-store check"
fi

# --- 4. Render the overlay ------------------------------------------------

bold "4. Rendered overlay (${OVERLAY})"
render=$(mktemp /tmp/positronic-render.XXXXXX.yaml)
trap 'rm -f "$render"' EXIT

if $KUBECTL kustomize "$OVERLAY" >"$render" 2>"${render}.err"; then
  ok "overlay renders cleanly"
  printf '  %s\n' "positronic-control container image:"
  grep -E '^\s+image:\s*foundationbot/positronic-control' "$render" | indent || warn "    no positronic-control image: line found"
  printf '  %s\n' "phantom-models volume reference:"
  awk '/name: models$/{flag=1} flag && /reference:/{print; flag=0}' "$render" | indent \
    || warn "    no phantom-models reference: line found"
else
  fail "kustomize render failed:"
  cat "${render}.err" | indent
  rm -f "${render}.err"
  problems+=("render-failed")
fi
rm -f "${render}.err"

# --- 5. PLACEHOLDER detector ----------------------------------------------

bold "5. PLACEHOLDER survival check"
if grep -q PLACEHOLDER "$render" 2>/dev/null; then
  fail "rendered overlay still contains PLACEHOLDER — patches not taking effect"
  grep PLACEHOLDER "$render" | indent
  problems+=("placeholder-in-render")
else
  ok "no PLACEHOLDER strings in rendered output"
fi

# --- 6. Decide what's next ------------------------------------------------

bold "Diagnosis"

placeholder_in_render=false
missing_pull_secret=false
for p in "${problems[@]:-}"; do
  case "$p" in
    placeholder-in-render) placeholder_in_render=true ;;
    missing-pull-secret) missing_pull_secret=true ;;
  esac
done

if [ "$missing_pull_secret" = true ]; then
  fail "dockerhub-creds is missing in ${NAMESPACE}"
  echo
  echo "  Seed it so foundationbot/* images can be pulled:"
  echo "    sudo bash scripts/bootstrap-robot.sh --seed-pull-secrets"
fi

if [ "$placeholder_in_render" = true ]; then
  fail "Strategic-merge patch isn't rewriting the image-volume reference."
  echo
  echo "  Likely fix: drop the patch and hardcode the tag in the base manifest."
  echo "  In manifests/base/positronic/positronic-control.yaml, change:"
  echo "      reference: foundationbot/phantom-models:PLACEHOLDER"
  echo "  to:"
  echo "      reference: foundationbot/phantom-models:<your-tag>"
  echo
  echo "  Image tag overrides now come from /etc/phantomos/host-config.yaml's"
  echo "  images: list — bump the tag there and run:"
  echo "      sudo bash scripts/bootstrap-robot.sh --image-overrides"
fi

if [ "${#problems[@]}" -eq 0 ]; then
  ok "rendered overlay looks correct."
  echo
  if [ "${APPLY:-}" = "1" ]; then
    echo "  APPLY=1 set — applying the overlay now."
    $KUBECTL apply -k "$OVERLAY"
    echo
    echo "  Bouncing the positronic-control pod so it picks up new images:"
    $KUBECTL -n "$NAMESPACE" delete pod -l "$APP_LABEL" --ignore-not-found
    echo
    echo "  Watching pod (Ctrl-C to exit):"
    $KUBECTL -n "$NAMESPACE" get pod -l "$APP_LABEL" -w
  else
    echo "  Apply with:"
    echo "    $KUBECTL apply -k $OVERLAY"
    echo "    $KUBECTL -n $NAMESPACE delete pod -l $APP_LABEL"
    echo
    echo "  Or re-run with APPLY=1 to do that automatically:"
    echo "    APPLY=1 $0"
  fi
fi

# Exit code = number of problems
exit "${#problems[@]}"
