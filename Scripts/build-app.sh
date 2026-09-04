#!/bin/bash
set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)
app_name="M-Series Video Converter"
build_dir="$project_dir/.build/release"
dist_dir="$project_dir/dist"
app_dir="$dist_dir/$app_name.app"

swift build -c release --package-path "$project_dir"

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources/Engine"
cp "$build_dir/MSeriesVideoConverter" "$app_dir/Contents/MacOS/MSeriesVideoConverter"
cp "$project_dir/Support/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/Support/Engine/convert_videos.sh" "$app_dir/Contents/Resources/Engine/convert_videos.sh"
chmod +x "$app_dir/Contents/MacOS/MSeriesVideoConverter" "$app_dir/Contents/Resources/Engine/convert_videos.sh"
codesign --force --deep --sign - "$app_dir"

printf 'App erstellt: %s\n' "$app_dir"
