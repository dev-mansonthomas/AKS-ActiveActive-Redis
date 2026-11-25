#!/usr/bin/env bash
# ============================================================================
# Fail early and clearly if this file is sourced by something too old, rather
# than dying later on a missing function. Everything here is written to be
# parseable by bash 3.2 (which macOS still ships as /bin/bash).
# ============================================================================
if [ -z "${BASH_VERSION:-}" ]; then
  echo "FATAL: common/lib.sh requires bash (not sh/dash/zsh)" >&2
  return 1 2>/dev/null || exit 1
fi
# ============================================================================
# common/lib.sh — shared helpers for every script in this repository
# ============================================================================
# Source it as the FIRST thing a script does:
#
#     . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/lib.sh"
#
# It provides:
#   REPO_ROOT              absolute path to the repository root (CWD-independent)
#   re_load_config         source config.sh once, from anywhere
#   re_log_init <name>     start logging this run to debug/<name>-<ts>.log
#   re_log / re_warn / re_die / re_run
#   re_export_tf_vars      export every TF_VAR_* Terraform needs, from config.sh
#   re_require             assert a config variable is set and non-empty
#
# Set RE_OFFLINE=1 to export TF_VAR_* without requiring a cloud CLI or a live
# session. Used by scripts/verify-config.sh so the VM can prove that config.sh
# fully satisfies Terraform, credential-free.
# ============================================================================

# --- Repository root, independent of the caller's working directory ---------
# shellcheck disable=SC2128
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

DEBUG_DIR="$REPO_ROOT/debug"
export DEBUG_DIR

# Templates (tracked) and generated manifests (gitignored).
TEMPLATES_DIR="$REPO_ROOT/templates"
YAML_DIR="$REPO_ROOT/yaml"
export TEMPLATES_DIR YAML_DIR

# ============================================================================
# Configuration
# ============================================================================

# Load config.sh exactly once, whatever the current directory.
re_load_config() {
  if [ -n "${RE_CONFIG_LOADED:-}" ]; then return 0; fi
  if [ ! -f "$REPO_ROOT/config.sh" ]; then
    echo "❌ $REPO_ROOT/config.sh not found." >&2
    echo "   Copy the template first:  cp config.example.sh config.sh" >&2
    return 1
  fi
  # `set -a` exports everything config.sh defines, so child scripts inherit the
  # whole configuration. Without this, RE_CONFIG_LOADED would propagate to a
  # child while the values themselves would not — the child would then see
  # "CLOUD_PROVIDER: unbound variable".
  set -a
  # shellcheck source=/dev/null
  . "$REPO_ROOT/config.sh" || { set +a; return 1; }
  set +a
  RE_CONFIG_LOADED=1
  export RE_CONFIG_LOADED
}

# re_to_tf_list "a,b,c" -> ["a","b","c"]
# Terraform reads list variables from TF_VAR_* as HCL/JSON, so a comma-separated
# value from config.sh has to be converted. Keeps config.sh readable.
re_to_tf_list() {
  printf '%s' "$1" | awk -F, '{
    printf "[";
    for (i = 1; i <= NF; i++) {
      gsub(/^[ \t]+|[ \t]+$/, "", $i);
      if ($i == "") continue;
      printf "%s\"%s\"", (i > 1 ? "," : ""), $i;
    }
    printf "]";
  }'
}

# re_count_csv "a,b,c" -> 3
re_count_csv() {
  printf '%s' "$1" | awk -F, '{n=0; for (i=1;i<=NF;i++) if ($i != "") n++; print n}'
}

# re_require VAR_NAME [hint] — fail loudly when a config value is missing.
re_require() {
  local name="$1" hint="${2:-}"
  local value="${!name:-}"
  if [ -z "$value" ]; then
    re_die "config.sh: '$name' is not set${hint:+ ($hint)}"
  fi
}

# ============================================================================
# Logging — everything lands in debug/ (gitignored)
# ============================================================================

# re_log_init <script-name> — tee all stdout/stderr into debug/<name>-<ts>.log
re_log_init() {
  local name="${1:-run}"
  mkdir -p "$DEBUG_DIR"
  RE_LOG_FILE="$DEBUG_DIR/${name}-$(date +%Y%m%d-%H%M%S).log"
  export RE_LOG_FILE
  # Keep a stable symlink to the most recent run of this script.
  ln -sfn "$(basename "$RE_LOG_FILE")" "$DEBUG_DIR/${name}-latest.log"
  # Record whether we started on a terminal BEFORE redirecting. The `tee`
  # below makes stdout a pipe, so `[ -t 1 ]` is false for the rest of the
  # script — any later "am I interactive?" test must use these instead.
  [ -t 0 ] && RE_STDIN_TTY=1 || RE_STDIN_TTY=0
  [ -t 1 ] && RE_STDOUT_TTY=1 || RE_STDOUT_TTY=0
  export RE_STDIN_TTY RE_STDOUT_TTY

  # Duplicate stdout+stderr into the log file without losing the terminal.
  exec > >(tee -a "$RE_LOG_FILE") 2>&1
  re_log "── $name started ── log: ${RE_LOG_FILE#"$REPO_ROOT"/}"
  re_log "   cloud=${CLOUD_PROVIDER:-<unset>} user=$(whoami) host=$(hostname)"

  # Always tell the operator where the log is, however the script ends —
  # including re_die and unexpected failures. Registered once per script.
  trap '_re_log_footer $?' EXIT
}

