#!/usr/bin/env bash
# ============================================================================
# gcp-setup.sh — ONE-OFF IAM setup for the GCP project (run BEFORE gcp-deploy.sh)
# ============================================================================
# Creates what the deploy needs but is deliberately NOT allowed to create itself
# (docs/gcp-iam.md): the dedicated, least-privilege service account the GKE
# nodes run as, and the IAM bindings that let the deploy identity use it.
#
#   ./gcp-setup.sh --dry-run   # print every change, touch nothing (review this!)
#   ./gcp-setup.sh             # apply — idempotent, safe to re-run
#
# Reads config.sh:
#   GCP_PROJECT_ID, GCP_NODE_SERVICE_ACCOUNT   the node SA to create
#   GCP_ACCOUNT                                the DEPLOY identity (receives the bindings)
#   GCP_DEPLOYER_ROLES                         project roles granted to the deploy identity
#   GCP_REQUIRED_APIS                          APIs enabled on the project
#   GCP_ADMIN_ACCOUNT (optional)               who runs THIS script; default = the
#                                              active gcloud account
#
# It must run as a human/admin with IAM rights. It REFUSES to run as the deploy
# identity: that one must never hold rights to edit IAM (privilege escalation).
# HOST ONLY — needs gcloud credentials, which do not exist in the VM.
# ============================================================================

set -uo pipefail

_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common/lib.sh"
if [ ! -r "$_LIB" ]; then
  echo "FATAL: cannot read $_LIB" >&2
  exit 1
fi
# shellcheck source=common/lib.sh
. "$_LIB" || { echo "FATAL: failed to load $_LIB" >&2; exit 1; }

DRY_RUN=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY_RUN=1 ;;
  -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
  *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
esac

re_load_config
re_log_init "gcp-setup"

[ "$CLOUD_PROVIDER" = "gcp" ] || re_die "config.sh has CLOUD_PROVIDER=$CLOUD_PROVIDER, expected gcp"
re_require GCP_PROJECT_ID
re_require GCP_NODE_SERVICE_ACCOUNT
re_require GCP_ACCOUNT
re_require GCP_DEPLOYER_ROLES
re_require GCP_REQUIRED_APIS

P="$GCP_PROJECT_ID"
NODE_SA="$GCP_NODE_SERVICE_ACCOUNT"
DEPLOYER="$GCP_ACCOUNT"
NODE_SA_NAME="${NODE_SA%%@*}"

[ "$NODE_SA" = "${NODE_SA_NAME}@${P}.iam.gserviceaccount.com" ] \
  || re_die "GCP_NODE_SERVICE_ACCOUNT must be <name>@${P}.iam.gserviceaccount.com (got $NODE_SA)"

# member syntax differs for users and service accounts
member_of() { case "$1" in *.gserviceaccount.com) echo "serviceAccount:$1" ;; *) echo "user:$1" ;; esac; }

# ---- who runs this ----------------------------------------------------------
if [ "$DRY_RUN" -eq 1 ] && ! command -v gcloud >/dev/null 2>&1; then
  ADMIN="${GCP_ADMIN_ACCOUNT:-<active gcloud account>}"
else
  command -v gcloud >/dev/null 2>&1 || re_die "gcloud not found — run this on the host, not in the VM"
  ADMIN="${GCP_ADMIN_ACCOUNT:-$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -1)}"
  [ -n "$ADMIN" ] || re_die "no active gcloud account — run: gcloud auth login"
fi
if [ "$ADMIN" = "$DEPLOYER" ]; then
  re_die "refusing to run as the deploy identity ($DEPLOYER): it must not hold IAM rights. Use an admin account (gcloud auth login, or GCP_ADMIN_ACCOUNT in config.sh)."
fi

re_log "Project        : $P"
re_log "Node SA        : $NODE_SA"
re_log "Deploy identity: $DEPLOYER   (receives the bindings)"
re_log "Running as     : $ADMIN"
[ "$DRY_RUN" -eq 1 ] && re_log "DRY RUN — nothing will be changed"

ACC=(); [ -n "${GCP_ADMIN_ACCOUNT:-}" ] && ACC=(--account "$GCP_ADMIN_ACCOUNT")

# step <description> <command...> — print, then run unless --dry-run
FAILED=0
step() {
  local desc="$1"; shift
  re_log "→ $desc"
  re_log "    $(printf '%q ' "$@")"
  [ "$DRY_RUN" -eq 1 ] && return 0
  if "$@" >/dev/null; then
    re_log "  ✅ done"
  else
    re_warn "  ❌ failed: $desc"
    FAILED=$((FAILED + 1))
  fi
}

# ---- 0. APIs (idempotent; needs serviceusage.services.enable) ----------------
step "enable the required APIs ($GCP_REQUIRED_APIS)" \
  gcloud services enable $GCP_REQUIRED_APIS --project "$P" "${ACC[@]}"

# ---- 1. the node service account (created once) ----------------------------
if [ "$DRY_RUN" -eq 0 ] && gcloud iam service-accounts describe "$NODE_SA" --project "$P" "${ACC[@]}" >/dev/null 2>&1; then
  re_log "✅ node service account already exists"
else
  step "create the node service account" \
    gcloud iam service-accounts create "$NODE_SA_NAME" --project "$P" "${ACC[@]}" \
      --display-name "GKE nodes (Redis Active-Active demo)"
fi

# ---- 2. least-privilege runtime role for the nodes --------------------------
# (--format=none: the project policy is huge on a shared project)
step "grant the node SA its runtime role (logging, monitoring, metadata, image pull)" \
  gcloud projects add-iam-policy-binding "$P" "${ACC[@]}" \
    --member="serviceAccount:$NODE_SA" --role="roles/container.defaultNodeServiceAccount" \
    --condition=None --format=none --quiet

# ---- 3. the deploy identity may attach (actAs) the node SA — this SA only ----
step "let the deploy identity actAs the node SA" \
  gcloud iam service-accounts add-iam-policy-binding "$NODE_SA" --project "$P" "${ACC[@]}" \
    --member="$(member_of "$DEPLOYER")" --role="roles/iam.serviceAccountUser" \
    --format=none --quiet

# ---- 4. project roles the deploy identity needs (docs/gcp-iam.md §3) --------
for role in $GCP_DEPLOYER_ROLES; do
  step "grant $role to the deploy identity" \
    gcloud projects add-iam-policy-binding "$P" "${ACC[@]}" \
      --member="$(member_of "$DEPLOYER")" --role="$role" \
      --condition=None --format=none --quiet
done

if [ "$FAILED" -gt 0 ]; then
  re_warn "$FAILED step(s) failed — see above. You probably lack IAM admin rights on $P."
  exit 1
fi
if [ "$DRY_RUN" -eq 1 ]; then
  re_log "✅ dry run complete — review the commands above, then run ./gcp-setup.sh"
else
  re_log "✅ GCP project ready. Next: ./gcp-deploy.sh --plan-only"
fi
