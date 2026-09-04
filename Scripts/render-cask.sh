#!/bin/bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  printf 'Usage: %s VERSION SHA256 OUTPUT\n' "$0" >&2
  exit 2
fi

version=${1#v}
sha256=$2
output=$3

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  printf 'Invalid version: %s\n' "$version" >&2
  exit 2
}
case "$sha256" in *[!0-9a-f]*|'') printf 'Invalid SHA256 checksum.\n' >&2; exit 2;; esac
[ "${#sha256}" -eq 64 ] || { printf 'SHA256 must contain 64 characters.\n' >&2; exit 2; }

mkdir -p "$(dirname "$output")"
sed -e "s/__VERSION__/$version/g" -e "s/__SHA256__/$sha256/g" \
  "$(cd "$(dirname "$0")/.." && pwd)/Support/Homebrew/m-series-video-converter.rb.template" > "$output"