# Printed on every exit path. Keep it short and always last.
_re_log_footer() {
  local rc="${1:-0}"
  [ -n "${RE_LOG_FILE:-}" ] || return 0
  # tee is asynchronous; give it a moment so the footer is not truncated.
  if [ "$rc" -eq 0 ]; then
    echo "[$(_re_ts)] 📄 log: ${RE_LOG_FILE#"$REPO_ROOT"/}"
  else
    echo "[$(_re_ts)] 📄 log: ${RE_LOG_FILE#"$REPO_ROOT"/}  (exit $rc)"
    echo "[$(_re_ts)]    errors across all runs:  ./scripts/logs.sh errors"
  fi
}

_re_ts() { date '+%Y-%m-%d %H:%M:%S'; }

# ============================================================================
# Portability helpers — these scripts run on the HOST, which is macOS (BSD
# userland), while the VM is Linux (GNU coreutils). Anything touching stat,
# date -r or base64 differs between the two.
# ============================================================================

# re_file_mtime <path> — "YYYY-MM-DD HH:MM:SS" of a file's mtime.
# `date -r FILE` is GNU-only: on BSD/macOS, -r takes an epoch, not a path.
re_file_mtime() {
  local f="$1" out
  # GNU coreutils. Require non-empty output, not just exit 0: a stat that
  # succeeds with nothing to say would otherwise short-circuit the fallback.
  out=$(stat -c '%y' "$f" 2>/dev/null)
  if [ -n "$out" ]; then
    printf '%s' "${out%%.*}"
    return 0
  fi
  # BSD / macOS
  out=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$f" 2>/dev/null)
  if [ -n "$out" ]; then
    printf '%s' "$out"
    return 0
  fi
  printf '?'
}

# re_raise_fd_limit — raise this process's open-file limit.
# macOS defaults to 256. Terraform holds TLS connections plus a polling loop
# per concurrent operation; once the resolver cannot open a socket, Go reports
# "no such host", which looks like a DNS outage and hides the real cause.
# Soft-limit only, no privileges needed, and scoped to this process tree.
# shellcheck disable=SC2120  # the argument is optional by design
re_raise_fd_limit() {
  local want="${1:-4096}" cur
  cur=$(ulimit -n 2>/dev/null) || return 0
  [ "$cur" = "unlimited" ] && return 0
  if [ "$cur" -ge "$want" ] 2>/dev/null; then
    return 0
  fi
  if ulimit -n "$want" 2>/dev/null; then
    re_log "file descriptor limit raised: $cur -> $(ulimit -n)"
  else
    # Try the hard limit instead of giving up entirely.
    local hard
    hard=$(ulimit -Hn 2>/dev/null || echo "")
    if [ -n "$hard" ] && [ "$hard" != "unlimited" ] && [ "$hard" -gt "$cur" ] 2>/dev/null \
       && ulimit -n "$hard" 2>/dev/null; then
      re_log "file descriptor limit raised: $cur -> $hard (hard limit reached)"
    else
      re_warn "could not raise the fd limit above $cur."
      re_warn "   Long Terraform runs may fail with a misleading \"no such host\"."
      re_warn "   Mitigation in place: TF_PARALLELISM=${TF_PARALLELISM:-4}."
    fi
  fi
}

# re_upper <text> — uppercase, without bash 4's ${var^^}.
# macOS still ships bash 3.2 as /bin/bash, where ${var^^} is a PARSE error —
# the script would not even start. Keep the whole tree bash-3.2-parseable.
re_upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

# re_b64_decode — read base64 on stdin, write bytes on stdout.
# GNU uses -d; older BSD/macOS only accepts -D.
re_b64_decode() {
  if printf 'eA==' | base64 -d >/dev/null 2>&1; then
    base64 -d
  else
    base64 -D
  fi
}
re_log()  { echo "[$(_re_ts)] $*"; }
re_warn() { echo "[$(_re_ts)] ⚠️  $*" >&2; }
re_die()  { echo "[$(_re_ts)] ❌ $*" >&2; exit 1; }

# re_retry <attempts> <delay> -- <cmd...> — retry a transient failure.
# Provider downloads and cloud APIs fail on brief network blips; a 10s timeout
# should not abort a 30-minute deployment.
re_retry() {
  local attempts="$1" delay="$2"; shift 2
  local n=1 rc=0
  while :; do
    rc=0
    "$@" || rc=$?
    [ "$rc" -eq 0 ] && return 0
    if [ "$n" -ge "$attempts" ]; then
      re_warn "failed after $n attempt(s): $*"
      return "$rc"
    fi
    re_warn "attempt $n/$attempts failed (exit $rc), retrying in ${delay}s: $1"
    sleep "$delay"
    n=$((n + 1))
  done
}

# re_tofu_init — `tofu init` with retries, for flaky registry access.
re_tofu_init() {
  re_log "▶ tofu init"
  re_retry 3 10 tofu init -input=false "$@"
}

