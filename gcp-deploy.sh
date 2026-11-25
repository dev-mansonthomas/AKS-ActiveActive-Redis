#!/usr/bin/env bash
# ============================================================================
# gcp-deploy.sh — deploy (or tear down) the demo on GCP / GKE
# ============================================================================
# THE single entry point for GCP. Runs on the HOST: it needs gcloud credentials,
# which by design do not exist inside the VM.
#
#   ./gcp-deploy.sh --plan-only   # preflight + tofu plan, changes nothing
#   ./gcp-deploy.sh               # build the demo
#   ./gcp-deploy.sh --destroy     # remove everything
#
# All configuration comes from config.sh. Logs to debug/.
# ============================================================================

set -uo pipefail

# shellcheck disable=SC2034  # consumed by common-deploy.sh
DEPLOY_CLOUD="gcp"

# shellcheck source=common/deploy-lib.sh
_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common/deploy-lib.sh"
if [ ! -r "$_LIB" ]; then
  echo "FATAL: cannot read $_LIB" >&2
  exit 1
fi
# shellcheck source=common/deploy-lib.sh
. "$_LIB" || { echo "FATAL: failed to load $_LIB" >&2; exit 1; }

# ============================================================================
# GCP-specific preflight
# ============================================================================
# ============================================================================
# GCP-specific preflight
# ============================================================================
# Design rule: THE PREFLIGHT MUST NOT BE MORE PRIVILEGED THAN THE DEPLOY.
# Most of the checks below use introspection APIs (resourcemanager, serviceusage,
# compute.regions) that a principal with full deploy rights on a project often
# does NOT have. So we distinguish three outcomes:
#
#   verified OK        -> ✅  (proven good)
#   cannot verify      -> ⚠️   (permission denied / API disabled — NOT blocking)
#   verified bad       -> ❌  (the query worked and the answer is wrong — blocking)
#
# Only "verified bad" and missing credentials block. Everything else is a
# warning, because `tofu plan` is the authoritative test.
# ============================================================================

