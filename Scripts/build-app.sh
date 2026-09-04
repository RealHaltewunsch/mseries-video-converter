#!/bin/bash
set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)
app_name="M-Series Video Converter"
dist_dir="$project_dir/dist"
app_dir="$dist_dir/$app_name.app"
target_triple="${TARGET_TRIPLE:-arm64-apple-macosx13.0}"
app_version="${APP_VERSION:-0.1.0}"
signing_identity="${SIGNING_IDENTITY:-}"

swift build -c release --triple "$target_triple" --package-path "$project_dir"
build_dir=$(swift build -c release --triple "$target_triple" --package-path "$project_dir" --show-bin-path)

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources/Engine"
cp "$build_dir/MSeriesVideoConverter" "$app_dir/Contents/MacOS/MSeriesVideoConverter"
cp "$project_dir/Support/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/Support/Engine/convert_videos.sh" "$app_dir/Contents/Resources/Engine/convert_videos.sh"
cp "$project_dir/Support/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
chmod +x "$app_dir/Contents/MacOS/MSeriesVideoConverter" "$app_dir/Contents/Resources/Engine/convert_videos.sh"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $app_version" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${GITHUB_RUN_NUMBER:-1}" "$app_dir/Contents/Info.plist"

if [ -n "$signing_identity" ]; then
  codesign --force --deep --options runtime --timestamp --sign "$signing_identity" "$app_dir"
  printf 'Developer ID signature: %s\n' "$signing_identity"
else
  codesign --force --deep --sign - "$app_dir"
  printf 'Note: ad-hoc signed; Apple notarization is unavailable.\n'
fi
codesign --verify --deep --strict --verbose=2 "$app_dir"

printf 'App created: %s\n' "$app_dir"
