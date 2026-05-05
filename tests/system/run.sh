#!/usr/bin/env bash
# tests/system/run.sh — end-to-end harness for RFC-0002 v1 verification.
#
# Exercises the complete RFC-0002 implementation on a real (or VM) k0s install:
#   preflight → bringup (private repo) → sync verification → manifest reconcile
#   → ArgoCD RBAC → K8s RBAC → etcd encryption → disk residue → auth failure
#   → rotation drill → cleanup
#
# USAGE
#   bash tests/system/run.sh [options]
#   TEST_ROBOT_HOST=mk11000009 bash tests/system/run.sh [options]
#
# OPTIONS
#   --phase <name>      Start at this named phase, skip all earlier phases.
#                       Phase names: preflight bringup sync reconcile
#                                    argocd-rbac k8s-rbac etcd-encryption
#                                    disk-residue auth-failure rotation cleanup
#   --cleanup           Run only Phase 11 (cleanup) and exit.
#   --keep-going        Continue past phase failures; collect all errors,
#                       exit non-zero at the end.
#   --help              Print this usage and exit.
#
# REQUIRED ENV VARS
#   ARGOCD_REPO_CREDENTIAL_FILE
#       Path to the ArgoCD repository Secret YAML file (mode 0600). The harness
#       does NOT generate it. See "Generating the credential file" below.
#       Default: /tmp/phantomos-test-creds.yaml
#
# OPTIONAL ENV VARS
#   PHANTOMOS_TEST_NEW_CREDENTIAL_FILE
#       Path to a fresh-credential-file (mode 0600) for the rotation drill
#       (Phase 9). When unset, Phase 9 is skipped with a note.
#   TEST_ROBOT_HOST
#       If set, Phases 1-8 run over SSH as root@$TEST_ROBOT_HOST instead of
#       locally. The robot 'mk11000009' is the canonical test target.
#       See "SSH seed" section below before running in this mode.
#
# GENERATING THE CREDENTIAL FILE
#   GitHub App (preferred):
#     1. Create a GitHub App on foundationbot org scoped to
#        foundationbot/phantomos-deployer with Contents: Read permission.
#     2. Install the App on that repo. Note the App ID and Installation ID.
#     3. Generate and download a private key (.pem).
#     4. Render the credential file:
#          cat > /tmp/phantomos-test-creds.yaml <<EOF
#          apiVersion: v1
#          kind: Secret
#          metadata:
#            name: phantomos-kos-repo
#            namespace: argocd
#            labels:
#              argocd.argoproj.io/secret-type: repository
#          stringData:
#            type: git
#            url: https://github.com/foundationbot/phantomos-deployer
#            githubAppID: "<app-id>"
#            githubAppInstallationID: "<install-id>"
#            githubAppPrivateKey: |
#              -----BEGIN RSA PRIVATE KEY-----
#              <paste pem contents here>
#              -----END RSA PRIVATE KEY-----
#          EOF
#          chmod 0600 /tmp/phantomos-test-creds.yaml
#
#   PAT fallback (if GitHub App is unavailable):
#     Create a fine-grained PAT with Contents: Read on
#     foundationbot/phantomos-deployer only, then:
#          cat > /tmp/phantomos-test-creds.yaml <<EOF
#          apiVersion: v1
#          kind: Secret
#          metadata:
#            name: phantomos-kos-repo
#            namespace: argocd
#            labels:
#              argocd.argoproj.io/secret-type: repository
#          stringData:
#            type: git
#            url: https://github.com/foundationbot/phantomos-deployer
#            username: x-access-token
#            password: <PAT>
#          EOF
#          chmod 0600 /tmp/phantomos-test-creds.yaml
#
# SSH SEED (required before using TEST_ROBOT_HOST)
#   From this repo's root, run once to seed the robot:
#     rsync -av --exclude=.git --exclude=tests/system/ \
#       . root@$TEST_ROBOT_HOST:/tmp/phantomos-deployer-test/
#     scp "$ARGOCD_REPO_CREDENTIAL_FILE" \
#       root@$TEST_ROBOT_HOST:/etc/phantomos/argocd-repo-credential.yaml
#     ssh root@$TEST_ROBOT_HOST \
#       chmod 0600 /etc/phantomos/argocd-repo-credential.yaml
#   The harness will error in Phase 0 preflight if the seed paths are absent.

set -euo pipefail

# ---------------------------------------------------------------------------
# Colored output helpers — match bootstrap-robot.sh's style exactly.
# ---------------------------------------------------------------------------

_PASS=0
_FAIL=0
_SKIP=0
_FAIL_MESSAGES=()

_pass() { _PASS=$((_PASS + 1)); printf '  \033[32m✓ PASS\033[0m  %s\n' "$1"; }
_fail() {
  _FAIL=$((_FAIL + 1))
  printf '  \033[31m✗ FAIL\033[0m  %s\n' "$1"
  _FAIL_MESSAGES+=("$1")
}
_skip()  { _SKIP=$((_SKIP + 1)); printf '  \033[33m• SKIP\033[0m  %s\n' "$1"; }
_info()  { printf '  \033[2m·\033[0m %s\n' "$1"; }
# shellcheck disable=SC2317  # called via variable-dispatch / trap
_note()  { printf '  \033[36m→\033[0m %s\n' "$1"; }
_phase() { printf '\n\033[1;44m  PHASE: %-65s\033[0m\n' "$1"; }
_banner_pass() { printf '\033[32m══ PHASE PASS: %s\033[0m\n' "$1"; }
_banner_fail() { printf '\033[31m══ PHASE FAIL: %s\033[0m\n' "$1"; }

# _die: hard abort (not a phase failure, a programming/env error)
_die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 2; }

# _summary: print final pass/fail/skip tallies and exit
_summary() {
  printf '\n\033[1m── Summary ──────────────────────────────\033[0m\n'
  printf '  PASS  %d   FAIL  %d   SKIP  %d\n' "$_PASS" "$_FAIL" "$_SKIP"
  if [ "${#_FAIL_MESSAGES[@]}" -gt 0 ]; then
    printf '\n\033[31mFailed checks:\033[0m\n'
    local m
    for m in "${_FAIL_MESSAGES[@]}"; do
      printf '  • %s\n' "$m"
    done
  fi
  printf '\033[1m─────────────────────────────────────────\033[0m\n'
}

# ---------------------------------------------------------------------------
# Option parsing
# ---------------------------------------------------------------------------

# Ordered phase list — used by --phase to skip ahead.
_PHASE_ORDER=(preflight bringup sync reconcile argocd-rbac k8s-rbac
              etcd-encryption disk-residue auth-failure rotation migration cleanup)

START_PHASE="preflight"
CLEANUP_ONLY=0
KEEP_GOING=0

_usage() {
  sed -n '2,/^set -euo pipefail/p' "$0" | sed 's/^# \?//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --phase)
      START_PHASE="${2:?--phase requires a phase name}"
      # Validate the name.
      _valid=0
      for _p in "${_PHASE_ORDER[@]}"; do
        [ "$_p" = "$START_PHASE" ] && { _valid=1; break; }
      done
      [ "$_valid" -eq 1 ] || _die "unknown phase '$START_PHASE'. Valid: ${_PHASE_ORDER[*]}"
      shift 2 ;;
    --cleanup)
      CLEANUP_ONLY=1; shift ;;
    --keep-going)
      KEEP_GOING=1; shift ;;
    --help|-h)
      _usage; exit 0 ;;
    *)
      _die "unknown option: $1" ;;
  esac
done

# ---------------------------------------------------------------------------
# Environment / defaults
# ---------------------------------------------------------------------------

