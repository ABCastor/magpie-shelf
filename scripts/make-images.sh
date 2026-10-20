#!/usr/bin/env bash
# Regenerates every image in docs/images/ from the real views.
#
# The pictures in the README are not screenshots somebody took once. They are
# offscreen renders of the actual SwiftUI views, produced by
# Tests/MagpieTests/RenderSnapshots.swift, so a change to the shelf changes the
# documentation the next time this runs. A hand-recorded take is a performance
# that goes stale the first time a control moves, and nobody notices.
#
# Needs ffmpeg for the animation. Without it, the stills are still written and
# the script says so.
#
#     ./scripts/make-images.sh
set -euo pipefail
cd "$(dirname "$0")/.."

shots="${TMPDIR:-/tmp}/magpie-images-$$"
out="docs/images"
mkdir -p "$shots" "$out"
trap 'rm -rf "$shots"' EXIT

echo "==> Rendering the views"
MAGPIE_RENDER_SNAPSHOTS=1 MAGPIE_SNAPSHOT_DIR="$shots" \
    swift test --filter RenderSnapshots >/dev/null

echo "==> Stills"
cp "$shots/container-dark.png"            "$out/shelf-dark.png"
cp "$shots/container-light.png"           "$out/shelf-light.png"
cp "$shots/strip-dragging-move-dark.png"  "$out/drag-move-hint.png"

echo "==> Animation"
if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "    ffmpeg not found, keeping the existing selection.gif"
    exit 0
fi

# Four real states in the order a user moves through them: the resting shelf,
# one row picked, three picked, and back to rest. Every frame is a render of a
# state the app actually has, which is why this is a demo and not an
# illustration.
seq_dir="$shots/seq"
mkdir -p "$seq_dir"
i=0
for f in strip-selection-default-dark strip-selection-one-dark \
         strip-selection-several-dark strip-selection-default-dark; do
    i=$((i + 1))
    cp "$shots/$f.png" "$seq_dir/$(printf '%02d' "$i").png"
done

ffmpeg -y -loglevel error -framerate 0.8 -i "$seq_dir/%02d.png" \
    -vf "scale=360:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=single[p];[b][p]paletteuse=new=1" \
    -loop 0 "$out/selection.gif"

echo "==> Done"
ls -lh "$out"