# _re_is_transient <output> — worth retrying, or hopeless?
# Retrying a deterministic failure just wastes minutes and hides the real
# message. Only network/rate-limit style failures are retryable.
_re_is_transient() {
  case "$1" in
    *"no such host"*|*"dial tcp"*|*"connection refused"*|*"connection reset"* \
    |*"i/o timeout"*|*"TLS handshake timeout"*|*"Client.Timeout"* \
    |*"cannot fetch token"*|*"EOF"*|*"try again"* \
    |*"rateLimitExceeded"*|*"quotaExceeded"*|*"Too Many Requests"*|*"429"* \
    |*"backendError"*|*"500"*|*"502"*|*"503"*|*"Internal error"*|*"unavailable"*)
      return 0 ;;
  esac
  return 1
}

# _re_tofu_retry <label> <max> <delay> -- <tofu args...>
# Runs tofu, and retries ONLY when the failure looks transient. On a permanent
# error it stops at once and shows the last output.
_re_tofu_retry() {
  local label="$1" max="$2" delay="$3"; shift 3
  local n=1 rc out cap
  while :; do
    rc=0
    # Stream to the terminal AND keep a copy to classify the failure.
    # A plain `out=$(tofu ...)` would swallow all progress output — during a
    # 10-40 minute GKE apply the operator would stare at a silent terminal.
    cap=$(mktemp)
    tofu "$@" 2>&1 | tee "$cap"
    rc=${PIPESTATUS[0]}
    out=$(cat "$cap"); rm -f "$cap"

    [ "$rc" -eq 0 ] && { re_log "✅ $label ok"; return 0; }

    # Ctrl-C / SIGTERM: the operator asked us to stop. Never retry, and say
    # what to do next, because Terraform has just written its state.
    if [ "$rc" -ge 130 ] || printf '%s' "$out" | grep -q "Interrupt received"; then
      re_warn "$label interrupted (exit $rc)."
      re_warn "   Terraform shut down gracefully and saved its state."
      re_warn "   Clean up with:  ./${CLOUD_PROVIDER}-deploy.sh --destroy"
      re_warn "   Then verify:    ./check-tags.sh --expect-empty"
      return "$rc"
    fi

    if ! _re_is_transient "$out"; then
      re_warn "$label failed with a permanent error — not retrying."
      return "$rc"
    fi
    if [ "$n" -ge "$max" ]; then
      re_warn "$label failed after $n attempt(s) of transient errors."
      return "$rc"
    fi
    re_warn "$label: transient failure (attempt $n/$max), retrying in ${delay}s"
    sleep "$delay"
    n=$((n + 1))
  done
}

# re_tofu_apply — apply, retrying transient network failures only.
# GKE cluster creation takes ~10 min per cluster, so a single DNS hiccup used
# to abandon the whole run. Terraform reconciles against its state, so a retry
# resumes where it stopped and is a no-op for whatever already succeeded.
re_tofu_apply() {
  re_raise_fd_limit
  _re_tofu_retry "tofu apply" 3 30 \
    apply -auto-approve -input=false -parallelism="${TF_PARALLELISM:-4}" "$@"
}

# re_gcp_clean_orphan_firewalls — remove the k8s-* firewall rules that GKE
# creates for LoadBalancer Services and that OUTLIVE the cluster.
#
# They are not in Terraform state, they reference our VPC, and a VPC cannot be
# deleted while a firewall points at it. Symptom:
#   Error waiting for Deleting Network: The network resource '<prefix>-vpc' is
#   already being used by 'firewalls/k8s-<hash>-node-http-hc'
re_gcp_clean_orphan_firewalls() {
  [ "${CLOUD_PROVIDER:-}" = "gcp" ] || return 0
  command -v gcloud >/dev/null 2>&1 || return 0
  local vpc="${CLUSTER_PREFIX}-vpc" list fw
  list=$(gcloud compute firewall-rules list --project "$GCP_PROJECT_ID" \
    --filter="network~${vpc}\$ AND name~^k8s-" --format='value(name)' 2>/dev/null || true)
  [ -n "$list" ] || return 0
  re_warn "GKE left firewall rules attached to $vpc; they block its deletion:"
  for fw in $list; do
    re_warn "   ⛔ $fw"
    gcloud compute firewall-rules delete "$fw" --project "$GCP_PROJECT_ID" --quiet \
      >/dev/null 2>&1 || re_warn "      could not delete $fw"
  done
}