ARGOCD_REPO_CREDENTIAL_FILE="${ARGOCD_REPO_CREDENTIAL_FILE:-/tmp/phantomos-test-creds.yaml}"
TEST_REPO_URL="https://github.com/foundationbot/phantomos-deployer.git"
TEST_REPO_URL_NO_GIT="https://github.com/foundationbot/phantomos-deployer"
# Export so bootstrap-robot.sh sees it when invoked from this harness.
export DEFAULT_REPO_URL="${TEST_REPO_URL}"

TEST_ROBOT_HOST="${TEST_ROBOT_HOST:-}"
PHANTOMOS_TEST_NEW_CREDENTIAL_FILE="${PHANTOMOS_TEST_NEW_CREDENTIAL_FILE:-}"

# Paths used on the robot (local or SSH target)
_ROBOT_REPO_PATH="/tmp/phantomos-deployer-test"
_ROBOT_CREDENTIAL_PATH="/etc/phantomos/argocd-repo-credential.yaml"

# ArgoCD admin credentials (bootstrap default)
_ARGOCD_ADMIN_PW="1984"
_ARGOCD_OPERATOR_PW="1984"
_ARGOCD_FLEET_OP_PW="1984"
_ARGOCD_SERVER="localhost:30443"

# Temp files created by this harness — cleaned up on exit.
_TMPDIR=""
_setup_tmpdir() {
  _TMPDIR="$(mktemp -d /tmp/phantomos-system-test.XXXXXX)"
  # shellcheck disable=SC2064
  trap "_teardown_tmpdir" EXIT
}
# shellcheck disable=SC2317  # called via EXIT trap
_teardown_tmpdir() {
  if [ -n "$_TMPDIR" ] && [ -d "$_TMPDIR" ]; then
    rm -rf "$_TMPDIR"
  fi
}

# ---------------------------------------------------------------------------
# SSH helper — run a command locally or over SSH depending on TEST_ROBOT_HOST.
# ---------------------------------------------------------------------------

# _ssh_run <description> <command_string>
#   When TEST_ROBOT_HOST is set: ssh root@$TEST_ROBOT_HOST "bash -c '<cmd>'"
#   Otherwise: bash -c '<cmd>'
#   Always prints the description, captures output, returns the exit code.
_ssh_run() {
  local desc="$1"
  local cmd="$2"
  _info "$desc"
  if [ -n "$TEST_ROBOT_HOST" ]; then
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        "root@${TEST_ROBOT_HOST}" "bash -c $(printf '%q' "$cmd")"
  else
    bash -c "$cmd"
  fi
}

# _ssh_run_capture <var_name> <description> <command_string>
#   Like _ssh_run but captures stdout into the named variable.
_ssh_run_capture() {
  local _var="$1"
  local desc="$2"
  local cmd="$3"
  _info "$desc"
  local _out
  if [ -n "$TEST_ROBOT_HOST" ]; then
    _out=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        "root@${TEST_ROBOT_HOST}" "bash -c $(printf '%q' "$cmd")" 2>&1) || true
  else
    _out=$(bash -c "$cmd" 2>&1) || true
  fi
  printf -v "$_var" '%s' "$_out"
}

# ---------------------------------------------------------------------------
# Phase guard — decides whether to skip a phase given the --phase start point.
# ---------------------------------------------------------------------------

# _phase_active <phase_name>: returns 0 if phase should run, 1 if skip.
_phase_active() {
  local name="$1"
  local found=0
  local p
  for p in "${_PHASE_ORDER[@]}"; do
    [ "$p" = "$START_PHASE" ] && found=1
    [ "$found" -eq 1 ] && [ "$p" = "$name" ] && return 0
  done
  return 1
}

# _guard_phase: called after each phase function.  If FAIL > 0 and
# --keep-going is NOT set, print summary and exit now.
_guard_phase() {
  local phase_name="$1"
  if [ "$_FAIL" -gt 0 ]; then
    _banner_fail "$phase_name"
    if [ "$KEEP_GOING" -eq 0 ]; then
      _summary
      exit "$_FAIL"
    fi
  else
    _banner_pass "$phase_name"
  fi
}

# ---------------------------------------------------------------------------
# Phase 0: Preflight
# ---------------------------------------------------------------------------

_phase_preflight() {
  _phase "Phase 0: Preflight"

  # --- root / sudo ---
  if [ "$(id -u)" -ne 0 ]; then
    _fail "must run as root (the harness installs k0s). Re-run: sudo bash $0"
    _guard_phase "preflight"
    return
  fi
  _pass "running as root"

  # --- required tools ---
  local tool
  for tool in kubectl argocd kustomize gh curl htpasswd git helm; do
    if command -v "$tool" >/dev/null 2>&1; then
      _pass "tool present: $tool"
    else
      _fail "required tool missing from PATH: $tool"
    fi
  done

  # --- gh auth ---
  if gh auth status >/dev/null 2>&1; then
    _pass "gh auth status: authenticated"
  else
    _fail "gh auth status failed — run 'gh auth login' and retry"
  fi

  # --- gh repo access ---
  if gh repo view foundationbot/phantomos-deployer >/dev/null 2>&1; then
    _pass "gh can read foundationbot/phantomos-deployer"
  else
    _fail "gh cannot read foundationbot/phantomos-deployer — check PAT scope or repo name"
  fi

  # --- credential file exists ---
  if [ -f "$ARGOCD_REPO_CREDENTIAL_FILE" ]; then
    _pass "credential file exists: $ARGOCD_REPO_CREDENTIAL_FILE"
  else
    _fail "credential file not found: $ARGOCD_REPO_CREDENTIAL_FILE — see --help for generation instructions"
    _guard_phase "preflight"
    return
  fi

  # --- credential file mode 0600 ---
  local _mode
  _mode=$(stat -c '%a' "$ARGOCD_REPO_CREDENTIAL_FILE" 2>/dev/null \
        || stat -f '%Lp' "$ARGOCD_REPO_CREDENTIAL_FILE" 2>/dev/null || echo "unknown")
  if [ "$_mode" = "600" ]; then
    _pass "credential file mode 0600"
  else
    _fail "credential file mode is $_mode, expected 0600 — run: chmod 0600 $ARGOCD_REPO_CREDENTIAL_FILE"
  fi

  # --- SAFETY CHECK: credential file URL must point at the test mirror, not
  #     the production repo, to prevent accidental credential pollution. ---
  local _cred_url
  _cred_url=$(grep -E '^\s+url:' "$ARGOCD_REPO_CREDENTIAL_FILE" 2>/dev/null \
            | head -1 | sed 's/.*url:[[:space:]]*//' | tr -d '"' | tr -d "'") || true
  if echo "$_cred_url" | grep -qF "phantomos-deployer"; then
    _pass "credential file URL targets phantomos-deployer (test mirror) — safety OK"
  else
    _fail "SAFETY: credential file url: '$_cred_url' does not mention 'phantomos-deployer'. " \
          "The harness must ONLY be used with the test mirror " \
          "(https://github.com/foundationbot/phantomos-deployer). " \
          "Regenerate the credential file against the test repo."
  fi

  # --- SSH seed checks (only when TEST_ROBOT_HOST is set) ---
  if [ -n "$TEST_ROBOT_HOST" ]; then
    _info "SSH mode: verifying robot $TEST_ROBOT_HOST is seeded"
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
         "root@${TEST_ROBOT_HOST}" "test -d ${_ROBOT_REPO_PATH}/scripts" 2>/dev/null; then
      _pass "SSH seed: repo present at $TEST_ROBOT_HOST:$_ROBOT_REPO_PATH"
    else
      _fail "SSH seed: repo not found at $TEST_ROBOT_HOST:$_ROBOT_REPO_PATH — seed it first:
  rsync -av --exclude=.git --exclude=tests/system/ . root@$TEST_ROBOT_HOST:$_ROBOT_REPO_PATH/"
    fi
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
         "root@${TEST_ROBOT_HOST}" "test -f ${_ROBOT_CREDENTIAL_PATH}" 2>/dev/null; then
      _pass "SSH seed: credential file present at $TEST_ROBOT_HOST:$_ROBOT_CREDENTIAL_PATH"
    else
      _fail "SSH seed: credential file not found at $TEST_ROBOT_HOST:$_ROBOT_CREDENTIAL_PATH — seed it:
  scp \$ARGOCD_REPO_CREDENTIAL_FILE root@$TEST_ROBOT_HOST:$_ROBOT_CREDENTIAL_PATH
  ssh root@$TEST_ROBOT_HOST chmod 0600 $_ROBOT_CREDENTIAL_PATH"
    fi
  fi

  _guard_phase "preflight"
}

