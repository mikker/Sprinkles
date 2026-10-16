#!/usr/bin/env bash
# Runs xcodebuild with build/dd as derived data and keeps the full log under build/xcodebuild/.
# Usage: scripts/agent-build.sh <xcodebuild args...>
set -eo pipefail

if [ $# -eq 0 ]; then
  echo "usage: $(basename "$0") <xcodebuild args...>" >&2
  exit 64
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$repo_root/build"
derived_data="$build_dir/dd"
log_dir="$build_dir/xcodebuild"
mkdir -p "$log_dir"

timestamp="$(date +%Y-%m-%d-%H-%M-%S)"
action="$1"
safe_action="$(printf '%s' "$action" | tr -c '[:alnum:]-' '_')"
log_stub="$(mktemp "$log_dir/xcodebuild-${safe_action}-${timestamp}.XXXXXX")"
log_file="$log_stub.log"
mv "$log_stub" "$log_file"

set +e
if command -v xcsift >/dev/null 2>&1; then
  xcsift_args=(--format toon)
  [ "$action" != "test" ] && xcsift_args+=(--quiet)
  xcodebuild -derivedDataPath "$derived_data" "$@" 2>&1 | tee "$log_file" | xcsift "${xcsift_args[@]}"
  pipe_status=("${PIPESTATUS[@]}")
  exit_code="${pipe_status[0]}"
else
  xcodebuild -derivedDataPath "$derived_data" "$@" &> "$log_file"
  exit_code=$?
  if [ "$exit_code" -ne 0 ]; then
    grep -E "error:|\*\* .* FAILED|Testing failed|failed \(" "$log_file" | sed 's/^/  /' | tail -n 20
  else
    grep -E "Executed [0-9]+ tests|\*\* .* SUCCEEDED" "$log_file" | tail -n 2 | sed 's/^/  /'
  fi
fi
set -e

echo "xcodebuild output saved to: $log_file"
if [ "$exit_code" -eq 0 ]; then
  echo "Status: SUCCESS"
else
  echo "Status: FAILED (exit code: $exit_code)"
  echo "Tip: tail -n 40 $log_file"
fi
exit "$exit_code"