cloud_preflight() {
  local fail=0 unverified=0
  _AUTH_BROKEN=0

  if ! command -v gcloud >/dev/null 2>&1; then
    re_warn "  ❌ gcloud not found — https://cloud.google.com/sdk/docs/install"
    return 1
  fi
  re_log "  ✅ gcloud $(gcloud version 2>/dev/null | head -1 | awk '{print $NF}')"

  # ---- Credentials: these DO block. Nothing works without them. -----------
  local account
  account=$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -1)
  if [ -z "$account" ]; then
    re_warn "  ❌ no active gcloud account — run: gcloud auth login"
    fail=$((fail + 1))
  else
    re_log "  ✅ gcloud credentialed accounts present (active: $account)"
  fi

  if gcloud auth application-default print-access-token >/dev/null 2>&1; then
    re_log "  ✅ application-default credentials present (this is what OpenTofu uses)"
  else
    re_warn "  ❌ no ADC — run: gcloud auth application-default login"
    re_warn "     ('gcloud auth login' alone is NOT enough for the OpenTofu provider)"
    fail=$((fail + 1))
  fi

  # Pin the right account BEFORE any introspection, otherwise every check below
  # tests the wrong identity and reports misleading 403s.
  re_gcp_select_account

  # Probe the CLI credential itself, once and cheaply. If it cannot refresh,
  # every subsequent query fails identically and reports a misleading reason
  # ("no permission" when the truth is "expired token"), so stop right here.
  cloud_q gcloud auth print-access-token ${CLOUDSDK_CORE_ACCOUNT:+--account="$CLOUDSDK_CORE_ACCOUNT"}
  if [ "$_Q_RC" -ne 0 ] && cloud_is_auth_error "$_Q_ERR"; then
    re_warn "  🔑 THE gcloud CLI CREDENTIAL IS EXPIRED — fix this first."
    re_warn ""
    re_warn "     $_Q_ERR"
    re_warn ""
    re_warn "     Note this is NOT a permissions or project problem. Your"
    re_warn "     application-default credentials are separate and still valid,"
    re_warn "     so 'tofu plan' works — but the deploy also needs the gcloud CLI"
    re_warn "     for kubeconfig (providers/gcp/get-credentials.sh) and DNS records"
    re_warn "     (common/dns-gcp.sh), so it would fail at step 02."
    re_warn ""
    re_warn "         gcloud auth login"
    re_warn ""
    re_warn "     Then re-run: ./gcp-deploy.sh --plan-only"
    return $((fail + 1))
  fi
  re_log "  ✅ gcloud CLI token refreshes"

  # GOOGLE_APPLICATION_CREDENTIALS overrides the ADC well-known file and wins
  # for every client library, including the OpenTofu google provider. If it is
  # set, THAT is the identity which will deploy — not the gcloud CLI account,
  # and not whatever `gcloud auth application-default login` writes. Surface it
  # explicitly: this is the single most confusing thing about GCP auth.
  if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then
    re_log "  ℹ️  GOOGLE_APPLICATION_CREDENTIALS is set — it OVERRIDES ADC:"
    re_log "     $GOOGLE_APPLICATION_CREDENTIALS"
    if [ ! -r "$GOOGLE_APPLICATION_CREDENTIALS" ]; then
      re_warn "  ❌ that file is not readable — OpenTofu will fail to authenticate"
      fail=$((fail + 1))
    else
      local gac_email gac_project gac_type
      gac_email=$(jq -r '.client_email // empty' "$GOOGLE_APPLICATION_CREDENTIALS" 2>/dev/null)
      gac_project=$(jq -r '.project_id // empty' "$GOOGLE_APPLICATION_CREDENTIALS" 2>/dev/null)
      gac_type=$(jq -r '.type // empty' "$GOOGLE_APPLICATION_CREDENTIALS" 2>/dev/null)
      re_log "     type=${gac_type:-unknown} identity=${gac_email:-unknown}"
      if [ -n "$gac_project" ] && [ "$gac_project" != "$GCP_PROJECT_ID" ]; then
        re_warn "  ❌ that key belongs to project '$gac_project' but config.sh"
        re_warn "     says '$GCP_PROJECT_ID'. OpenTofu would deploy to the wrong project."
        fail=$((fail + 1))
      elif [ -n "$gac_project" ]; then
        re_log "  ✅ key project matches config.sh ($gac_project)"
      fi
      # The CLI account and this SA are different identities. Recommend aligning
      # them so DNS and kubeconfig operations use the same rights as the deploy.
      if [ -n "$gac_email" ] && [ "${CLOUDSDK_CORE_ACCOUNT:-}" != "$gac_email" ]; then
        re_log "  ℹ️  OpenTofu will deploy as   : $gac_email"
        re_log "     gcloud CLI will act as     : ${CLOUDSDK_CORE_ACCOUNT:-<active account>}"
        re_log "     Two different identities. That is fine only if BOTH can do their job:"
        re_log "     OpenTofu creates the clusters; the CLI writes DNS records and"
        re_log "     fetches kubeconfig. To use one identity for everything:"
        re_log "         gcloud auth activate-service-account --key-file=\"$GOOGLE_APPLICATION_CREDENTIALS\""
        re_log "         # then in config.sh:  GCP_ACCOUNT=$gac_email"
      fi
    fi
  fi

  # ADC is a SEPARATE credential from the CLI account. Switching the CLI
  # account does not switch ADC, and OpenTofu only ever uses ADC (or
  # GOOGLE_APPLICATION_CREDENTIALS above) — so a mismatch here silently
  # deploys as a different identity.
  cloud_q gcloud auth application-default print-access-token
  if [ "$_Q_RC" -eq 0 ]; then
    local adc_probe
    adc_probe=$(curl -sS -m 10 \
      -H "Authorization: Bearer $_Q_OUT" \
      "https://cloudresourcemanager.googleapis.com/v1/projects/$GCP_PROJECT_ID" 2>/dev/null)
    if printf '%s' "$adc_probe" | grep -q '"projectId"'; then
      re_log "  ✅ ADC can reach $GCP_PROJECT_ID (this is what OpenTofu will use)"
    elif printf '%s' "$adc_probe" | grep -qE 'PERMISSION_DENIED|"code": *403'; then
      re_warn "  ADC reached Google but was denied on '$GCP_PROJECT_ID'."
      re_warn "     ADC is a SEPARATE credential from the gcloud CLI account —"
      re_warn "     switching the CLI account does NOT switch it, and OpenTofu"
      re_warn "     uses ADC only. Align it with:"
      re_warn "         gcloud auth application-default login --account=${GCP_ACCOUNT:-<the-right-account>}"
      re_warn "     Not blocking: 'tofu plan' is the authoritative test."
      unverified=$((unverified + 1))
    else
      re_warn "  could not confirm which identity ADC uses (resourcemanager API"
      re_warn "     may be disabled). Not blocking — 'tofu plan' will tell us."
      unverified=$((unverified + 1))
    fi
  fi

  # Warn when the CLI's active project disagrees with config.sh — a very common
  # cause of confusing results.
  local cli_project
  cli_project=$(gcloud config get-value project 2>/dev/null)
  if [ -n "$cli_project" ] && [ "$cli_project" != "(unset)" ] && [ "$cli_project" != "$GCP_PROJECT_ID" ]; then
    re_warn "  gcloud's active project is '$cli_project' but config.sh says '$GCP_PROJECT_ID'"
    re_warn "     (not blocking — we always pass --project/TF_VAR_project_id explicitly)"
  fi

  # ---- Everything below is best-effort introspection ----------------------
  cloud_q gcloud projects describe "$GCP_PROJECT_ID" --format=value\(projectId\)
  if [ "$_Q_RC" -eq 0 ]; then
    re_log "  ✅ project $GCP_PROJECT_ID accessible"
  elif cloud_is_auth_error "$_Q_ERR"; then
    _AUTH_BROKEN=1
  elif cloud_is_permission_error "$_Q_ERR"; then
    re_warn "  cannot read project metadata (no resourcemanager.projects.get)."
    re_warn "     Not blocking: deploying does not require it. Detail: $_Q_ERR"
    unverified=$((unverified + 1))
  else
    re_warn "  ❌ project '$GCP_PROJECT_ID' does not exist or is unreachable: $_Q_ERR"
    fail=$((fail + 1))
  fi

  # Required APIs — needs serviceusage.services.list, often denied.
  cloud_q gcloud services list --enabled --project "$GCP_PROJECT_ID" --format=value\(config.name\)
  if [ "$_Q_RC" -ne 0 ]; then
    re_warn "  cannot list enabled APIs (no serviceusage.services.list)."
    re_warn "     Ensure these are on: container, compute, dns. Detail: $_Q_ERR"
    unverified=$((unverified + 1))
  else
    local api
    for api in container.googleapis.com compute.googleapis.com dns.googleapis.com; do
      if printf '%s\n' "$_Q_OUT" | grep -qx "$api"; then
        re_log "  ✅ API $api enabled"
      else
        re_warn "  ❌ API $api NOT enabled — run:"
        re_warn "     gcloud services enable $api --project $GCP_PROJECT_ID"
        fail=$((fail + 1))
      fi
    done

    # Cloud Asset Inventory is OPTIONAL: it is the only sweep that finds
    # resources independently of our naming convention, which matters because
    # GCP cannot label networks/subnets/firewalls/node-pools (ADR 0006).
    # Never blocking — offer to enable it, and carry on either way.
    if printf '%s\n' "$_Q_OUT" | grep -qx "cloudasset.googleapis.com"; then
      re_log "  ✅ API cloudasset.googleapis.com enabled (label-wide audit available)"
    else
      re_log "  ℹ️  API cloudasset.googleapis.com is NOT enabled (optional)."
      re_log "     It powers the only audit sweep that does not rely on our"
      re_log "     naming convention — useful on a shared project, since GCP"
      re_log "     cannot label networks, subnets, firewalls or node pools."
      if [ -t 0 ]; then
        printf '     Enable it now? [y/N] '
        local answer=""
        read -r answer
        case "$answer" in
          [yY]|[yY][eE][sS])
            if re_run gcloud services enable cloudasset.googleapis.com \
                 --project "$GCP_PROJECT_ID"; then
              re_log "  ✅ cloudasset.googleapis.com enabled"
            else
              re_warn "  could not enable it (needs serviceusage.services.enable)."
              re_warn "     Ask a project admin, or run it yourself:"
              re_warn "       gcloud services enable cloudasset.googleapis.com --project $GCP_PROJECT_ID"
            fi
            ;;
          *) re_log "     skipped — ./check-tags.sh will audit by name prefix only" ;;
        esac
      else
        re_log "     Not a terminal, so not asking. To enable it later:"
        re_log "       gcloud services enable cloudasset.googleapis.com --project $GCP_PROJECT_ID"
      fi
    fi
  fi

  # Regions + machine type availability.
  local region zone
  for region in "$GCP_REGION1" "$GCP_REGION2"; do
    # Machine types are zonal. Listing them all and filtering client-side takes
    # ~30s per region; describing one in a single zone of that region is ~1s.
    cloud_q gcloud compute zones list --project "$GCP_PROJECT_ID" \
      --filter="region~/$region\$" --limit=1 --format=value\(name\)
    zone="$_Q_OUT"
    if [ -z "$zone" ]; then
      re_warn "  cannot list zones of '$region'. Detail: $_Q_ERR"
      unverified=$((unverified + 1))
      continue
    fi
    cloud_q gcloud compute machine-types describe "$GCP_INSTANCE_TYPE" \
      --zone "$zone" --project "$GCP_PROJECT_ID" --format=value\(name\)
    if [ "$_Q_RC" -ne 0 ]; then
      re_warn "  cannot query machine types in $region. Detail: $_Q_ERR"
      unverified=$((unverified + 1))
    elif [ -n "$_Q_OUT" ]; then
      re_log "  ✅ $GCP_INSTANCE_TYPE available in $region (checked in $zone)"
    else
      re_warn "  ❌ machine type '$GCP_INSTANCE_TYPE' not offered in '$region' (zone $zone)"
      re_warn "     see docs/TODO.md I1 (quota/region finder)"
      fail=$((fail + 1))
    fi
  done

  # Cloud DNS managed zone — genuinely required by Active/Active, but only
  # blocking if we could actually look and it was absent.
  cloud_q gcloud dns managed-zones list --project "$GCP_PROJECT_ID" \
    --filter="dnsName=${DNS_ZONE}." --format=value\(name\)
  if [ "$_Q_RC" -ne 0 ]; then
    re_warn "  cannot list Cloud DNS zones. Detail: $_Q_ERR"
    re_warn "     A managed zone for '$DNS_ZONE' IS required — step 02 writes"
    re_warn "     '*.<cluster>.$DNS_ZONE' records and will fail without it."
    unverified=$((unverified + 1))
  elif [ -n "$_Q_OUT" ]; then
    re_log "  ✅ Cloud DNS managed zone '$_Q_OUT' for $DNS_ZONE"
  else
    re_warn "  ❌ no Cloud DNS managed zone for '$DNS_ZONE' in $GCP_PROJECT_ID"
    # Show what DOES exist — usually the zone is simply named differently.
    cloud_q gcloud dns managed-zones list --project "$GCP_PROJECT_ID" \
      --format="value(name,dnsName)"
    if [ "$_Q_RC" -eq 0 ] && [ -n "$_Q_OUT" ]; then
      re_warn "     Zones that DO exist in this project:"
      printf '%s\n' "$_Q_OUT" | sed 's/^/         /' >&2
      re_warn "     If one of these is the right zone, set GCP_DNS_ZONE in config.sh"
      re_warn "     to its dnsName (without the trailing dot)."
    else
      re_warn "     This project has no managed zone at all. Create one:"
      re_warn "     gcloud dns managed-zones create redis-demo --dns-name=${DNS_ZONE}. \\"
      re_warn "       --description='Redis AA demo' --project $GCP_PROJECT_ID"
      re_warn "     ...then delegate ${DNS_ZONE} to its name servers at your registrar."
    fi
    re_warn "     Active/Active identifies clusters by FQDN, so this is mandatory."
    fail=$((fail + 1))
  fi

  # ---- IAM permissions -----------------------------------------------------
  # testIamPermissions needs NO permission of its own: any authenticated caller
  # may ask what it can do. So we can check the exact rights the deploy needs
  # BEFORE creating anything, instead of discovering a 403 half-way through and
  # leaving a partially built demo behind.
  local want="compute.networks.create,compute.networks.delete"
  want="$want,compute.subnetworks.create,compute.subnetworks.delete"
  want="$want,compute.firewalls.create,compute.firewalls.delete"
  want="$want,container.clusters.create,container.clusters.get,container.clusters.delete"
  want="$want,dns.changes.create,dns.resourceRecordSets.create,dns.resourceRecordSets.delete"

  # gcloud has no `projects test-iam-permissions` subcommand, so call the
  # Resource Manager REST endpoint directly. It returns only the subset of the
  # requested permissions that the caller actually holds.
  local iam_tok iam_body iam_resp
  iam_tok=$(gcloud auth print-access-token 2>/dev/null)
  if [ -z "$iam_tok" ]; then
    re_warn "  cannot obtain a token to test IAM permissions"
    unverified=$((unverified + 1))
  else
    iam_body=$(printf '%s' "$want" | jq -R 'split(",") | {permissions: .}')
    iam_resp=$(curl -sS -m 20 -X POST \
      -H "Authorization: Bearer $iam_tok" \
      -H "Content-Type: application/json" \
      -d "$iam_body" \
      "https://cloudresourcemanager.googleapis.com/v1/projects/${GCP_PROJECT_ID}:testIamPermissions" 2>/dev/null)

    if printf '%s' "$iam_resp" | jq -e '.error' >/dev/null 2>&1; then
      re_warn "  cannot test IAM permissions: $(printf '%s' "$iam_resp" | jq -r '.error.message' | cut -c1-140)"
      unverified=$((unverified + 1))
    else
      local have missing perm
      have=$(printf '%s' "$iam_resp" | jq -r '.permissions[]? // empty' | tr '\n' ' ')
      missing=""
      for perm in $(printf '%s' "$want" | tr ',' ' '); do
        case " $have " in
          *" $perm "*) ;;
          *) missing="$missing $perm" ;;
        esac
      done
      if [ -n "$missing" ]; then
        re_warn "  ❌ the deploying identity is missing IAM permissions:"
        for perm in $missing; do re_warn "         $perm"; done
        re_warn ""
        re_warn "     Identity: ${CLOUDSDK_CORE_ACCOUNT:-<active account>}"
        re_warn "     Grant the roles that cover them, e.g.:"
        re_warn "       gcloud projects add-iam-policy-binding $GCP_PROJECT_ID \\"
        re_warn "         --member=serviceAccount:${CLOUDSDK_CORE_ACCOUNT:-SA} \\"
        re_warn "         --role=roles/container.admin"
        re_warn "       (also roles/compute.networkAdmin and roles/dns.admin)"
        re_warn "     IAM changes can take a couple of minutes to propagate."
        fail=$((fail + 1))
      else
        re_log "  ✅ all $(printf '%s' "$want" | tr ',' '\n' | grep -c .) required IAM permissions present"
      fi
    fi
  fi

  # ---- actAs on the node service account -----------------------------------
  # Creating a GKE cluster needs roles/container.admin AND
  # roles/iam.serviceAccountUser on the service account the NODES will use.
  # We do not set one, so GKE uses the Compute Engine default SA. Missing
  # actAs is the classic second failure right after container.admin, and it
  # only surfaces once the cluster create call is made.
  cloud_q gcloud projects describe "$GCP_PROJECT_ID" --format=value\(projectNumber\)
  local proj_num="$_Q_OUT" node_sa=""
  if [ -n "$proj_num" ]; then
    node_sa="${proj_num}-compute@developer.gserviceaccount.com"
    if [ -n "${iam_tok:-}" ]; then
      local sa_resp
      sa_resp=$(curl -sS -m 20 -X POST \
        -H "Authorization: Bearer $iam_tok" \
        -H "Content-Type: application/json" \
        -d '{"permissions":["iam.serviceAccounts.actAs"]}' \
        "https://iam.googleapis.com/v1/projects/$GCP_PROJECT_ID/serviceAccounts/$node_sa:testIamPermissions" 2>/dev/null)
      if printf '%s' "$sa_resp" | jq -e '.permissions[]? | select(. == "iam.serviceAccounts.actAs")' >/dev/null 2>&1; then
        re_log "  ✅ can actAs the node service account ($node_sa)"
      elif printf '%s' "$sa_resp" | jq -e '.error' >/dev/null 2>&1; then
        re_warn "  cannot check actAs on $node_sa: $(printf '%s' "$sa_resp" | jq -r '.error.message' | cut -c1-120)"
        unverified=$((unverified + 1))
      else
        re_warn "  ❌ missing iam.serviceAccounts.actAs on the node service account:"
        re_warn "         $node_sa"
        re_warn "     GKE cluster creation needs it in addition to container.admin:"
        re_warn "       gcloud iam service-accounts add-iam-policy-binding $node_sa \\"
        re_warn "         --member=serviceAccount:${CLOUDSDK_CORE_ACCOUNT:-SA} \\"
        re_warn "         --role=roles/iam.serviceAccountUser --project $GCP_PROJECT_ID"
        fail=$((fail + 1))
      fi
    fi
  else
    re_warn "  cannot resolve the project number, so the node service account is unknown"
    unverified=$((unverified + 1))
  fi

  # ---- Name lengths --------------------------------------------------------
  # GKE caps cluster and node-pool names at 40 characters. Names are derived
  # from CLUSTER_PREFIX + region, so a long prefix or a long region name (e.g.
  # southamerica-east1) silently overflows and apply fails after minutes.
  local longest=0 offender="" n len
  for n in "$CLUSTER1" "$CLUSTER2" "$CLUSTER1-nodes" "$CLUSTER2-nodes"; do
    len=${#n}
    if [ "$len" -gt "$longest" ]; then longest=$len; offender="$n"; fi
  done
  if [ "$longest" -gt 40 ]; then
    re_warn "  ❌ '$offender' is $longest chars; GKE caps cluster/node-pool names at 40."
    re_warn "     Shorten CLUSTER_PREFIX in config.sh (currently '$CLUSTER_PREFIX')."
    fail=$((fail + 1))
  elif [ "$longest" -gt 35 ]; then
    re_log "  ⚠️  longest derived name '$offender' is $longest/40 chars — little headroom"
  else
    re_log "  ✅ derived names fit GKE's 40-char limit (longest: $longest)"
  fi

  # ---- Name collisions -----------------------------------------------------
  # Terraform manages only what is in ITS STATE. A resource that exists in the
  # project but not in state is not adopted or updated: `apply` tries to CREATE
  # it and the API returns 409 alreadyExists, leaving a half-built deployment.
  # So when our state is empty, every name we intend to create must be free.
  local state="$REPO_ROOT/providers/gcp/terraform.tfstate"
  local in_state=0
  if [ -f "$state" ]; then
    # Count the resources array properly. Grepping for '"type"' overcounts:
    # that key also appears in outputs and elsewhere in the state JSON.
    in_state=$(jq '.resources | length' "$state" 2>/dev/null || echo 0)
    [ -n "$in_state" ] || in_state=0
  fi

  if [ "$in_state" -gt 0 ]; then
    re_log "  ✅ Terraform state holds $in_state resource(s) — it owns them, no collision check"
  else
    re_log "  Terraform state is empty; checking our names are free..."
    local taken=""

    cloud_q gcloud compute networks describe "${CLUSTER_PREFIX}-vpc" \
      --project "$GCP_PROJECT_ID" --format=value\(name\)
    [ "$_Q_RC" -eq 0 ] && [ -n "$_Q_OUT" ] && taken="$taken network/${CLUSTER_PREFIX}-vpc"

    local fw
    for fw in "${CLUSTER_PREFIX}-allow-internal" "${CLUSTER_PREFIX}-allow-redis-ports"; do
      cloud_q gcloud compute firewall-rules describe "$fw" \
        --project "$GCP_PROJECT_ID" --format=value\(name\)
      [ "$_Q_RC" -eq 0 ] && [ -n "$_Q_OUT" ] && taken="$taken firewall/$fw"
    done

    local pair cl rg
    for pair in "$CLUSTER1:$GCP_REGION1" "$CLUSTER2:$GCP_REGION2"; do
      cl="${pair%%:*}"; rg="${pair##*:}"
      cloud_q gcloud container clusters describe "$cl" --region "$rg" \
        --project "$GCP_PROJECT_ID" --format=value\(name\)
      [ "$_Q_RC" -eq 0 ] && [ -n "$_Q_OUT" ] && taken="$taken cluster/$cl"
      cloud_q gcloud compute networks subnets describe "${CLUSTER_PREFIX}-subnet-$rg" \
        --region "$rg" --project "$GCP_PROJECT_ID" --format=value\(name\)
      [ "$_Q_RC" -eq 0 ] && [ -n "$_Q_OUT" ] && taken="$taken subnet/${CLUSTER_PREFIX}-subnet-$rg"
    done

    if [ -n "$taken" ]; then
      re_warn "  ❌ these resources already exist but are NOT in our Terraform state:"
      local t
      for t in $taken; do re_warn "         $t"; done
      re_warn ""
      re_warn "     Terraform will try to CREATE them and get 409 alreadyExists."
      re_warn "     It does not adopt or update resources it did not create."
      re_warn ""
      re_warn "     Pick one:"
      re_warn "     (a) If they belong to ANOTHER deployment (e.g. your RE-on-VM"
      re_warn "         project), give this rig its own namespace — edit config.sh:"
      re_warn "             CLUSTER_PREFIX=redis-aa"
      re_warn "         Nothing is shared then, and --destroy can never touch theirs."
      re_warn "     (b) If they are leftovers from a previous run of THIS rig whose"
      re_warn "         state was lost, delete them, then re-run."
      re_warn "     (c) To deliberately take ownership, 'tofu import' each one."
      re_warn "         ⚠️  --destroy would then DELETE them. Only do this if they"
      re_warn "         really are this rig's."
      fail=$((fail + 1))
    else
      re_log "  ✅ no name collisions — all target names are free"
    fi
  fi

  re_log "  ℹ️  planned footprint: 2 clusters x $GCP_NODE_COUNT x $GCP_INSTANCE_TYPE"
  re_log "     (autoscaling $GCP_NODE_MIN_COUNT-$GCP_NODE_MAX_COUNT per pool)"

  if [ "${_AUTH_BROKEN:-0}" -eq 1 ]; then
    re_warn "  🔑 THE gcloud CLI CREDENTIAL IS EXPIRED — this is the real problem."
    re_warn ""
    re_warn "     Every gcloud query above failed while refreshing your auth token,"
    re_warn "     before any permission was even evaluated. Your project and your"
    re_warn "     OpenTofu credentials are fine — ADC is separate and still valid,"
    re_warn "     which is why 'tofu plan' works."
    re_warn ""
    re_warn "     But the deploy needs the gcloud CLI later, for kubeconfig"
    re_warn "     (providers/gcp/get-credentials.sh) and DNS records"
    re_warn "     (common/dns-gcp.sh), so it would fail at step 02. Fix it now:"
    re_warn ""
    re_warn "         gcloud auth login"
    re_warn ""
    re_warn "     Then re-run: ./gcp-deploy.sh --plan-only"
    fail=$((fail + 1))
  elif [ "$unverified" -gt 0 ]; then
    re_warn "  $unverified check(s) could not be verified (insufficient read"
    re_warn "     permissions). This does NOT block: 'tofu plan' is the real test."
    re_warn "     For the raw errors run: ./scripts/diagnose-gcp.sh"
  fi

  return "$fail"
}

deploy_parse_args "$@"
deploy_main