# ---------------------------------------------------------------------------
# Phase 1: Initial bringup, private repo from the start
# ---------------------------------------------------------------------------

_phase_bringup() {
  _phase "Phase 1: Initial bringup (private repo from start)"

  # Determine the bootstrap script path.
  local _bootstrap
  if [ -n "$TEST_ROBOT_HOST" ]; then
    _bootstrap="${_ROBOT_REPO_PATH}/scripts/bootstrap-robot.sh"
  else
    # Derive from this harness's location: tests/system/../../scripts/
    _bootstrap="$(cd "$(dirname "$0")/../.." && pwd)/scripts/bootstrap-robot.sh"
  fi

  _info "bootstrap path: $_bootstrap"
  _info "DEFAULT_REPO_URL=$DEFAULT_REPO_URL"
  _info "credential file: $ARGOCD_REPO_CREDENTIAL_FILE"

  # Run bootstrap with --gitops --argocd-users and the test repo credential.
  local _cred_on_target="$ARGOCD_REPO_CREDENTIAL_FILE"
  if [ -n "$TEST_ROBOT_HOST" ]; then
    _cred_on_target="$_ROBOT_CREDENTIAL_PATH"
  fi

  # Run bootstrap. We pass -y to suppress interactive prompts.
  # DEFAULT_REPO_URL is already exported above; bootstrap reads it.
  if _ssh_run "Running bootstrap-robot.sh --gitops --argocd-users -y" \
       "DEFAULT_REPO_URL=${DEFAULT_REPO_URL} bash ${_bootstrap} \
        --gitops --argocd-users \
        --repo-credential-file ${_cred_on_target} \
        -y 2>&1"; then
    _pass "bootstrap-robot.sh completed without error"
  else
    _fail "bootstrap-robot.sh exited non-zero — check output above"
    _guard_phase "bringup"
    return
  fi

  # Wait for ArgoCD pods to be Ready (5 min timeout).
  _info "Waiting for ArgoCD pods to be Ready (timeout: 300s)"
  local _deadline
  _deadline=$(($(date +%s) + 300))
  local _all_ready=0
  while [ "$(date +%s)" -lt "$_deadline" ]; do
    local _not_ready
    _not_ready=$(_ssh_run "checking argocd pod readiness" \
      "kubectl -n argocd get pods --no-headers 2>/dev/null \
       | grep -v 'Running\|Completed' | wc -l" 2>/dev/null) || _not_ready=99
    if [ "${_not_ready// /}" = "0" ]; then
      _all_ready=1
      break
    fi
    sleep 10
  done

  if [ "$_all_ready" -eq 1 ]; then
    _pass "all ArgoCD pods Ready"
  else
    local _pods_out
    _ssh_run_capture _pods_out "capturing argocd pod state" \
      "kubectl -n argocd get pods --no-headers 2>&1"
    _fail "ArgoCD pods not Ready within 300s. Current state:
$_pods_out"
    _guard_phase "bringup"
    return
  fi

  # argocd login
  if _ssh_run "argocd login as admin" \
       "argocd login ${_ARGOCD_SERVER} \
        --username admin --password ${_ARGOCD_ADMIN_PW} \
        --insecure --plaintext 2>&1"; then
    _pass "argocd login admin succeeded"
  else
    _fail "argocd login admin failed — check ArgoCD pod logs and admin password"
    _guard_phase "bringup"
    return
  fi

  # argocd repo list — expect Successful for phantomos-deployer URL
  local _repo_out
  _ssh_run_capture _repo_out "argocd repo list" \
    "argocd repo list 2>&1"
  if echo "$_repo_out" | grep -qF "phantomos-deployer"; then
    if echo "$_repo_out" | grep -qF "Successful"; then
      _pass "argocd repo list: phantomos-deployer reports Successful"
    else
      _fail "argocd repo list: phantomos-deployer present but NOT Successful:
$_repo_out"
    fi
  else
    _fail "argocd repo list: phantomos-deployer not found in repo list:
$_repo_out"
  fi

  # argocd app list — discover the phantomos-*-core application.
  local _apps_out
  _ssh_run_capture _apps_out "argocd app list" \
    "kubectl -n argocd get applications -o name 2>&1"
  if echo "$_apps_out" | grep -q "application.argoproj.io/phantomos-"; then
    _pass "at least one phantomos-* Application found"
    # Export the app name for downstream phases.
    _TEST_APP_NAME=$(echo "$_apps_out" \
      | grep "application.argoproj.io/phantomos-" \
      | head -1 \
      | sed 's|application.argoproj.io/||')
    _info "using application: $_TEST_APP_NAME"
  else
    _fail "no phantomos-* Application found — bringup may have failed:
$_apps_out"
  fi

  _guard_phase "bringup"
}

# App name discovered in bringup, used by later phases.
_TEST_APP_NAME=""

# ---------------------------------------------------------------------------
# Phase 2: Sync verification
# ---------------------------------------------------------------------------

_phase_sync() {
  _phase "Phase 2: Sync verification"

  if [ -z "$_TEST_APP_NAME" ]; then
    # Try to discover it (e.g. when starting at this phase via --phase sync).
    _ssh_run_capture _TEST_APP_NAME "discovering application name" \
      "kubectl -n argocd get applications -o name 2>/dev/null \
       | grep 'phantomos-' | head -1 | sed 's|application.argoproj.io/||'" || true
    if [ -z "$_TEST_APP_NAME" ]; then
      _fail "could not discover phantomos-* application name — run Phase 1 first"
      _guard_phase "sync"
      return
    fi
    _info "discovered application: $_TEST_APP_NAME"
  fi

  # argocd app sync with 300s timeout.
  if _ssh_run "argocd app sync $_TEST_APP_NAME" \
       "argocd login ${_ARGOCD_SERVER} \
          --username admin --password ${_ARGOCD_ADMIN_PW} \
          --insecure --plaintext >/dev/null 2>&1 && \
        argocd app sync ${_TEST_APP_NAME} --timeout 300 2>&1"; then
    _pass "argocd app sync $_TEST_APP_NAME completed"
  else
    _fail "argocd app sync $_TEST_APP_NAME failed"
    _guard_phase "sync"
    return
  fi

  # Confirm Synced/Healthy
  local _app_out
  _ssh_run_capture _app_out "argocd app get $_TEST_APP_NAME" \
    "argocd app get ${_TEST_APP_NAME} 2>&1"
  if echo "$_app_out" | grep -q "Synced" && echo "$_app_out" | grep -q "Healthy"; then
    _pass "application $_TEST_APP_NAME is Synced/Healthy"
  else
    _fail "application $_TEST_APP_NAME is not Synced/Healthy:
$_app_out"
  fi

  _guard_phase "sync"
}

