#!/usr/bin/env bash
# Root wrapper -> scripts/delete-all-resources.sh  (works from any directory)
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/delete-all-resources.sh" "$@"
