#!/usr/bin/env bash
# Run the chart table's macOS harness.
#
#     apple/tests/run.sh [chart.pmtiles]
#
# The visionOS app cannot be launched on this machine, so this exercises the
# chain underneath it on the Mac: the RealityKit drawable queue, the core's
# texture render path, the geo-to-sheet mapping and the AIS decoder the app
# ships. It compiles apple/LookoutMarine-visionOS/AISRows.swift, so the decoder under
# test is the one that ships. PluginAlerts comes along so the alarm the AIS
# plugin raises is decoded here by the same reader the apps use.
#
# Traffic needs a feed. With none, the AIS section checks the decoder against
# the ABI's own documented example instead:
#
#     zig run tools/nmea_gen.zig -- test/annapolis.nmea     # once
#     zig run -lc tools/nmea_replay.zig -- --port 10110 &
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$root"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

if [ -z "${DEVELOPER_DIR:-}" ] && ! xcode-select -p 2>/dev/null | grep -q '\.app/Contents/Developer'; then
    for app in /Applications/Xcode.app /Applications/Xcode-beta.app \
               "$HOME"/Applications/Xcode*.app "$HOME"/Downloads/Xcode*.app; do
        if [ -x "$app/Contents/Developer/usr/bin/xcodebuild" ]; then
            export DEVELOPER_DIR="$app/Contents/Developer"
            break
        fi
    done
fi

# The macOS core, and the plugin set the harness loads.
scripts/build-wamr.sh macos >/dev/null
zig build -Doptimize=ReleaseFast -Dplugins=true
zig build plugins >/dev/null

# ld64 rejects zig-emitted archive members, so repack to loose objects first,
# exactly as the app targets do.
repack="zig-out/repack-test"
rm -rf "$repack"; mkdir -p "$repack/lookout" "$repack/tile57"
(cd "$repack/lookout" && ar x ../../lib/liblookout_marine.a)
(cd "$repack/tile57" && ar x ../../lib/libtile57.a)
chmod 644 "$repack"/lookout/*.o "$repack"/tile57/*.o
xcrun libtool -static -o "$repack/liblookoutall.a" "$repack"/lookout/*.o "$repack"/tile57/*.o 2>/dev/null

out="zig-out/table-smoke"
xcrun swiftc -O \
    -import-objc-header apple/LookoutMarine-visionOS/Bridging-Header.h \
    -I zig-out/include \
    apple/LookoutMarine-visionOS/AISRows.swift \
    apple/LookoutMarine-visionOS/DepthField.swift \
    apple/LookoutMarine/PluginAlerts.swift \
    apple/LookoutMarine/PickDecoded.swift \
    apple/LookoutMarine/Chrome.swift \
    apple/LookoutMarine-visionOS/Log.swift \
    apple/tests/main.swift \
    "$repack/liblookoutall.a" \
    -lz \
    -framework RealityKit -framework Metal -framework CoreGraphics -framework Foundation \
    -o "$out"

exec "$out" "$@"
