#!/bin/bash
set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)

release_credentials=(
  "${SIGNING_IDENTITY:-}"
  "${APPLE_ID:-}"
  "${APPLE_TEAM_ID:-}"
  "${APPLE_APP_PASSWORD:-}"
)
present=0
for value in "${release_credentials[@]}"; do
  [ -n "$value" ] && present=$((present + 1))
done
if [ "$present" -ne 0 ] && [ "$present" -ne 4 ]; then
  printf 'Fehler: Signierung und Notarisierung müssen vollständig oder gar nicht konfiguriert sein.\n' >&2
  exit 2
fi

"$project_dir/Scripts/build-app.sh"
cd "$project_dir/dist"
rm -f M-Series-Video-Converter.zip
/usr/bin/ditto -c -k --keepParent "M-Series Video Converter.app" M-Series-Video-Converter.zip

if [ "$present" -eq 4 ]; then
  printf 'Übermittle App zur Apple-Notarisierung …\n'
  xcrun notarytool submit M-Series-Video-Converter.zip \
    --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" --wait
  xcrun stapler staple "M-Series Video Converter.app"
  xcrun stapler validate "M-Series Video Converter.app"
  codesign --verify --deep --strict --verbose=2 "M-Series Video Converter.app"
  spctl --assess --type execute --verbose=2 "M-Series Video Converter.app"
  rm -f M-Series-Video-Converter.zip
  /usr/bin/ditto -c -k --keepParent "M-Series Video Converter.app" M-Series-Video-Converter.zip
  printf 'Notarisierung erfolgreich.\n'
else
  printf 'Hinweis: Apple-Zugangsdaten fehlen; Release bleibt ad-hoc signiert.\n'
fi

shasum -a 256 M-Series-Video-Converter.zip
printf 'Release-Paket erstellt: %s\n' "$project_dir/dist/M-Series-Video-Converter.zip"
