#!/usr/bin/env bash
# Copy the shipped plugin set into the app bundle being built.
#
# Every Apple target runs this as its post-build phase. The modules are wasm,
# so one build serves every platform and this needs no target of its own.
#
# It runs AFTER the bundle exists, so the copy lands in a real Resources
# directory, and before code signing, which Xcode does once every phase has
# run. The app loads the result at open.
set -e
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

# zig-out/plugins-bundled holds the shipped set and nothing else;
# zig-out/plugins is the dev working set and may carry examples and a
# developer's own modules beside it.
zig build plugins
dest="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Plugins"
mkdir -p "$dest"
# --delete so a plugin dropped from the shipped set leaves the app instead of
# lingering in an incremental build.
rsync -a --delete zig-out/plugins-bundled/ "$dest/"
echo "bundled plugins: $(ls "$dest" | grep -c '\.wasm$') module(s) in $dest"
