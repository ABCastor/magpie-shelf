#!/bin/bash
# Builds the app icon, light and dark, from the masters in Icon/.
#
#   scripts/make-icon.sh <out-dir>   ->  <out-dir>/AppIcon.icns, <out-dir>/Assets.car
#
# Icon/app-icon-{light,dark}.svg are the approved, frozen drawings (1024).
# Icon/AppIcon-{light,dark}.png are those drawings placed on the macOS icon
# grid (an 824-point tile on a 1024 canvas, with the system's soft shadow),
# rendered by a browser so the SVG is drawn exactly as it was approved.
# actool turns the pair into an asset catalog whose icon follows the
# system appearance (Assets.car, read through CFBundleIconName) and a
# light .icns for anything older that reads CFBundleIconFile.
set -euo pipefail
OUT="${1:?usage: make-icon.sh <out-dir>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
SET="${WORK}/Icon.xcassets/AppIcon.appiconset"
mkdir -p "${SET}" "${OUT}"
echo '{"info":{"author":"xcode","version":1}}' > "${WORK}/Icon.xcassets/Contents.json"
ENTRIES=""
for size in 16 32 128 256 512; do
  for scale in 1 2; do
    px=$((size * scale))
    for v in light dark; do
      fn="${v}-${size}@${scale}x.png"
      sips -z "${px}" "${px}" "${ROOT}/Icon/AppIcon-${v}.png" --out "${SET}/${fn}" >/dev/null
      appearance=""
      if [ "${v}" = dark ]; then
        appearance=',"appearances":[{"appearance":"luminosity","value":"dark"}]'
      fi
      ENTRIES="${ENTRIES}{\"filename\":\"${fn}\",\"idiom\":\"mac\",\"scale\":\"${scale}x\",\"size\":\"${size}x${size}\"${appearance}},"
    done
  done
done
echo "{\"images\":[${ENTRIES%,}],\"info\":{\"author\":\"xcode\",\"version\":1}}" > "${SET}/Contents.json"
xcrun actool "${WORK}/Icon.xcassets" --compile "${OUT}" --platform macosx \
  --minimum-deployment-target 13.0 --app-icon AppIcon \
  --output-partial-info-plist "${WORK}/partial.plist" >/dev/null
test -s "${OUT}/AppIcon.icns" && test -s "${OUT}/Assets.car"