# re_tofu_destroy — destroy, with one self-healing case.
#
# The google provider defaults google_container_cluster.deletion_protection to
# true (v6.0+). If clusters were created while that was in effect, the flag is
# stored SERVER-SIDE, and `destroy` refuses before it can update it. The cure
# is a targeted apply that pushes deletion_protection=false onto the clusters
# only (no other resource is touched), then destroy again.
re_tofu_destroy() {
  local rc=0 out
  re_raise_fd_limit
  local par="-parallelism=${TF_PARALLELISM:-4}" cap
  cap=$(mktemp)
  tofu destroy -auto-approve -input=false "$par" "$@" 2>&1 | tee "$cap"
  rc=${PIPESTATUS[0]}
  out=$(cat "$cap"); rm -f "$cap"
  [ "$rc" -eq 0 ] && { re_log "✅ tofu destroy ok"; return 0; }

  case "$out" in
    *"deletion_protection is set to true"*)
      re_warn "clusters still carry deletion_protection=true server-side."
      re_warn "Pushing deletion_protection=false onto the clusters only, then retrying."
      local targets="" res
      for res in $(tofu state list 2>/dev/null | grep '^google_container_cluster\.'); do
        targets="$targets -target=$res"
      done
      if [ -z "$targets" ]; then
        re_warn "no google_container_cluster in state — cannot self-heal"
        return "$rc"
      fi
      # shellcheck disable=SC2086
      if ! _re_tofu_retry "tofu apply (deletion_protection)" 3 20 \
             apply -auto-approve -input=false $targets; then
        re_warn "could not clear deletion_protection"
        return 1
      fi
      _re_tofu_retry "tofu destroy (retry)" 3 30 destroy -auto-approve -input=false "$par" "$@"
      return $?
      ;;
  esac

  case "$out" in
    *"is already being used by"*"firewalls/k8s-"*)
      re_warn "the VPC is held by GKE-created firewall rules."
      re_gcp_clean_orphan_firewalls
      _re_tofu_retry "tofu destroy (after firewall cleanup)" 2 15 \
        destroy -auto-approve -input=false "$par" "$@"
      return $?
      ;;
  esac

  if _re_is_transient "$out"; then
    _re_tofu_retry "tofu destroy" 4 30 destroy -auto-approve -input=false "$par" "$@"
    return $?
  fi
  re_warn "tofu destroy failed with a permanent error — not retrying."
  return "$rc"
}

# re_run <cmd...> — log a command, run it, log its exit status.
re_run() {
  re_log "▶ $*"
  local start=$SECONDS rc=0
  "$@" || rc=$?
  if [ $rc -eq 0 ]; then
    re_log "✅ ok ($((SECONDS - start))s): $1"
  else
    re_warn "exit $rc after $((SECONDS - start))s: $*"
  fi
  return $rc
}