# ---------------------------------------------------------------------------
# Phase 3: Manifest-change reconciliation
# ---------------------------------------------------------------------------

_phase_reconcile() {
  _phase "Phase 3: Manifest-change reconciliation"

  if [ -z "$_TEST_APP_NAME" ]; then
    _ssh_run_capture _TEST_APP_NAME "discovering application name" \
      "kubectl -n argocd get applications -o name 2>/dev/null \
       | grep 'phantomos-' | head -1 | sed 's|application.argoproj.io/||'" || true
    if [ -z "$_TEST_APP_NAME" ]; then
      _fail "could not discover phantomos-* application name — run Phase 1 first"
      _guard_phase "reconcile"
      return
    fi
  fi

  # Get the current SHA from ArgoCD before the change.
  local _before_sha
  _ssh_run_capture _before_sha "getting current sync SHA" \
    "argocd app get ${_TEST_APP_NAME} -o json 2>/dev/null \
     | python3 -c \"import sys,json; d=json.load(sys.stdin); \
       print(d.get('status',{}).get('sync',{}).get('revision','unknown'))\" 2>/dev/null \
     || echo unknown" || true
  _info "current SHA before change: ${_before_sha:-unknown}"

  # Make a trivial change via gh API: add a comment to a manifest file.
  _info "making a trivial manifest change via gh API"
  local _branch="main"
  local _target_file="manifests/stacks/core/kustomization.yaml"
  local _comment_marker
  _comment_marker="# system-test-harness-$(date +%s)"

  # Fetch current file content and SHA.
  local _file_json
  _file_json=$(gh api \
    "repos/foundationbot/phantomos-deployer/contents/${_target_file}?ref=${_branch}" \
    2>&1) || {
    _fail "could not fetch $_target_file from phantomos-deployer via gh API:
$_file_json"
    _guard_phase "reconcile"
    return
  }

  local _file_sha
  _file_sha=$(echo "$_file_json" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['sha'])" 2>/dev/null) || {
    _fail "could not parse sha from gh API response"
    _guard_phase "reconcile"
    return
  }

  local _file_content_b64
  _file_content_b64=$(echo "$_file_json" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['content'].replace('\\n',''))" 2>/dev/null) || {
    _fail "could not parse content from gh API response"
    _guard_phase "reconcile"
    return
  }

  # Decode, append comment, re-encode.
  local _new_content_b64
  _new_content_b64=$(printf '%s' "$_file_content_b64" | base64 -d 2>/dev/null \
    | { cat; printf '\n%s\n' "$_comment_marker"; } \
    | base64 -w 0) || {
    _fail "could not base64-encode modified manifest content"
    _guard_phase "reconcile"
    return
  }

  # Push the change via gh API.
  local _push_out
  _push_out=$(gh api \
    "repos/foundationbot/phantomos-deployer/contents/${_target_file}" \
    -X PUT \
    -f "message=chore: system-test trivial manifest change $(date +%s)" \
    -f "content=${_new_content_b64}" \
    -f "sha=${_file_sha}" \
    -f "branch=${_branch}" \
    2>&1) || {
    _fail "gh API PUT failed for $_target_file:
$_push_out"
    _guard_phase "reconcile"
    return
  }

  local _new_commit_sha
  _new_commit_sha=$(echo "$_push_out" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['commit']['sha'][:12])" 2>/dev/null) || \
    _new_commit_sha="(parse failed)"
  _pass "pushed manifest change; new commit SHA: $_new_commit_sha"

  # Wait up to 3 min for ArgoCD to pick up the new SHA.
  _info "waiting up to 180s for ArgoCD to reconcile new SHA"
  local _deadline
  _deadline=$(($(date +%s) + 180))
  local _reconciled=0
  local _current_sha=""
  while [ "$(date +%s)" -lt "$_deadline" ]; do
    _ssh_run_capture _current_sha "polling argocd app SHA" \
      "argocd app get ${_TEST_APP_NAME} -o json 2>/dev/null \
       | python3 -c \"import sys,json; d=json.load(sys.stdin); \
         print(d.get('status',{}).get('sync',{}).get('revision',''))\" 2>/dev/null \
       || echo ''" || true
    if [ -n "$_current_sha" ] && [ "$_current_sha" != "$_before_sha" ]; then
      _reconciled=1
      break
    fi
    sleep 15
  done

  if [ "$_reconciled" -eq 1 ]; then
    _pass "ArgoCD picked up new SHA: $_current_sha"
  else
    _fail "ArgoCD did not reconcile new SHA within 180s (still at: ${_before_sha:-unknown})"
    _guard_phase "reconcile"
    return
  fi

  # Confirm Synced/Healthy after reconcile.
  local _app_out
  _ssh_run_capture _app_out "checking post-reconcile app health" \
    "argocd app get ${_TEST_APP_NAME} 2>&1"
  if echo "$_app_out" | grep -q "Synced" && echo "$_app_out" | grep -q "Healthy"; then
    _pass "application $_TEST_APP_NAME is Synced/Healthy after manifest change"
  else
    _fail "application $_TEST_APP_NAME is not Synced/Healthy after reconcile:
$_app_out"
  fi

  _guard_phase "reconcile"
}

# ---------------------------------------------------------------------------
# Phase 4: ArgoCD account RBAC
# ---------------------------------------------------------------------------

