#!/usr/bin/env bash
# Build Lookout Table for visionOS.
#
#     visionos/build.sh [device|simulator] [Debug|Release]
#
# Defaults to the simulator, Debug. The app and its cores land in
# visionos/build-xros/Build/Products/<config>-<platform>/.
#
# It generates the Xcode project from project.yml first, so an edit there is
# always applied. The pre-build script inside the project builds the zig cores,
# the WAMR runtime and the image codecs for the platform being built.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root/visionos"

target="${1:-simulator}"
config="${2:-Debug}"
case "$target" in
    device)    destination="generic/platform=visionOS" ;;
    simulator) destination="generic/platform=visionOS Simulator" ;;
    *) echo "usage: ${BASH_SOURCE[0]##*/} [device|simulator] [Debug|Release]" >&2; exit 2 ;;
esac

# The visionOS SDK is only in Xcode. An exported DEVELOPER_DIR wins.
if [ -z "${DEVELOPER_DIR:-}" ] && ! xcode-select -p 2>/dev/null | grep -q '\.app/Contents/Developer'; then
    for app in /Applications/Xcode.app /Applications/Xcode-beta.app \
               "$HOME"/Applications/Xcode*.app "$HOME"/Downloads/Xcode*.app; do
        if [ -x "$app/Contents/Developer/usr/bin/xcodebuild" ]; then
            export DEVELOPER_DIR="$app/Contents/Developer"
            break
        fi
    done
fi
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

command -v xcodegen >/dev/null 2>&1 || { echo "build.sh: xcodegen not found (brew install xcodegen)" >&2; exit 1; }
xcodegen generate --quiet

# The sample cell the app falls back to when Documents holds no chart. Copied
# rather than tracked: charts are data, not source.
sample="$HOME/Charts/ENC_ROOT/US5MD1MC/US5MD1MC.pmtiles"
if [ -f "$sample" ] && [ ! -f Charts/US5MD1MC.pmtiles ]; then
    mkdir -p Charts
    cp "$sample" Charts/US5MD1MC.pmtiles
    echo "sample chart: Charts/US5MD1MC.pmtiles"
fi

xcodebuild -project LookoutTable.xcodeproj \
    -scheme LookoutTable \
    -configuration "$config" \
    -destination "$destination" \
    -derivedDataPath build-xros \
    CODE_SIGNING_ALLOWED=NO \
    build
