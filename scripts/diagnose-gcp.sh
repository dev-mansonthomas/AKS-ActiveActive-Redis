#!/usr/bin/env bash
# ============================================================================
# diagnose-gcp.sh — show the RAW gcloud errors the preflight swallowed
# ============================================================================
# The preflight hides stderr to keep its output readable, which makes a
# permission problem indistinguishable from a missing resource. This prints
# everything verbatim so we can tell them apart.
#
# Read-only. HOST ONLY (needs gcloud). Log: debug/diagnose-gcp-<timestamp>.log
# ============================================================================

set -uo pipefail

_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/lib.sh"
if [ ! -r "$_LIB" ]; then
  echo "FATAL: cannot read $_LIB" >&2
  exit 1
fi
# shellcheck source=../common/lib.sh
. "$_LIB" || { echo "FATAL: failed to load $_LIB" >&2; exit 1; }

re_load_config
re_log_init "diagnose-gcp"

hr() { echo "──────────────────────────────────────────────────────────────"; }

show() {
  local label="$1"; shift
  hr
  echo "▶ $label"
  echo "\$ $*"
  "$@" 2>&1 | sed 's/^/  /'
  echo "  → exit=${PIPESTATUS[0]}"
}

echo "config.sh GCP_PROJECT_ID = $GCP_PROJECT_ID"
echo "config.sh regions        = $GCP_REGION1 / $GCP_REGION2"
echo "config.sh instance type  = $GCP_INSTANCE_TYPE"
echo "config.sh DNS_ZONE       = $DNS_ZONE"

show "Who am I (gcloud CLI identity)" \
  gcloud auth list

show "Active gcloud config (project may differ from config.sh!)" \
  gcloud config list

# Never write an access token to a log file — report presence only.
hr
echo "▶ Application Default Credentials — what OpenTofu actually uses"
if gcloud auth application-default print-access-token >/dev/null 2>&1; then
  echo "  present and refreshable (token NOT logged)"
else
  echo "  MISSING or unrefreshable:"
  gcloud auth application-default print-access-token 2>&1 | sed 's/^/    /'
  echo "  → fix with: gcloud auth application-default login"
fi

hr
echo "▶ gcloud CLI credential (separate from ADC — this is what broke before)"
if gcloud auth print-access-token >/dev/null 2>&1; then
  echo "  present and refreshable (token NOT logged)"
else
  echo "  EXPIRED or unrefreshable:"
  gcloud auth print-access-token 2>&1 | sed 's/^/    /'
  echo "  → fix with: gcloud auth login"
fi

show "ADC scopes/audience (identity only; no token echoed)" \
  sh -c 'curl -sS -H "Authorization: Bearer $(gcloud auth application-default print-access-token 2>/dev/null)" \
    "https://oauth2.googleapis.com/tokeninfo" 2>/dev/null | jq "{azp,aud,scope,email,expires_in}" 2>/dev/null'

show "Project describe (needs resourcemanager.projects.get)" \
  gcloud projects describe "$GCP_PROJECT_ID"

show "Enabled services (needs serviceusage.services.list)" \
  gcloud services list --enabled --project "$GCP_PROJECT_ID"

show "Regions (needs compute.regions.list + compute API)" \
  gcloud compute regions list --project "$GCP_PROJECT_ID" --format='value(name)'

show "Region $GCP_REGION1 describe" \
  gcloud compute regions describe "$GCP_REGION1" --project "$GCP_PROJECT_ID"

show "Machine type $GCP_INSTANCE_TYPE in $GCP_REGION1" \
  gcloud compute machine-types list \
    --filter="name=$GCP_INSTANCE_TYPE AND zone~^$GCP_REGION1" \
    --project "$GCP_PROJECT_ID" --format='value(name,zone)'

show "Cloud DNS managed zones" \
  gcloud dns managed-zones list --project "$GCP_PROJECT_ID"

show "GKE clusters already present" \
  gcloud container clusters list --project "$GCP_PROJECT_ID"

hr
echo "▶ What OpenTofu can actually see (the only test that really matters)"
echo "  This uses ADC, exactly like a real deploy."
(
  cd "$REPO_ROOT/providers/gcp" || exit 1
  RE_OFFLINE=1 re_export_tf_vars >/dev/null 2>&1
  export TF_VAR_project_id="$GCP_PROJECT_ID"
  tofu init -input=false >/dev/null 2>&1
  tofu plan -input=false -lock=false 2>&1 | tail -25 | sed 's/^/  /'
)

hr
echo
echo "Send back this whole output (or the log file) — it distinguishes"
echo "'no permission to ask' from 'the resource does not exist'."