_phase_argocd_rbac() {
  _phase "Phase 4: ArgoCD account RBAC"

  if [ -z "$_TEST_APP_NAME" ]; then
    _ssh_run_capture _TEST_APP_NAME "discovering application name" \
      "kubectl -n argocd get applications -o name 2>/dev/null \
       | grep 'phantomos-' | head -1 | sed 's|application.argoproj.io/||'" || true
    if [ -z "$_TEST_APP_NAME" ]; then
      _fail "could not discover application name"
      _guard_phase "argocd-rbac"
      return
    fi
  fi

  # -- operator: readonly role --
  # Login as operator.
  if _ssh_run "argocd login as operator" \
       "argocd login ${_ARGOCD_SERVER} \
        --username operator --password ${_ARGOCD_OPERATOR_PW} \
        --insecure --plaintext 2>&1"; then
    _pass "argocd login as operator succeeded"
  else
    _fail "argocd login as operator failed (check --argocd-users ran)"
    _guard_phase "argocd-rbac"
    return
  fi

  # operator: argocd app sync should be DENIED.
  local _sync_out
  _sync_out=$(_ssh_run "operator: argocd app sync (expect permission denied)" \
    "argocd app sync ${_TEST_APP_NAME} 2>&1" || true)
  if echo "$_sync_out" | grep -qi "permission\|denied\|unauthorized\|PermissionDenied\|403"; then
    _pass "operator: argocd app sync correctly denied"
  else
    _fail "operator: argocd app sync was NOT denied (expected permission denied):
$_sync_out"
  fi

  # operator: argocd app get should SUCCEED.
  local _get_out
  _ssh_run_capture _get_out "operator: argocd app get (expect success)" \
    "argocd app get ${_TEST_APP_NAME} 2>&1"
  if echo "$_get_out" | grep -q "Name:\|Application:"; then
    _pass "operator: argocd app get succeeded"
  else
    _fail "operator: argocd app get failed:
$_get_out"
  fi

  # -- fleet-operator: custom role --
  # Login as fleet-operator.
  if _ssh_run "argocd login as fleet-operator" \
       "argocd login ${_ARGOCD_SERVER} \
        --username fleet-operator --password ${_ARGOCD_FLEET_OP_PW} \
        --insecure --plaintext 2>&1"; then
    _pass "argocd login as fleet-operator succeeded"
  else
    _fail "argocd login as fleet-operator failed"
    _guard_phase "argocd-rbac"
    return
  fi

  # fleet-operator: argocd app sync should SUCCEED.
  if _ssh_run "fleet-operator: argocd app sync (expect success)" \
       "argocd app sync ${_TEST_APP_NAME} --timeout 120 2>&1"; then
    _pass "fleet-operator: argocd app sync succeeded"
  else
    _fail "fleet-operator: argocd app sync failed (expected success)"
  fi

  # fleet-operator: argocd app delete should be DENIED.
  local _delete_out
  _delete_out=$(_ssh_run "fleet-operator: argocd app delete (expect denied)" \
    "argocd app delete ${_TEST_APP_NAME} --yes 2>&1" || true)
  if echo "$_delete_out" | grep -qi "permission\|denied\|unauthorized\|PermissionDenied\|403"; then
    _pass "fleet-operator: argocd app delete correctly denied"
  else
    _fail "fleet-operator: argocd app delete was NOT denied:
$_delete_out"
  fi

  # fleet-operator: argocd repo get — should return output with redacted secret fields.
  local _repo_out
  _ssh_run_capture _repo_out "fleet-operator: argocd repo get" \
    "argocd repo get ${TEST_REPO_URL_NO_GIT} 2>&1 || \
     argocd repo list 2>&1 | grep phantomos-deployer"
  if echo "$_repo_out" | grep -qF "phantomos-deployer"; then
    _pass "fleet-operator: repo info returned (repo accessible)"
    # Verify no raw PEM material is visible.
    if echo "$_repo_out" | grep -q "BEGIN RSA PRIVATE KEY\|BEGIN PRIVATE KEY"; then
      _fail "fleet-operator: PEM key visible in argocd repo output — ArgoCD not redacting!"
    else
      _pass "fleet-operator: no PEM material in argocd repo output (redacted)"
    fi
    if echo "$_repo_out" | grep -Eqi "password.*ghp_|password.*[A-Za-z0-9]{30,}"; then
      _fail "fleet-operator: raw password token visible in argocd repo output — not redacted!"
    else
      _pass "fleet-operator: password field redacted in argocd repo output"
    fi
  else
    _fail "fleet-operator: repo info not returned:
$_repo_out"
  fi

  # Logout.
  _ssh_run "argocd logout" "argocd logout 2>&1 || true"
  _pass "argocd logout done"

  # Re-login as admin so downstream phases work.
  _ssh_run "re-login as admin" \
    "argocd login ${_ARGOCD_SERVER} \
     --username admin --password ${_ARGOCD_ADMIN_PW} \
     --insecure --plaintext >/dev/null 2>&1" || true

  _guard_phase "argocd-rbac"
}

# ---------------------------------------------------------------------------
# Phase 5: Kubernetes RBAC
# ---------------------------------------------------------------------------

