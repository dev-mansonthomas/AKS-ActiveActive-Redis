#!/usr/bin/env bash
# shellcheck shell=bash
# ============================================================================
# chaos_notify — tell the chaos web console what chaos.sh is doing.
# ============================================================================
# Best effort by design: the console is a display, so a missing, slow or
# misbehaving console must never fail or delay a chaos run. Every call returns 0
# within ~2 s; only the FIRST failure writes one line.
#
#   . common/chaos-notify.sh
#   CHAOS_RUN_ID=20261126-171505
#   chaos_notify run_start target=rec-a witness=rec-b
#   chaos_notify phase_start phase=node
#   chaos_notify inject phase=node note="gcloud compute instances reset ..."
#   chaos_notify step phase=node name=node-recovery status=PASS seconds=61
#   chaos_notify run_end status=PASS
#
# Keys sent: phase target witness name status seconds note. Contract and limits:
# docs/specs/chaos-webui.md (run_id charset/length, note clipped to 200 chars).
# Environment: CHAOS_WEBUI_PORT (5050), CHAOS_RUN_ID (required).
# ============================================================================

_CN_WARNED=0

_cn_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  # any other control character is not valid inside a JSON string
  printf '%s' "$s" | LC_ALL=C tr -d '\000-\010\013\014\016-\037'
}

_cn_warn_once() {
  [ "$_CN_WARNED" -eq 0 ] || return 0
  _CN_WARNED=1
  echo "[chaos console] not reachable on port ${CHAOS_WEBUI_PORT:-5050} — events are skipped (start it with ./chaos-webui-start.sh)"
}

# chaos_notify <type> [key=value ...]
chaos_notify() {
  local type="$1"; shift
  [ -n "${CHAOS_RUN_ID:-}" ] || return 0
  # Optional hook: the caller can keep its own record of every event (chaos.sh writes
  # the audit file with it). Never allowed to fail the notification.
  if declare -F chaos_notify_hook >/dev/null 2>&1; then chaos_notify_hook "$type" "$@" || true; fi
  local body kv key val
  body="{\"type\":\"$(_cn_json_escape "$type")\",\"run_id\":\"$(_cn_json_escape "$CHAOS_RUN_ID")\""
  for kv in "$@"; do
    key="${kv%%=*}"; val="${kv#*=}"
    case "$key" in
      phase|target|witness|name|status|note) body+=",\"$key\":\"$(_cn_json_escape "$val")\"" ;;
      seconds) case "$val" in
                 ''|*[!0-9.]*|*.*.*) : ;;                  # not a plain number: leave it out
                 *) body+=",\"seconds\":$val" ;;
               esac ;;
    esac
  done
  body+="}"
  local code
  code=$(curl -s -m 2 -o /dev/null -w '%{http_code}' -X POST \
           -H 'Content-Type: application/json' -d "$body" \
           "http://127.0.0.1:${CHAOS_WEBUI_PORT:-5050}/api/chaos/event" 2>/dev/null) || code=""
  [ "$code" = "204" ] || _cn_warn_once
  return 0
}
