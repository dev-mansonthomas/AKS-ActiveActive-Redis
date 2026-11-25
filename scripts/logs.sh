#!/usr/bin/env bash
# ============================================================================
# logs.sh — browse the deployment/run logs in debug/
# ============================================================================
# Every script that deploys or inspects writes a timestamped log to debug/
# (via re_log_init in common/lib.sh). This is the front door to them.
#
# Usage:
#   ./scripts/logs.sh                 # list all runs, newest first
#   ./scripts/logs.sh last            # show the most recent log
#   ./scripts/logs.sh last 01-create-cluster
#   ./scripts/logs.sh tail            # follow the most recent log
#   ./scripts/logs.sh errors          # errors/warnings across all logs
#   ./scripts/logs.sh bundles         # list collected diagnostic bundles
#   ./scripts/logs.sh clean [days]    # delete logs older than N days (default 7)
#
# Read-only apart from `clean`. Safe to run in the VM (touches no cloud).
# ============================================================================

set -uo pipefail

_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/lib.sh"
if [ ! -r "$_LIB" ]; then
  echo "FATAL: cannot read $_LIB" >&2
  exit 1
fi
# shellcheck source=../common/lib.sh
. "$_LIB" || { echo "FATAL: failed to load $_LIB" >&2; exit 1; }

mkdir -p "$DEBUG_DIR"
CMD="${1:-list}"

_logs() { find "$DEBUG_DIR" -maxdepth 1 -name '*.log' -type f 2>/dev/null | sort -r; }

case "$CMD" in
  list|"")
    printf '%-34s %8s  %s\n' "LOG" "SIZE" "LAST MODIFIED"
    printf '%-34s %8s  %s\n' "----------------------------------" "--------" "-------------------"
    found=0
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      found=1
      printf '%-34s %8s  %s\n' "$(basename "$f")" \
        "$(du -h "$f" | cut -f1)" "$(re_file_mtime "$f")"
    done < <(_logs)
    if [ "$found" -eq 0 ]; then
      echo "(no logs yet — run a deployment script first)"
    fi
    ;;

  last|show)
    name="${2:-}"
    if [ -n "$name" ]; then
      f=$(_logs | grep -m1 "/$name-" || true)
    else
      f=$(_logs | head -1)
    fi
    [ -n "$f" ] || { echo "no matching log${name:+ for '$name'}" >&2; exit 1; }
    echo "── $f"
    cat "$f"
    ;;

  tail|follow)
    f=$(_logs | head -1)
    [ -n "$f" ] || { echo "no logs yet" >&2; exit 1; }
    echo "── following $(basename "$f") (Ctrl-C to stop)"
    tail -f "$f"
    ;;

  errors|err)
    found=0
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      hits=$(grep -nE '❌|⚠️|Error:|error:|FAILED|failed|exit [1-9]' "$f" 2>/dev/null || true)
      if [ -n "$hits" ]; then
        found=1
        echo "══ $(basename "$f")"
        echo "$hits" | sed 's/^/   /'
        echo
      fi
    done < <(_logs)
    if [ "$found" -eq 0 ]; then
      echo "✅ no errors or warnings in any log"
    fi
    ;;

  bundles)
    printf '%-30s %6s  %s\n' "BUNDLE" "FILES" "COLLECTED"
    found=0
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      found=1
      printf '%-30s %6s  %s\n' "$(basename "$d")" \
        "$(find "$d" -type f | wc -l | tr -d ' ')" "$(re_file_mtime "$d")"
    done < <(find "$DEBUG_DIR" -maxdepth 1 -type d -name 'diag-*' 2>/dev/null | sort -r)
    if [ "$found" -eq 0 ]; then
      echo "(none — run ./scripts/get-logs.sh)"
    fi
    ;;

  clean)
    days="${2:-7}"
    n=$(find "$DEBUG_DIR" -maxdepth 1 \( -name '*.log' -o -name 'diag-*' \) -mtime "+$days" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$n" -eq 0 ]; then
      echo "nothing older than $days day(s)"
    else
      find "$DEBUG_DIR" -maxdepth 1 \( -name '*.log' -o -name 'diag-*' \) -mtime "+$days" -exec rm -rf {} +
      echo "🧹 removed $n item(s) older than $days day(s)"
    fi
    ;;

  -h|--help|help) sed -n '2,20p' "$0" ;;
  *) echo "unknown command: $CMD (try --help)" >&2; exit 2 ;;
esac

exit 0