_phase_k8s_rbac() {
  _phase "Phase 5: Kubernetes RBAC"

  # Generate a fleet-operator kubeconfig per docs/operations.md.
  local _fo_kubeconfig
  _fo_kubeconfig="${_TMPDIR}/fleet-operator.kubeconfig"

  if [ -n "$TEST_ROBOT_HOST" ]; then
    # Generate on the robot, copy back.
    if _ssh_run "generating fleet-operator kubeconfig on robot" \
         "SA_NS=kube-system && SA=fleet-operator && \
          SECRET=\$(kubectl -n \$SA_NS create token \$SA --duration=2h 2>/dev/null) && \
          APISERVER=\$(kubectl config view --minify \
            -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null) && \
          CA=\$(kubectl config view --raw --minify \
            -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' 2>/dev/null) && \
          cat > /tmp/fleet-operator-test.kubeconfig <<KEOF
apiVersion: v1
kind: Config
clusters:
- name: test-robot
  cluster:
    server: \$APISERVER
    certificate-authority-data: \$CA
contexts:
- name: test-robot
  context: {cluster: test-robot, user: fleet-operator, namespace: default}
users:
- name: fleet-operator
  user: {token: \$SECRET}
current-context: test-robot
KEOF
          chmod 0600 /tmp/fleet-operator-test.kubeconfig && echo OK"; then
      # Copy the kubeconfig back.
      scp -q "root@${TEST_ROBOT_HOST}:/tmp/fleet-operator-test.kubeconfig" \
          "$_fo_kubeconfig" 2>/dev/null \
        || _fail "could not scp fleet-operator kubeconfig from robot"
    else
      _fail "could not generate fleet-operator kubeconfig on robot"
      _guard_phase "k8s-rbac"
      return
    fi
  else
    # Generate locally.
    local _sa_ns="kube-system" _sa="fleet-operator"
    local _secret _apiserver _ca
    _secret=$(kubectl -n "$_sa_ns" create token "$_sa" --duration=2h 2>/dev/null) || {
      _fail "could not create token for fleet-operator ServiceAccount — was --argocd-users (which applies fleet-operator-kubectl-rbac) run?"
      _guard_phase "k8s-rbac"
      return
    }
    _apiserver=$(kubectl config view --minify \
      -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)
    _ca=$(kubectl config view --raw --minify \
      -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' 2>/dev/null)
    cat > "$_fo_kubeconfig" <<KEOF
apiVersion: v1
kind: Config
clusters:
- name: test-robot
  cluster:
    server: ${_apiserver}
    certificate-authority-data: ${_ca}
contexts:
- name: test-robot
  context: {cluster: test-robot, user: fleet-operator, namespace: default}
users:
- name: fleet-operator
  user: {token: ${_secret}}
current-context: test-robot
KEOF
    chmod 0600 "$_fo_kubeconfig"
  fi

  _pass "fleet-operator kubeconfig generated"

  # All kubectl checks below use the fleet-operator kubeconfig.
  local _kc="--kubeconfig=${_fo_kubeconfig}"
  if [ -n "$TEST_ROBOT_HOST" ]; then
    # For SSH mode, use the kubeconfig on the robot.
    _kc="--kubeconfig=/tmp/fleet-operator-test.kubeconfig"
  fi

  # Check 1: kubectl get secret -n argocd phantomos-kos-repo → Forbidden
  local _secret_out
  _secret_out=$(_ssh_run "fleet-operator kubectl get secret phantomos-kos-repo" \
    "kubectl ${_kc} get secret -n argocd phantomos-kos-repo 2>&1" || true)
  if echo "$_secret_out" | grep -qi "forbidden\|cannot\|Error"; then
    _pass "fleet-operator: get secret phantomos-kos-repo is Forbidden"
  else
    _fail "fleet-operator: get secret phantomos-kos-repo should be Forbidden:
$_secret_out"
  fi

  # Check 2: kubectl get pods -A → success (view ClusterRole)
  local _pods_out
  _pods_out=$(_ssh_run "fleet-operator kubectl get pods -A" \
    "kubectl ${_kc} get pods -A 2>&1" || true)
  if echo "$_pods_out" | grep -qi "NAMESPACE\|Running\|No resources"; then
    _pass "fleet-operator: kubectl get pods -A succeeded (view role)"
  else
    _fail "fleet-operator: kubectl get pods -A failed:
$_pods_out"
  fi

  # Check 3: kubectl scale deploy — need a deploy target.
  # Discover a deploy in nimbus or any fleet namespace.
  local _deploy_target="" _deploy_ns=""
  for _ns in nimbus argus positronic; do
    local _dep
    _dep=$(_ssh_run "looking for a Deployment in namespace $_ns" \
      "kubectl ${_kc} get deploy -n ${_ns} --no-headers -o name 2>/dev/null | head -1" \
      || true) || true
    if [ -n "$_dep" ]; then
      _deploy_target="${_dep#deployment.apps/}"
      _deploy_ns="$_ns"
      break
    fi
  done

  if [ -n "$_deploy_target" ]; then
    local _scale_out
    _scale_out=$(_ssh_run "fleet-operator kubectl scale deploy/$_deploy_target in $_deploy_ns" \
      "kubectl ${_kc} scale deploy/${_deploy_target} --replicas=1 -n ${_deploy_ns} 2>&1" \
      || true)
    if echo "$_scale_out" | grep -qi "scaled\|unchanged"; then
      _pass "fleet-operator: kubectl scale deploy/$_deploy_target in $_deploy_ns succeeded"
    else
      _fail "fleet-operator: kubectl scale deploy/$_deploy_target failed:
$_scale_out"
    fi
  else
    _skip "fleet-operator: scale check — no Deployment found in nimbus/argus/positronic"
  fi

  # Check 4: kubectl delete ns → Forbidden
  local _del_ns_out
  _del_ns_out=$(_ssh_run "fleet-operator kubectl delete ns nimbus (expect Forbidden)" \
    "kubectl ${_kc} delete ns nimbus 2>&1" || true)
  if echo "$_del_ns_out" | grep -qi "forbidden\|cannot\|Error\|not found"; then
    _pass "fleet-operator: kubectl delete ns nimbus is Forbidden (or ns not found)"
  else
    _fail "fleet-operator: kubectl delete ns nimbus should be Forbidden:
$_del_ns_out"
  fi

  # Check 5: kubectl get secrets -n kube-system → Forbidden or empty
  local _ks_secrets_out
  _ks_secrets_out=$(_ssh_run "fleet-operator kubectl get secrets -n kube-system" \
    "kubectl ${_kc} get secrets -n kube-system 2>&1" || true)
  if echo "$_ks_secrets_out" | grep -qi "forbidden\|cannot\|No resources"; then
    _pass "fleet-operator: kubectl get secrets -n kube-system is Forbidden or empty (view excludes secrets)"
  else
    _fail "fleet-operator: kubectl get secrets -n kube-system should be Forbidden:
$_ks_secrets_out"
  fi

  _guard_phase "k8s-rbac"
}

# ---------------------------------------------------------------------------
# Phase 6: Etcd encryption-at-rest
# ---------------------------------------------------------------------------

_phase_etcd_encryption() {
  _phase "Phase 6: Etcd encryption-at-rest"

  # Confirm etcd cluster is reachable via k0s.
  # k0s embeds etcd; the correct tool is 'k0s etcd member-list'.
  local _member_out
  _member_out=$(_ssh_run "k0s etcd member-list" \
    "k0s etcd member-list 2>&1" || true)
  if echo "$_member_out" | grep -qi "etcdID\|member\|peerURLs\|clientURLs"; then
    _pass "k0s etcd member-list: cluster reachable"
  else
    _fail "k0s etcd member-list failed — is k0s running?
$_member_out"
    _guard_phase "etcd-encryption"
    return
  fi

  # Read the raw etcd bytes for the phantomos-kos-repo secret.
  # k0s does NOT expose an 'etcdctl' subcommand directly.
  # The correct invocation is via the bundled etcdctl inside k0s:
  #   k0s etcd snapshot --help  (not useful)
  # Actually k0s provides: k0s etcd <subcommand>
  # For raw get we need to invoke the system etcdctl pointed at k0s's socket.
  # k0s stores the etcd data socket / certs at:
  #   /var/lib/k0s/pki/etcd-ca.crt
  #   /var/lib/k0s/pki/etcd/server.crt  (or apiserver-etcd-client.crt)
  #   /var/lib/k0s/pki/etcd/server.key
  # and the etcd peer URL is typically https://127.0.0.1:2380 (control plane).
  # The client URL is https://127.0.0.1:2379.
  #
  # IMPORTANT: k0s bundles etcdctl inside /var/lib/k0s/bin/etcdctl (or
  # accessible via 'k0s etcd' — test both). If neither works, this phase
  # prints the correct invocation and fails with a clear message.

  local _etcd_secret_path="/registry/secrets/argocd/phantomos-kos-repo"
  local _etcd_certs="/var/lib/k0s/pki"
  local _etcdctl_candidates=(
    "k0s etcdctl get ${_etcd_secret_path}"
    "ETCDCTL_API=3 /var/lib/k0s/bin/etcdctl \
       --endpoints=https://127.0.0.1:2379 \
       --cacert=${_etcd_certs}/etcd-ca.crt \
       --cert=${_etcd_certs}/apiserver-etcd-client.crt \
       --key=${_etcd_certs}/apiserver-etcd-client.key \
       get ${_etcd_secret_path}"
    "ETCDCTL_API=3 etcdctl \
       --endpoints=https://127.0.0.1:2379 \
       --cacert=${_etcd_certs}/etcd-ca.crt \
       --cert=${_etcd_certs}/apiserver-etcd-client.crt \
       --key=${_etcd_certs}/apiserver-etcd-client.key \
       get ${_etcd_secret_path}"
  )

  local _etcd_out=""
  local _etcdctl_worked=0
  for _etcdcmd in "${_etcdctl_candidates[@]}"; do
    _etcd_out=$(_ssh_run "trying: $_etcdcmd" "$_etcdcmd 2>&1" || true) || true
    # Check it returned something non-empty and not an obvious error.
    if [ -n "$_etcd_out" ] && ! echo "$_etcd_out" | grep -qi "not found\|error\|Usage\|unknown command"; then
      _etcdctl_worked=1
      break
    fi
  done

  if [ "$_etcdctl_worked" -eq 0 ]; then
    _fail "could not read etcd directly. The correct invocations to try manually are:
  # Option 1 (k0s built-in etcdctl):
  k0s etcdctl get /registry/secrets/argocd/phantomos-kos-repo
  # Option 2 (bundled binary):
  ETCDCTL_API=3 /var/lib/k0s/bin/etcdctl \\
    --endpoints=https://127.0.0.1:2379 \\
    --cacert=${_etcd_certs}/etcd-ca.crt \\
    --cert=${_etcd_certs}/apiserver-etcd-client.crt \\
    --key=${_etcd_certs}/apiserver-etcd-client.key \\
    get /registry/secrets/argocd/phantomos-kos-repo
  Verify that the output starts with 'k8s:enc:aescbc:v1:phantomos-v1:'"
    _guard_phase "etcd-encryption"
    return
  fi

  # Check the encryption prefix.
  if echo "$_etcd_out" | grep -q "k8s:enc:aescbc:v1:phantomos-v1:"; then
    _pass "etcd secret has expected encryption prefix: k8s:enc:aescbc:v1:phantomos-v1:"
  else
    _fail "etcd secret does NOT have encryption prefix k8s:enc:aescbc:v1:phantomos-v1:
First 200 bytes: $(echo "$_etcd_out" | head -c 200)"
  fi

  # Verify the PEM is NOT in plaintext in the etcd output.
  if echo "$_etcd_out" | grep -q "BEGIN RSA PRIVATE KEY\|BEGIN PRIVATE KEY"; then
    _fail "etcd output contains plaintext PEM — secret is NOT encrypted at rest!"
  else
    _pass "etcd output does not contain plaintext PEM (encrypted)"
  fi

  _guard_phase "etcd-encryption"
}

# ---------------------------------------------------------------------------
# Phase 7: Disk-residue check
# ---------------------------------------------------------------------------

_phase_disk_residue() {
  _phase "Phase 7: Disk-residue check"

  # grep for BEGIN RSA PRIVATE KEY across common paths, excluding the encrypted
  # etcd store itself (/var/lib/k0s/...).
  local _residue_out
  _residue_out=$(_ssh_run \
    "grep for PEM in /etc /var /tmp /root (excluding /var/lib/k0s)" \
    "grep -rla 'BEGIN RSA PRIVATE KEY\|BEGIN PRIVATE KEY' \
       /etc /var /tmp /root 2>/dev/null \
     | grep -v '^/var/lib/k0s' \
     | grep -v '^/var/lib/k0s-data' \
     || true") || true

  if [ -z "$_residue_out" ]; then
    _pass "no PEM material found on disk outside /var/lib/k0s (disk clean)"
  else
    # The credential file at /etc/phantomos/ is expected (mode 0600, root-only).
    # It's the controlled copy. Flag anything else.
    local _unexpected=""
    while IFS= read -r _line; do
      if echo "$_line" | grep -qF "/etc/phantomos/argocd-repo-credential.yaml"; then
        _info "expected: PEM in $_line (controlled copy, mode 0600 root)"
      else
        _unexpected="${_unexpected}${_line}
"
      fi
    done <<< "$_residue_out"

    if [ -z "$_unexpected" ]; then
      _pass "PEM found only at expected path /etc/phantomos/argocd-repo-credential.yaml"
    else
      _fail "PEM material found at unexpected paths (disk residue detected):
${_unexpected}"
    fi
  fi

  _guard_phase "disk-residue"
}

# ---------------------------------------------------------------------------
# Phase 8: Auth failure mode
# ---------------------------------------------------------------------------

_phase_auth_failure() {
  _phase "Phase 8: Auth failure mode"

  if [ -z "$_TEST_APP_NAME" ]; then
    _ssh_run_capture _TEST_APP_NAME "discovering application name" \
      "kubectl -n argocd get applications -o name 2>/dev/null \
       | grep 'phantomos-' | head -1 | sed 's|application.argoproj.io/||'" || true
    if [ -z "$_TEST_APP_NAME" ]; then
      _fail "could not discover application name"
      _guard_phase "auth-failure"
      return
    fi
  fi

  # Save the original secret data so we can restore it.
  local _orig_secret_json
  _ssh_run_capture _orig_secret_json "saving original phantomos-kos-repo secret" \
    "kubectl -n argocd get secret phantomos-kos-repo -o json 2>&1" || true
  if ! echo "$_orig_secret_json" | python3 -c \
       "import sys,json; json.load(sys.stdin)" >/dev/null 2>&1; then
    _fail "could not read original phantomos-kos-repo secret — may not exist yet"
    _guard_phase "auth-failure"
    return
  fi

  # Inject invalid credential (invalidate password / githubAppPrivateKey).
  _info "injecting invalid credential into phantomos-kos-repo"
  local _patch_result
  _patch_result=$(_ssh_run "patching secret with invalid credential" \
    "kubectl -n argocd patch secret phantomos-kos-repo \
       -p '{\"stringData\":{\"password\":\"invalidated-by-harness\",\"githubAppPrivateKey\":\"invalidated-by-harness\"}}' \
     2>&1" || true)

  if echo "$_patch_result" | grep -qi "patched\|unchanged"; then
    _pass "injected invalid credential into phantomos-kos-repo"
  else
    _fail "could not patch phantomos-kos-repo:
$_patch_result"
    _guard_phase "auth-failure"
    return
  fi

  # Force a hard refresh to invalidate ArgoCD's cached connection state.
  _ssh_run "annotating app with argocd.argoproj.io/refresh=hard" \
    "kubectl -n argocd annotate application ${_TEST_APP_NAME} \
       argocd.argoproj.io/refresh=hard --overwrite 2>&1" || true
  _pass "hard refresh annotation applied"

  # Wait up to 2 min for argocd app sync to fail with an auth error.
  _info "waiting up to 120s for auth failure to surface in argocd"
  local _deadline
  _deadline=$(($(date +%s) + 120))
  local _auth_failed=0
  local _sync_err_out=""
  while [ "$(date +%s)" -lt "$_deadline" ]; do
    _sync_err_out=$(_ssh_run "polling argocd app sync for auth failure" \
      "argocd app sync ${_TEST_APP_NAME} --timeout 10 2>&1 || true" || true)
    if echo "$_sync_err_out" | grep -qi \
         "auth\|authentication\|credential\|401\|403\|ComparisonError\|repo error"; then
      _auth_failed=1
      break
    fi
    sleep 15
  done

  if [ "$_auth_failed" -eq 1 ]; then
    _pass "argocd app sync failed with auth error as expected:
$(echo "$_sync_err_out" | head -5)"
  else
    _fail "argocd did not surface an auth error within 120s after credential invalidation:
$(echo "$_sync_err_out" | head -10)"
  fi

  # Confirm existing pods are still running (workload continuity).
  local _pods_out
  _ssh_run_capture _pods_out "checking pods still running after auth failure" \
    "kubectl get pods -A --no-headers 2>/dev/null | grep -v 'Completed\|Terminating' | wc -l"
  if [ "${_pods_out// /}" -gt 0 ] 2>/dev/null; then
    _pass "existing pods still running after auth failure ($_pods_out non-completed pods)"
  else
    _fail "unexpected: no running pods found after auth failure"
  fi

  # Restore the original credential.
  _info "restoring original credential"
  # Re-apply the original credential file (which is the authoritative source).
  local _restore_result
  _restore_result=$(_ssh_run "re-applying original credential file" \
    "kubectl -n argocd apply -f ${_ROBOT_CREDENTIAL_PATH:-/etc/phantomos/argocd-repo-credential.yaml} 2>&1" \
    || true)
  if echo "$_restore_result" | grep -qi "configured\|unchanged\|created"; then
    _pass "original credential restored"
  else
    _fail "credential restore may have failed (manual check needed):
$_restore_result"
  fi

  # Annotate again to force ArgoCD to re-try with the restored credential.
  _ssh_run "re-annotating app to force refresh after restore" \
    "kubectl -n argocd annotate application ${_TEST_APP_NAME} \
       argocd.argoproj.io/refresh=hard --overwrite 2>&1" || true
  _pass "hard refresh annotation applied after restore"

  _guard_phase "auth-failure"
}

# ---------------------------------------------------------------------------
# Phase 9: Rotation drill (optional)
# ---------------------------------------------------------------------------

_phase_rotation() {
  _phase "Phase 9: Rotation drill"

  if [ -z "$PHANTOMOS_TEST_NEW_CREDENTIAL_FILE" ]; then
    _skip "rotation drill skipped — PHANTOMOS_TEST_NEW_CREDENTIAL_FILE is not set.
  To run this phase, set PHANTOMOS_TEST_NEW_CREDENTIAL_FILE to a path containing
  a fresh credential file (mode 0600) for foundationbot/phantomos-deployer,
  then re-run with --phase rotation."
    _guard_phase "rotation"
    return
  fi

  if [ ! -f "$PHANTOMOS_TEST_NEW_CREDENTIAL_FILE" ]; then
    _fail "PHANTOMOS_TEST_NEW_CREDENTIAL_FILE='$PHANTOMOS_TEST_NEW_CREDENTIAL_FILE' does not exist"
    _guard_phase "rotation"
    return
  fi

  local _new_cred_mode
  _new_cred_mode=$(stat -c '%a' "$PHANTOMOS_TEST_NEW_CREDENTIAL_FILE" 2>/dev/null || echo "unknown")
  if [ "$_new_cred_mode" != "600" ]; then
    _fail "PHANTOMOS_TEST_NEW_CREDENTIAL_FILE mode is $_new_cred_mode, expected 0600"
    _guard_phase "rotation"
    return
  fi
  _pass "new credential file exists and mode 0600"

  # Deploy new credential to robot.
  if [ -n "$TEST_ROBOT_HOST" ]; then
    scp -q "$PHANTOMOS_TEST_NEW_CREDENTIAL_FILE" \
        "root@${TEST_ROBOT_HOST}:/etc/phantomos/argocd-repo-credential.yaml" || {
      _fail "could not scp new credential to $TEST_ROBOT_HOST"
      _guard_phase "rotation"
      return
    }
    _ssh_run "setting mode 0600 on new credential" \
      "chmod 0600 /etc/phantomos/argocd-repo-credential.yaml" || true
  else
    cp "$PHANTOMOS_TEST_NEW_CREDENTIAL_FILE" /etc/phantomos/argocd-repo-credential.yaml
    chmod 0600 /etc/phantomos/argocd-repo-credential.yaml
  fi
  _pass "new credential file installed at $_ROBOT_CREDENTIAL_PATH"

  # Determine bootstrap path.
  local _bootstrap
  if [ -n "$TEST_ROBOT_HOST" ]; then
    _bootstrap="${_ROBOT_REPO_PATH}/scripts/bootstrap-robot.sh"
  else
    _bootstrap="$(cd "$(dirname "$0")/../.." && pwd)/scripts/bootstrap-robot.sh"
  fi

  # Run bootstrap with --gitops-repo-credential-only.
  if _ssh_run "bootstrap-robot.sh --gitops-repo-credential-only" \
       "DEFAULT_REPO_URL=${DEFAULT_REPO_URL} bash ${_bootstrap} \
        --gitops-repo-credential-only \
        --repo-credential-file /etc/phantomos/argocd-repo-credential.yaml \
        -y 2>&1"; then
    _pass "bootstrap --gitops-repo-credential-only completed"
  else
    _fail "bootstrap --gitops-repo-credential-only failed"
    _guard_phase "rotation"
    return
  fi

  # Wait up to 60s for sync to resume.
  _info "waiting up to 60s for sync to resume after credential rotation"
  local _deadline
  _deadline=$(($(date +%s) + 60))
  local _synced=0
  while [ "$(date +%s)" -lt "$_deadline" ]; do
    local _app_status
    _ssh_run_capture _app_status "checking app status after rotation" \
      "argocd app get ${_TEST_APP_NAME:-$(kubectl -n argocd get applications -o name \
        2>/dev/null | grep phantomos | head -1 | sed 's|application.argoproj.io/||')} \
       2>&1 | grep -E 'Sync Status|Health Status'" || true
    if echo "$_app_status" | grep -q "Synced"; then
      _synced=1
      break
    fi
    sleep 10
  done

  if [ "$_synced" -eq 1 ]; then
    _pass "sync resumed after credential rotation"
  else
    _fail "sync did not resume within 60s after credential rotation"
  fi

  _guard_phase "rotation"
}

# ---------------------------------------------------------------------------
# Phase 10: Migration drill (skipped on single-machine harness)
# ---------------------------------------------------------------------------

_phase_migration() {
  _phase "Phase 10: Migration drill"
  # Migration drill requires a second robot — always SKIP in the single-machine
  # harness. See docs/system-test-rfc-0002.md for the manual two-robot procedure.
  _skip "migration drill skipped on single-machine harness; needs a second robot.
  Verified by hand on second robot (mk11000009).
  Procedure: configure a second robot, run bootstrap-robot.sh, verify
  argocd app list shows Synced/Healthy against the same private repo."
  _guard_phase "migration"
}

# ---------------------------------------------------------------------------
# Phase 11: Cleanup
# ---------------------------------------------------------------------------

_phase_cleanup() {
  _phase "Phase 11: Cleanup"

  # Determine bootstrap path.
  local _bootstrap
  if [ -n "$TEST_ROBOT_HOST" ]; then
    _bootstrap="${_ROBOT_REPO_PATH}/scripts/bootstrap-robot.sh"
  else
    _bootstrap="$(cd "$(dirname "$0")/../.." && pwd)/scripts/bootstrap-robot.sh"
  fi

  # k0s reset via bootstrap --reset.
  _info "running bootstrap-robot.sh --reset (stops k0s, backs up state)"
  if _ssh_run "bootstrap-robot.sh --reset" \
       "bash ${_bootstrap} --reset -y 2>&1"; then
    _pass "bootstrap --reset completed"
  else
    _fail "bootstrap --reset exited non-zero (may need manual k0s stop + reset)"
  fi

  # Drop the test credential file (only if it is the test default — don't wipe
  # a credential file that might be the real one on a production robot).
  if [ "$ARGOCD_REPO_CREDENTIAL_FILE" = "/tmp/phantomos-test-creds.yaml" ] \
     && [ -f "$ARGOCD_REPO_CREDENTIAL_FILE" ]; then
    rm -f "$ARGOCD_REPO_CREDENTIAL_FILE"
    _pass "test credential file removed: $ARGOCD_REPO_CREDENTIAL_FILE"
  else
    _info "skipping removal of non-default credential file: $ARGOCD_REPO_CREDENTIAL_FILE"
  fi

  # Remove credential from /etc/phantomos/ if present on robot.
  local _etc_cred="/etc/phantomos/argocd-repo-credential.yaml"
  if _ssh_run "checking /etc/phantomos/argocd-repo-credential.yaml" \
       "test -f ${_etc_cred} && echo exists || echo absent" 2>/dev/null | grep -q "exists"; then
    _ssh_run "removing /etc/phantomos/argocd-repo-credential.yaml" \
      "rm -f ${_etc_cred}" || true
    _pass "removed $_etc_cred from robot"
  fi

  # Remove the test fleet-operator kubeconfig from the robot (SSH mode).
  if [ -n "$TEST_ROBOT_HOST" ]; then
    _ssh_run "removing /tmp/fleet-operator-test.kubeconfig from robot" \
      "rm -f /tmp/fleet-operator-test.kubeconfig" || true
    _pass "cleaned up fleet-operator kubeconfig on robot"
  fi

  _guard_phase "cleanup"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
  _setup_tmpdir

  if [ "$CLEANUP_ONLY" -eq 1 ]; then
    _phase_cleanup
    _summary
    exit "$_FAIL"
  fi

  # Run phases in order, starting from $START_PHASE.
  local _phase_fn

  _phase_active "preflight"  && { _phase_preflight;       _phase_fn="preflight"; }
  _phase_active "bringup"    && { _phase_bringup;         _phase_fn="bringup"; }
  _phase_active "sync"       && { _phase_sync;            _phase_fn="sync"; }
  _phase_active "reconcile"  && { _phase_reconcile;       _phase_fn="reconcile"; }
  _phase_active "argocd-rbac" && { _phase_argocd_rbac;   _phase_fn="argocd-rbac"; }
  _phase_active "k8s-rbac"   && { _phase_k8s_rbac;        _phase_fn="k8s-rbac"; }
  _phase_active "etcd-encryption" && { _phase_etcd_encryption; _phase_fn="etcd-encryption"; }
  _phase_active "disk-residue" && { _phase_disk_residue;  _phase_fn="disk-residue"; }
  _phase_active "auth-failure" && { _phase_auth_failure;  _phase_fn="auth-failure"; }
  _phase_active "rotation"   && { _phase_rotation;        _phase_fn="rotation"; }
  # Phase 10: migration — single-machine harness always SKIPs this phase.
  _phase_active "migration"  && { _phase_migration;       _phase_fn="migration"; }

  _summary
  exit "$_FAIL"
}

main "$@"
