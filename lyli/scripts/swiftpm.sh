#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [ "$#" -lt 1 ]; then
  echo "usage: scripts/swiftpm.sh <build|run|test> [arguments...]" >&2
  exit 2
fi

command="$1"
shift

cache_base="${LYLI_SPM_SCRATCH_PATH:-$PWD/.build}/lyli-tool-cache"
cache_path="${LYLI_SPM_CACHE_PATH:-$cache_base/cache}"
config_path="${LYLI_SPM_CONFIG_PATH:-$cache_base/config}"
security_path="${LYLI_SPM_SECURITY_PATH:-$cache_base/security}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$cache_base/clang}"
mkdir -p "$cache_path" "$config_path" "$security_path" "$CLANG_MODULE_CACHE_PATH"

args=(--disable-sandbox --cache-path "$cache_path" --config-path "$config_path" --security-path "$security_path")
if [ -n "${LYLI_SPM_SCRATCH_PATH:-}" ]; then
  args+=(--scratch-path "$LYLI_SPM_SCRATCH_PATH")
fi

exec swift "$command" "${args[@]}" "$@"
