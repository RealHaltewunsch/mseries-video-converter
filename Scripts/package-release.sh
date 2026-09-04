#!/bin/bash
set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)
"$project_dir/Scripts/build-app.sh"
cd "$project_dir/dist"
rm -f M-Series-Video-Converter.zip
/usr/bin/ditto -c -k --keepParent "M-Series Video Converter.app" M-Series-Video-Converter.zip
printf 'Release-Paket erstellt: %s\n' "$project_dir/dist/M-Series-Video-Converter.zip"
