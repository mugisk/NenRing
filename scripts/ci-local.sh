#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
build_dir="$project_dir/build"
log_path="$build_dir/ci-local.log"
app_path="$build_dir/NenRing.app"

mkdir -p "$build_dir"
cd "$project_dir"

# Keep one readable CI log and all compiler output in the repository's fixed
# build directory. The SwiftPM and app-build wrappers clean only their own
# per-run temporary subdirectories.
exec > >(tee "$log_path") 2>&1

print "NenRing local CI"
print "Started: $(date '+%Y-%m-%d %H:%M:%S %Z')"
swift --version

if ! command -v smartctl >/dev/null 2>&1; then
    print -u2 "smartctl was not found. Install smartmontools, then rerun: brew install smartmontools"
    exit 69
fi
smartctl --version | head -n 1

print "\n== Swift test =="
"$script_dir/swiftpm.sh" test

print "\n== Release app bundle =="
"$script_dir/build-app.sh"

print "\n== App and helper signatures =="
codesign --verify --deep --strict --verbose=2 "$app_path"
for probe in "$app_path/Contents/Resources/ASPProbes/asp-ftl-stats-probe" \
             "$app_path/Contents/Resources/ASPProbes/asp-snapshot-probe"; do
    test -x "$probe"
    codesign --verify --strict --verbose=2 "$probe"
done

print "\n== Build identity =="
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :NenRingBuildCommit' "$app_path/Contents/Info.plist"
print "\nLOCAL CI PASSED"
print "Log: $log_path"
