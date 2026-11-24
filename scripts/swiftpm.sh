#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
build_dir="$project_dir/build"
scratch_path="$build_dir/swiftpm"
cache_path="$build_dir/swiftpm-cache"

if [[ "$#" -eq 0 || ( "$1" != "build" && "$1" != "test" ) ]]; then
    print -u2 "Usage: scripts/swiftpm.sh <build|test> [SwiftPM options]"
    exit 64
fi
swiftpm_command="$1"
shift

mkdir -p "$build_dir" "$scratch_path" "$cache_path"
temporary_dir="$(mktemp -d "$build_dir/.tmp.swiftpm.XXXXXXXX")"
cleanup() {
    local exit_code=$?
    trap - EXIT
    if [[ -n "$temporary_dir" && -d "$temporary_dir" ]]; then
        rm -rf -- "$temporary_dir" || exit_code=$?
    fi
    exit "$exit_code"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Reuse one package scratch/cache location; keep process-specific compiler and
# manifest temporary files under the project so they can be removed on exit.
export TMPDIR="${temporary_dir}/"
export TMP="$TMPDIR"
export TEMP="$TMPDIR"

swift "$swiftpm_command" \
    --scratch-path "$scratch_path" \
    --cache-path "$cache_path" \
    --manifest-cache local \
    "$@"