# ============================================================================
# config.sh -> TF_VAR_* : Terraform gets ALL of its input from config.sh.
# No .tfvars files, and no defaults in variables.tf.
# ============================================================================
re_export_tf_vars() {
  re_load_config || return 1

  re_require CLOUD_PROVIDER
  re_require CLUSTER_PREFIX
  re_require owner "format: firstname_lastname"
  re_require skip_deletion "yes or no"

  # Pin the right cloud identity before any CLI call.
  re_cloud_select_account

  # Common to every provider. owner/skip_deletion are set by config.sh.
  # shellcheck disable=SC2154
  export TF_VAR_owner="$owner"
  # shellcheck disable=SC2154
  export TF_VAR_skip_deletion="$skip_deletion"
  export TF_VAR_cluster_prefix="$CLUSTER_PREFIX"

  case "$CLOUD_PROVIDER" in
    azure)
      re_require AZURE_CLUSTER_RESOURCE_GROUP
      re_require AZURE_REGION1; re_require AZURE_REGION2
      re_require AZURE_INSTANCE_TYPE; re_require AZURE_NODE_COUNT
      re_require AZURE_DNS_PREFIX; re_require AZURE_NETWORK_PLUGIN
      re_require AZURE_LOAD_BALANCER_SKU
      # subscription_id comes from the host's az session, not config.sh.
      if [ -n "${RE_OFFLINE:-}" ]; then
        export TF_VAR_subscription_id="00000000-0000-0000-0000-000000000000"
      else
        command -v az >/dev/null 2>&1 || re_die "'az' CLI not found (run from the host, not the VM)"
        local sub_id
        sub_id="$(az account show --query id -o tsv)" || re_die "az account show failed — is 'az login' done?"
        export TF_VAR_subscription_id="$sub_id"
      fi
      export TF_VAR_azure_rg="$AZURE_CLUSTER_RESOURCE_GROUP"
      export TF_VAR_region1="$AZURE_REGION1"
      export TF_VAR_region2="$AZURE_REGION2"
      export TF_VAR_instance_type="$AZURE_INSTANCE_TYPE"
      export TF_VAR_node_count="$AZURE_NODE_COUNT"
      export TF_VAR_dns_prefix="$AZURE_DNS_PREFIX"
      export TF_VAR_network_plugin="$AZURE_NETWORK_PLUGIN"
      re_require AZURE_ZONES
      # AKS node_count is the TOTAL for the pool; `zones` spreads it.
      TF_VAR_zones="$(re_to_tf_list "$AZURE_ZONES")"; export TF_VAR_zones
      re_log "AKS: $AZURE_NODE_COUNT node(s) TOTAL across $(re_count_csv "$AZURE_ZONES") zones"
      export TF_VAR_load_balancer_sku="$AZURE_LOAD_BALANCER_SKU"
      ;;
    aws)
      re_require AWS_REGION1; re_require AWS_REGION2
      re_require AWS_INSTANCE_TYPE; re_require AWS_EKS_VERSION
      re_require AWS_NODE_DESIRED_SIZE; re_require AWS_NODE_MIN_SIZE
      re_require AWS_NODE_MAX_SIZE
      re_require AWS_VPC_CIDR1; re_require AWS_VPC_CIDR2
      [ -n "${RE_OFFLINE:-}" ] || command -v aws >/dev/null 2>&1 \
        || re_die "'aws' CLI not found (run from the host, not the VM)"
      export AWS_DEFAULT_REGION="$AWS_REGION1"
      export TF_VAR_region1="$AWS_REGION1"
      export TF_VAR_region2="$AWS_REGION2"
      export TF_VAR_eks_version="$AWS_EKS_VERSION"
      export TF_VAR_node_instance_type="$AWS_INSTANCE_TYPE"
      export TF_VAR_node_desired_size="$AWS_NODE_DESIRED_SIZE"
      export TF_VAR_node_min_size="$AWS_NODE_MIN_SIZE"
      export TF_VAR_node_max_size="$AWS_NODE_MAX_SIZE"
      re_require AWS_AZ_COUNT
      # EKS desired_size is the TOTAL; the node group balances across subnets.
      export TF_VAR_az_count="$AWS_AZ_COUNT"
      re_log "EKS: $AWS_NODE_DESIRED_SIZE node(s) TOTAL across $AWS_AZ_COUNT AZs"
      export TF_VAR_vpc_cidr1="$AWS_VPC_CIDR1"
      export TF_VAR_vpc_cidr2="$AWS_VPC_CIDR2"
      ;;
    gcp)
      re_require GCP_PROJECT_ID "this is the variable whose absence broke GCP deploys"
      re_require GCP_REGION1; re_require GCP_REGION2
      re_require GCP_INSTANCE_TYPE; re_require GCP_NODE_COUNT
      re_require GCP_NODE_MIN_COUNT; re_require GCP_NODE_MAX_COUNT
      re_require GCP_INITIAL_NODE_COUNT; re_require GCP_RELEASE_CHANNEL
      re_require GCP_SUBNET_CIDR1; re_require GCP_SUBNET_CIDR2
      re_require GCP_PODS_CIDR1; re_require GCP_PODS_CIDR2
      re_require GCP_SERVICES_CIDR1; re_require GCP_SERVICES_CIDR2
      re_require GCP_REDIS_PORTS
      [ -n "${RE_OFFLINE:-}" ] || command -v gcloud >/dev/null 2>&1 \
        || re_die "'gcloud' CLI not found (run from the host, not the VM)"
      export TF_VAR_project_id="$GCP_PROJECT_ID"
      export TF_VAR_region1="$GCP_REGION1"
      export TF_VAR_region2="$GCP_REGION2"
      export TF_VAR_node_machine_type="$GCP_INSTANCE_TYPE"
      export TF_VAR_node_count="$GCP_NODE_COUNT"
      export TF_VAR_node_min_count="$GCP_NODE_MIN_COUNT"
      export TF_VAR_node_max_count="$GCP_NODE_MAX_COUNT"
      export TF_VAR_initial_node_count="$GCP_INITIAL_NODE_COUNT"
      export TF_VAR_release_channel="$GCP_RELEASE_CHANNEL"
      re_require GCP_ZONES1; re_require GCP_ZONES2
      # node_locations makes the zone spread explicit rather than GKE's default.
      re_require GCP_CLUSTER_TIMEOUT; re_require GCP_NODE_POOL_TIMEOUT
      export TF_VAR_cluster_timeout="$GCP_CLUSTER_TIMEOUT"
      export TF_VAR_node_pool_timeout="$GCP_NODE_POOL_TIMEOUT"
      TF_VAR_zones1="$(re_to_tf_list "$GCP_ZONES1")"; export TF_VAR_zones1
      TF_VAR_zones2="$(re_to_tf_list "$GCP_ZONES2")"; export TF_VAR_zones2
      re_log "GKE: $GCP_NODE_COUNT node(s) PER ZONE x $(re_count_csv "$GCP_ZONES1")/$(re_count_csv "$GCP_ZONES2") zones"
      export TF_VAR_subnet_cidr1="$GCP_SUBNET_CIDR1"
      export TF_VAR_subnet_cidr2="$GCP_SUBNET_CIDR2"
      export TF_VAR_pods_cidr1="$GCP_PODS_CIDR1"
      export TF_VAR_pods_cidr2="$GCP_PODS_CIDR2"
      export TF_VAR_services_cidr1="$GCP_SERVICES_CIDR1"
      export TF_VAR_services_cidr2="$GCP_SERVICES_CIDR2"
      export TF_VAR_redis_ports="$GCP_REDIS_PORTS"
      ;;
    *)
      re_die "invalid CLOUD_PROVIDER '$CLOUD_PROVIDER' (expected azure, aws or gcp)"
      ;;
  esac

  re_log "TF_VAR_* exported for $CLOUD_PROVIDER: $(env | grep -c '^TF_VAR_') variables"
}

# ============================================================================
# Cloud account selection
# ============================================================================
# Selecting the wrong identity is easy when several accounts are credentialed,
# and the failure mode is confusing (a wall of 403s that looks like a broken
# project). So we pin the account for the duration of the script.
#
# IMPORTANT: we export CLOUDSDK_CORE_ACCOUNT / AWS_PROFILE for THIS PROCESS
# ONLY. We never run `gcloud config set account`, which would silently change
# the user's global state in every other terminal.

