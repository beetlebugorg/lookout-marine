#!/bin/zsh
# Build the app with Xcode into apple/build/, not into the shared DerivedData
# directory. `rm -rf apple/build` is a full clean.
#
#   apple/build.sh [mac|ios|visionos|visionos-device|all] [Debug|Release]
#
# This builds everything the app needs, from nothing: the target's WAMR runtime
# (scripts/build-wamr.sh), the Zig cores with the wasm plugin host linked in,
# and the shipped plugin set into Resources/Plugins. That work lives in the
# target's script phases, in apple/project.yml, so a build from Xcode.app is
# the same build as this one. Only zig, cmake and Xcode are needed; the first
# run clones and builds the pinned WAMR and takes a few minutes.
#
# Without Xcode, use build-dev.sh: swiftc and a hand-rolled bundle, macOS only.
set -e

# xcodebuild needs Xcode. It fails when xcode-select points at the Command Line
# Tools, so find an Xcode and set DEVELOPER_DIR for this run. An exported
# DEVELOPER_DIR wins.
if [[ -z "$DEVELOPER_DIR" ]] && ! xcode-select -p 2>/dev/null | grep -q '\.app/Contents/Developer'; then
  for app in /Applications/Xcode.app /Applications/Xcode-beta.app \
             $HOME/Applications/Xcode*.app $HOME/Downloads/Xcode*.app; do
    if [[ -x "$app/Contents/Developer/usr/bin/xcodebuild" ]]; then
      export DEVELOPER_DIR="$app/Contents/Developer"
      echo "==> DEVELOPER_DIR=$DEVELOPER_DIR"
      break
    fi
  done
fi
if [[ -z "$DEVELOPER_DIR" ]] && ! xcode-select -p 2>/dev/null | grep -q '\.app/Contents/Developer'; then
  echo "no Xcode found. Set it with:" >&2
  echo "  export DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer" >&2
  echo "  sudo xcode-select -s /path/to/Xcode.app/Contents/Developer" >&2
  exit 1
fi

REPO="${0:A:h:h}"
TARGET="${1:-mac}"
CONFIG="${2:-Debug}"
DERIVED="$REPO/apple/build"
PROJECT="$REPO/apple/LookoutMarine.xcodeproj"

# The project is generated, so an edit to project.yml is always applied.
if command -v xcodegen >/dev/null 2>&1; then
  (cd "$REPO/apple" && xcodegen generate --quiet)
elif [[ ! -d "$PROJECT" ]]; then
  echo "no project and no xcodegen: brew install xcodegen" >&2
  exit 1
fi

build() {
  echo "==> $1 ($CONFIG)"
  xcodebuild -project "$PROJECT" -scheme "$1" -configuration "$CONFIG" \
    -destination "$2" -derivedDataPath "$DERIVED" build
}

case "$TARGET" in
  mac)      build LookoutMarine 'platform=macOS' ;;
  ios)      build LookoutMarine-iOS 'generic/platform=iOS Simulator' ;;
  visionos) build LookoutMarine-visionOS 'generic/platform=visionOS Simulator' ;;
  visionos-device) build LookoutMarine-visionOS 'generic/platform=visionOS' ;;
  both)     build LookoutMarine 'platform=macOS'
            build LookoutMarine-iOS 'generic/platform=iOS Simulator' ;;
  all)      build LookoutMarine 'platform=macOS'
            build LookoutMarine-iOS 'generic/platform=iOS Simulator'
            build LookoutMarine-visionOS 'generic/platform=visionOS Simulator' ;;
  *) echo "usage: ${0:t} [mac|ios|visionos|visionos-device|both|all] [Debug|Release]" >&2; exit 2 ;;
esac

echo "==> products in $DERIVED/Build/Products/"
