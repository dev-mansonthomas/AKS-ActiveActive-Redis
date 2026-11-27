#!/usr/bin/env bash
# Root wrapper -> scripts/create-all.sh  (works from any directory)
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/create-all.sh" "$@"