# re_gcp_select_account — pin the gcloud account for this run.
# Order: config.sh GCP_ACCOUNT -> service account matching the project ->
#        probe each credentialed account and take the first that sees the project.
re_gcp_select_account() {
  command -v gcloud >/dev/null 2>&1 || return 0

  local accounts active
  accounts=$(gcloud auth list --format='value(account)' 2>/dev/null)
  active=$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -1)

  if [ -z "$accounts" ]; then
    re_die "no credentialed gcloud account — run: gcloud auth login"
  fi

  # 1. Explicit wins.
  if [ -n "${GCP_ACCOUNT:-}" ]; then
    if ! printf '%s\n' "$accounts" | grep -qxF "$GCP_ACCOUNT"; then
      re_warn "config.sh GCP_ACCOUNT='$GCP_ACCOUNT' is not credentialed. Available:"
      printf '%s\n' "$accounts" | sed 's/^/       /' >&2
      re_die "run: gcloud auth login $GCP_ACCOUNT"
    fi
    export CLOUDSDK_CORE_ACCOUNT="$GCP_ACCOUNT"
    if [ "$GCP_ACCOUNT" != "$active" ]; then
      re_log "🔀 using gcloud account '$GCP_ACCOUNT' (config.sh) instead of the"
      re_log "   globally active '$active' — this run only, your gcloud config is untouched."
    else
      re_log "✅ gcloud account: $GCP_ACCOUNT"
    fi
    return 0
  fi

  # 2. A service account named after the project is unambiguous.
  local sa
  sa=$(printf '%s\n' "$accounts" | grep -F "@${GCP_PROJECT_ID}.iam.gserviceaccount.com" | head -1)
  if [ -n "$sa" ]; then
    export CLOUDSDK_CORE_ACCOUNT="$sa"
    re_log "🔀 auto-selected service account '$sa' (matches project $GCP_PROJECT_ID)"
    return 0
  fi

  # 3. Probe: which credentialed account can actually see this project?
  #    Try the active one first so we do not switch needlessly.
  local candidate ordered
  ordered=$(printf '%s\n%s\n' "$active" "$accounts" | awk 'NF && !seen[$0]++')
  for candidate in $ordered; do
    if gcloud container clusters list --project "$GCP_PROJECT_ID" \
         --account "$candidate" >/dev/null 2>&1; then
      export CLOUDSDK_CORE_ACCOUNT="$candidate"
      if [ "$candidate" = "$active" ]; then
        re_log "✅ gcloud account: $candidate (verified against $GCP_PROJECT_ID)"
      else
        re_log "🔀 auto-selected '$candidate' — it can access $GCP_PROJECT_ID,"
        re_log "   the globally active '$active' cannot. This run only."
      fi
      return 0
    fi
  done

  # 4. Nothing worked. Be explicit rather than deploying as the wrong identity.
  re_warn "none of the credentialed gcloud accounts can access '$GCP_PROJECT_ID':"
  printf '%s\n' "$accounts" | sed 's/^/       /' >&2
  re_warn "Set GCP_ACCOUNT in config.sh, or grant access, or:"
  re_warn "       gcloud auth login <the-right-account>"
  re_die "cannot determine which gcloud account to use for $GCP_PROJECT_ID"
}

# re_aws_select_profile — pin AWS_PROFILE for this run, if config.sh names one.
re_aws_select_profile() {
  [ -n "${AWS_PROFILE_NAME:-}" ] || return 0
  export AWS_PROFILE="$AWS_PROFILE_NAME"
  re_log "🔀 using AWS_PROFILE='$AWS_PROFILE_NAME' (config.sh) — this run only"
}

# re_azure_select_subscription — pin the Azure subscription for this run.
re_azure_select_subscription() {
  [ -n "${AZURE_SUBSCRIPTION_ID:-}" ] || return 0
  export ARM_SUBSCRIPTION_ID="$AZURE_SUBSCRIPTION_ID"
  re_log "🔀 using Azure subscription '$AZURE_SUBSCRIPTION_ID' (config.sh)"
}

# re_cloud_select_account — dispatch on CLOUD_PROVIDER.
re_cloud_select_account() {
  case "${CLOUD_PROVIDER:-}" in
    gcp)   re_gcp_select_account ;;
    aws)   re_aws_select_profile ;;
    azure) re_azure_select_subscription ;;
  esac
}

# ============================================================================
# Kubernetes helpers
# ============================================================================

