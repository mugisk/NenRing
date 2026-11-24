#!/bin/zsh
set -euo pipefail

# Run after scripts/ci-local.sh. Keep artifacts in the ignored build directory.
project_dir="${0:A:h:h}"
app_dir="$project_dir/build/NenRing.app"
output_dir="$project_dir/build/releases"
test -d "$app_dir"
codesign --verify --deep --strict "$app_dir"
for probe in asp-ftl-stats-probe asp-snapshot-probe; do
    codesign --verify --strict "$app_dir/Contents/Resources/ASPProbes/$probe"
done
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Contents/Info.plist")"
revision="$(/usr/libexec/PlistBuddy -c 'Print :NenRingBuildCommit' "$app_dir/Contents/Info.plist")"
mkdir -p "$output_dir"
temporary_dir="$(mktemp -d "$project_dir/build/.tmp.package.XXXXXXXX")"
mount_point="$temporary_dir/mount"
cleanup() {
    local exit_code=$?
    trap - EXIT
    if [[ -d "$mount_point" ]] && mount | grep -qF " on $mount_point "; then
        hdiutil detach -quiet "$mount_point" || hdiutil detach -quiet -force "$mount_point" || exit_code=1
    fi
    rm -rf -- "$temporary_dir" || exit_code=$?
    exit "$exit_code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export TMPDIR="$temporary_dir/"

# The volume shows the app beside a link to /Applications so it can be
# dragged across. Clear local extended attributes such as a quarantine flag;
# macOS keeps com.apple.provenance on files created here, and it holds no
# user name or address.
staging_dir="$temporary_dir/NenRing"
mkdir "$staging_dir"
ditto "$app_dir" "$staging_dir/NenRing.app"
xattr -cr "$staging_dir/NenRing.app"
ln -s /Applications "$staging_dir/Applications"

image_name="NenRing-${version}-${revision}-experimental.dmg"
image_path="$temporary_dir/$image_name"
hdiutil create -quiet -volname NenRing -srcfolder "$staging_dir" \
    -fs HFS+ -format UDZO "$image_path"
hdiutil verify -quiet "$image_path"

# Check the image as a user would receive it before replacing this script's
# own fixed-name output.
mkdir "$mount_point"
hdiutil attach -quiet -readonly -nobrowse -noautoopen \
    -mountpoint "$mount_point" "$image_path"
diff -rq "$app_dir" "$mount_point/NenRing.app"
codesign --verify --deep --strict "$mount_point/NenRing.app"
for probe in asp-ftl-stats-probe asp-snapshot-probe; do
    codesign --verify --strict "$mount_point/NenRing.app/Contents/Resources/ASPProbes/$probe"
done
test "$(readlink "$mount_point/Applications")" = /Applications
hdiutil detach -quiet "$mount_point"

mv "$image_path" "$output_dir/$image_name"
cd "$output_dir"
shasum -a 256 "$image_name" > "$image_name.sha256"
print "$output_dir/$image_name"
