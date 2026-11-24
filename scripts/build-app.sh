#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
build_dir="$project_dir/build"
configuration="release"

mkdir -p "$build_dir"
temporary_dir="$(mktemp -d "$build_dir/.tmp.build-app.XXXXXXXX")"
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
export TMPDIR="${temporary_dir}/"
export TMP="$TMPDIR"
export TEMP="$TMPDIR"

cd "$project_dir"
"$script_dir/swiftpm.sh" build -c "$configuration" --product NenRing
bin_dir="$("$script_dir/swiftpm.sh" build -c "$configuration" --show-bin-path)"

app_dir="$build_dir/NenRing.app"
contents_dir="$app_dir/Contents"
# Assemble the bundle from scratch so nothing from an earlier build survives,
# such as a removed probe or the executable and resources from before the
# rename to NenRing.
rm -rf -- "$app_dir"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
cp "$bin_dir/NenRing" "$contents_dir/MacOS/NenRing"
# The debug map records absolute source and build paths, which would publish
# the builder's home folder. Function symbols stay for crash reports.
strip -S "$contents_dir/MacOS/NenRing"
cp -R "$bin_dir/NenRing_NenRing.bundle" "$contents_dir/Resources/"
cp "Resources/Info.plist" "$contents_dir/Info.plist"
mkdir -p "$contents_dir/Resources/Legal"
for notice in LICENSE THIRD_PARTY_NOTICES.md THIRD_PARTY_NOTICES.ja.md; do
    cp "$notice" "$contents_dir/Resources/Legal/$notice"
done
cp "Resources/NenRingIcons/LICENSE.md" "$contents_dir/Resources/Legal/NenRingIcons-LICENSE.md"

# Keep the displayed version independent from Finder's bundle modification
# date. The semantic version is maintained in Resources/Info.plist; the
# numeric build and source revision identify the exact local build.
build_number="$(git rev-list --count HEAD 2>/dev/null || printf '0')"
build_commit="$(git rev-parse --short=12 HEAD 2>/dev/null || printf 'local')"
if [[ -n "$(git status --porcelain --untracked-files=all 2>/dev/null)" ]]; then
    build_commit="${build_commit}-dirty"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c "Set :NenRingBuildCommit $build_commit" "$contents_dir/Info.plist"

# Bundle only the fixed, reviewed read-only ASP probes. The app invokes these
# with a private output root; a manual FTL retry may use macOS administrator
# authorization and never receives a password or scans arbitrary opcodes.
probes_dir="$contents_dir/Resources/ASPProbes"
mkdir -p "$probes_dir"
xcrun clang -Wall -Wextra -Werror -O2 \
    scripts/asp-snapshot-probe.c \
    -framework IOKit -framework CoreFoundation \
    -o "$probes_dir/asp-snapshot-probe"
xcrun clang -Wall -Wextra -Werror -O2 \
    scripts/asp-ftl-stats-probe.c \
    -framework IOKit -framework CoreFoundation \
    -o "$probes_dir/asp-ftl-stats-probe"

icons_source_dir="Resources/NenRingIcons"
runtime_icons_dir="$contents_dir/Resources/NenRingIcons"
mkdir -p "$runtime_icons_dir"
cp "$icons_source_dir"/*.svg "$runtime_icons_dir/"

for appearance in light dark; do
    # Use the artist-rendered PNGs unchanged: AppKit's SVG mask rendering
    # differs from the intended artwork. Never regenerate these from SVG.
    iconset_dir="$icons_source_dir/AppIcon-${appearance}.iconset"
    swift "scripts/validate-iconset.swift" "$iconset_dir"
    mkdir -p "$runtime_icons_dir/AppIcon-${appearance}.iconset"
    cp "$iconset_dir"/*.png "$runtime_icons_dir/AppIcon-${appearance}.iconset/"
    if [[ "$appearance" == "light" ]]; then
        output_icon="$contents_dir/Resources/NenRingIconLight.icns"
    else
        output_icon="$contents_dir/Resources/NenRingIconDark.icns"
    fi
    iconutil -c icns "$iconset_dir" -o "$output_icon"
done

# Finder needs a single bundle icon on the macOS versions currently targeted.
# The running app switches between the two full ICNS files automatically or by preference.
cp "$contents_dir/Resources/NenRingIconLight.icns" "$contents_dir/Resources/AppIcon.icns"

for builder_path in "$project_dir" "$HOME"; do
    if LC_ALL=C grep -rlaF -- "$builder_path" "$app_dir" >&2; then
        echo "The bundle contains the build path $builder_path" >&2
        exit 1
    fi
done

if command -v codesign >/dev/null 2>&1; then
    signing_identity="${CODE_SIGN_IDENTITY:--}"
    if command -v xattr >/dev/null 2>&1; then
        xattr -cr "$app_dir"
    fi
    sign_options=(--force --options runtime --sign "$signing_identity")
    if [[ "$signing_identity" == "-" ]]; then
        sign_options+=(--timestamp=none)
    else
        sign_options+=(--timestamp)
    fi
    probes=("$probes_dir"/asp-snapshot-probe "$probes_dir"/asp-ftl-stats-probe)
    # Sign the probes before the app so the app's seal covers their final
    # signatures. The app checks that each identifier is the probe name.
    for probe in "${probes[@]}"; do
        codesign "${sign_options[@]}" --identifier "${probe:t}" "$probe" >/dev/null
    done
    codesign "${sign_options[@]}" "$app_dir" >/dev/null
    # Fail the build if the app or a privileged-capable probe lacks a valid
    # signature or the Hardened Runtime. Runtime verification repeats the
    # signature check immediately before each probe run.
    for code in "$app_dir" "${probes[@]}"; do
        codesign --verify --strict "$code" >/dev/null
        code_directory="$(codesign --display --verbose=1 "$code" 2>&1 | sed -n '/^CodeDirectory /p')"
        if [[ ! "$code_directory" =~ ' flags=0x[0-9a-f]+\([^)]*runtime[^)]*\) ' ]]; then
            echo "Hardened Runtime is missing from $code" >&2
            exit 1
        fi
    done
else
    echo "codesign is required because NenRing bundles privileged-capable probes" >&2
    exit 1
fi

echo "$app_dir"