# re_yaml_dir_init — ensure yaml/ exists; optionally clear it.
# yaml/ is gitignored, so a fresh clone has no such directory and every
# `sed ... > yaml/x.yaml` would fail.
# shellcheck disable=SC2120  # the --clean argument is optional
re_yaml_dir_init() {
  mkdir -p "$YAML_DIR"
  if [ "${1:-}" = "--clean" ]; then
    rm -f "$YAML_DIR"/*.yaml 2>/dev/null || true
  fi
}

# re_render <template-name> <output-path> [EXTRA_TOKEN=value ...]
# Renders templates/<name> into <output-path>, substituting every {{TOKEN}}.
#
# Tokens are DELIMITED on purpose. The old bare tokens (CLUSTER, DNS_ZONE...)
# were prefix-collision hazards: `s/CLUSTER/x/g` also rewrote CLUSTER1, and
# `s/REC_NAME/x/g` would corrupt REC_NAME_1. With {{...}} the substitution
# order no longer matters (docs/adr/0003).
#
# Values come from config.sh; per-cluster ones are passed as KEY=value.
re_render() {
  local tpl="$1" out="$2"; shift 2
  local src="$TEMPLATES_DIR/$tpl"
  [ -r "$src" ] || re_die "template not found: $src"
  re_yaml_dir_init

  # Global tokens, straight from config.sh.
  local -a sed_args=()
  local k v
  for k in DNS_ZONE NAMESPACE AA_DB_NAME AA_DB_MEMORY AA_DB_SHARDS \
           RE_NODES RE_CPU RE_MEMORY; do
    case "$k" in
      NAMESPACE) v="$NS" ;;
      *)         v="${!k:-}" ;;
    esac
    [ -n "$v" ] || re_die "config.sh: $k is required by $tpl but empty"
    sed_args+=(-e "s|{{$k}}|$v|g")
  done

  # Per-call tokens (REC_NAME, REC_NAME_1/2, B64_*).
  local pair
  for pair in "$@"; do
    k="${pair%%=*}"; v="${pair#*=}"
    sed_args+=(-e "s|{{$k}}|$v|g")
  done

  sed "${sed_args[@]}" "$src" > "$out" || re_die "failed to render $tpl"

  # Refuse to hand a half-substituted manifest to kubectl.
  local left
  left=$(grep -oE '\{\{[A-Z0-9_]+\}\}' "$out" | sort -u | tr '\n' ' ')
  if [ -n "$left" ]; then
    re_die "$tpl rendered with unsubstituted tokens: $left"
  fi
}

# re_ns_ensure <context> <namespace> — create a namespace idempotently.
# `kubectl create ns` fails if it already exists, which is fatal under `set -e`.
re_ns_ensure() {
  local ctx="$1" ns="$2"
  kubectl --context="$ctx" create namespace "$ns" \
    --dry-run=client -o yaml | kubectl --context="$ctx" apply -f - >/dev/null
  re_log "namespace $ns present on $ctx"
}

# ============================================================================
# Kubernetes teardown — ordered, bounded, and self-unblocking
# ============================================================================
# Learned the hard way on 2026-09-07: a naive `kubectl delete ns rec` hangs
# FOREVER. Three things conspire:
#   1. REAADB/RERC/REC carry finalizers only the Redis Enterprise operator can
#      clear — but the operator lives in that same namespace and is deleted at
#      the same time. Deadlock.
#   2. The ValidatingWebhookConfiguration survives its own backend pod, so any
#      later patch on those CRs is REJECTED ("no endpoints available for
#      service admission") — including the patch that would remove the
#      finalizers.
#   3. PVCs must be deleted BEFORE the cluster, or their GCP persistent disks
#      are orphaned and keep costing money (6 x 80 GB in the incident).
#
# So the order is: webhook -> CRs (operator still alive) -> PVCs -> helm/LB ->
# namespaces, each with a timeout, escalating to finalizer removal only when
# the graceful path times out.

# re_k8s_strip_finalizers <ctx> <ns> <kind>
re_k8s_strip_finalizers() {
  local ctx="$1" ns="$2" kind="$3" obj
  for obj in $(kubectl --context="$ctx" -n "$ns" get "$kind" -o name 2>/dev/null); do
    re_warn "  removing finalizers from $obj (graceful delete timed out)"
    kubectl --context="$ctx" -n "$ns" patch "$obj" --type=merge \
      -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
  done
}

# re_k8s_delete_kind <ctx> <ns> <kind> <timeout-seconds>
# Graceful delete first; strip finalizers only if it does not finish in time.
re_k8s_delete_kind() {
  local ctx="$1" ns="$2" kind="$3" tmo="${4:-60}"
  kubectl --context="$ctx" -n "$ns" get "$kind" >/dev/null 2>&1 || return 0
  local n
  n=$(kubectl --context="$ctx" -n "$ns" get "$kind" -o name 2>/dev/null | grep -c . || true)
  [ "${n:-0}" -gt 0 ] || return 0

  re_log "  deleting $n $kind (timeout ${tmo}s)"
  if kubectl --context="$ctx" -n "$ns" delete "$kind" --all \
       --timeout="${tmo}s" --ignore-not-found >/dev/null 2>&1; then
    return 0
  fi
  re_k8s_strip_finalizers "$ctx" "$ns" "$kind"
  kubectl --context="$ctx" -n "$ns" delete "$kind" --all \
    --timeout=30s --ignore-not-found >/dev/null 2>&1 || true
}

# re_k8s_teardown <ctx> — release everything the cloud would otherwise keep
# billing, in an order that cannot deadlock.
re_k8s_teardown() {
  local ctx="$1"

  if ! kubectl --context="$ctx" version >/dev/null 2>&1; then
    re_warn "$ctx: unreachable — skipping Kubernetes cleanup"
    return 0
  fi
  re_log "🧹 $ctx"

  # 1. The Redis admission webhook, TARGETED. Never `--all`: that would also
  #    delete GKE's own system webhooks (flowcontrol, warden, gmp-operator).
  kubectl --context="$ctx" delete validatingwebhookconfiguration \
    redis-enterprise-admission --ignore-not-found >/dev/null 2>&1 || true

  # 2. Redis Enterprise objects, most-dependent first, while the operator is
  #    still running so it can clean up properly.
  re_k8s_delete_kind "$ctx" "$NS" reaadb 120
  re_k8s_delete_kind "$ctx" "$NS" redb   60
  re_k8s_delete_kind "$ctx" "$NS" rerc   60
  re_k8s_delete_kind "$ctx" "$NS" rec    180

  # 3. PVCs — this is what releases the GCP persistent disks.
  re_k8s_delete_kind "$ctx" "$NS" pvc 90

  # 4. The ingress LoadBalancer, which Terraform does NOT own: leaving it
  #    behind orphans a GCP forwarding rule and its public IP.
  helm uninstall haproxy-ingress -n ingress-controller \
    --kube-context="$ctx" --timeout 2m >/dev/null 2>&1 || true

  # 5. Namespaces, bounded. Escalate to the namespace finalizer if needed.
  local ns
  for ns in "$NS" ingress-controller; do
    kubectl --context="$ctx" get ns "$ns" >/dev/null 2>&1 || continue
    re_log "  deleting namespace $ns"
    if ! kubectl --context="$ctx" delete ns "$ns" --timeout=120s >/dev/null 2>&1; then
      re_warn "  namespace $ns still terminating — clearing its finalizers"
      kubectl --context="$ctx" get ns "$ns" -o json 2>/dev/null \
        | jq 'del(.spec.finalizers)' \
        | kubectl --context="$ctx" replace --raw "/api/v1/namespaces/$ns/finalize" -f - \
          >/dev/null 2>&1 || true
    fi
  done
}

# re_kube_credentials — load kubeconfig contexts for the selected provider.
# Delegates to providers/<cloud>/get-credentials.sh (single source of truth).
re_kube_credentials() {
  local script="$REPO_ROOT/providers/$CLOUD_PROVIDER/get-credentials.sh"
  [ -x "$script" ] || [ -f "$script" ] || re_die "missing $script"
  re_log "🔑 Loading kubectl credentials for $CLOUD_PROVIDER"
  bash "$script" || re_die "get-credentials.sh failed for $CLOUD_PROVIDER"
}

# re_dns_lib — source the DNS module for the selected provider.
# Provides create_dns_record / delete_dns_record with a per-cloud signature;
# use re_dns_upsert / re_dns_delete below to stay provider-agnostic.
re_dns_lib() {
  local lib="$REPO_ROOT/common/dns-$CLOUD_PROVIDER.sh"
  if [ -f "$lib" ]; then
    # shellcheck source=/dev/null
    . "$lib"
  elif [ "$CLOUD_PROVIDER" != "azure" ]; then
    re_die "missing DNS module: $lib"
  fi
}

# re_dns_upsert <record_name> <address> — create/replace a wildcard record.
# Normalises the differing per-cloud signatures and the IP-vs-hostname split
# (AWS ELBs publish a hostname, so an A record is wrong there).
re_dns_upsert() {
  local record="$1" address="$2" ttl="${3:-60}"
  case "$CLOUD_PROVIDER" in
    azure)
      re_run az network dns record-set a delete \
        -g "$DNS_RESOURCE_GROUP" -z "$DNS_ZONE" -n "$record" -y >/dev/null 2>&1 || true
      re_run az network dns record-set a add-record \
        -g "$DNS_RESOURCE_GROUP" -z "$DNS_ZONE" -n "$record" -a "$address" --ttl "$ttl"
      ;;
    aws)
      # AWS ELBs publish a HOSTNAME, but common/dns-aws.sh only creates A
      # records (it takes an ip_address). Fail loudly rather than writing a
      # broken record. See docs/TODO.md A8.
      case "$address" in
        *[a-zA-Z]*)
          re_die "AWS: ingress published a hostname ('$address'), but common/dns-aws.sh only creates A records. Needs CNAME/alias support — docs/TODO.md A8."
          ;;
      esac
      re_run create_dns_record "$DNS_ZONE" "$record" "$address" "$ttl"
      ;;
    gcp)   re_run create_dns_record "$DNS_ZONE" "$GCP_PROJECT_ID" "$record" "$address" "$ttl" ;;
    *)     re_die "re_dns_upsert: unsupported provider $CLOUD_PROVIDER" ;;
  esac
}

# re_ingress_address <context> <namespace> <service> — echo the LoadBalancer
# address, whether the cloud publishes an .ip (Azure/GCP) or a .hostname (AWS).
re_ingress_address() {
  local ctx="$1" ns="$2" svc="$3"
  kubectl --context="$ctx" get svc -n "$ns" "$svc" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null
}

# Print the exported TF_VAR_* set (without secrets) — useful for debugging.
re_dump_tf_vars() {
  env | grep '^TF_VAR_' | grep -v 'subscription_id' | sort | sed 's/^/    /'
}
