#!/bin/bash
set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)
MVC_ENGINE_LIBRARY_ONLY=1 source "$project_dir/Support/Engine/convert_videos.sh"

source_json='[{"QuickTime:CreateDate":"2019:11:21 17:57:58+01:00","UserData:GPSCoordinates":"37.213154 -113.247509 66.3"}]'
output_json='[{"QuickTime:CreateDate":"2019:11:21 17:57:58+01:00","Keys:Location":"+37.213154-113.247509+66.300"}]'

source_signature=$(printf '%s\n' "$source_json" | normalize_core_metadata)
output_signature=$(printf '%s\n' "$output_json" | normalize_core_metadata)

if [ "$source_signature" != "$output_signature" ]; then
  printf 'Equivalent QuickTime GPS representations produced different signatures.\n' >&2
  printf 'Source: %s\nOutput: %s\n' "$source_signature" "$output_signature" >&2
  exit 1
fi

printf 'Metadata normalization regression test passed.\n'
