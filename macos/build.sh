#!/bin/zsh
# Build the app with Xcode into macos/build-mac/, not into the shared
# DerivedData directory. `rm -rf macos/build-mac` is a full clean.
#
#   macos/build.sh [mac|ios|both] [Debug|Release]
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
DERIVED="$REPO/macos/build-mac"
PROJECT="$REPO/macos/LookoutMarine.xcodeproj"

[[ -d "$PROJECT" ]] || { echo "no project: run 'cd macos && xcodegen generate'" >&2; exit 1 }

build() {
  echo "==> $1 ($CONFIG)"
  xcodebuild -project "$PROJECT" -scheme "$1" -configuration "$CONFIG" \
    -destination "$2" -derivedDataPath "$DERIVED" build
}

case "$TARGET" in
  mac)  build LookoutMarine 'platform=macOS' ;;
  ios)  build LookoutMarine-iOS 'generic/platform=iOS Simulator' ;;
  both) build LookoutMarine 'platform=macOS'
        build LookoutMarine-iOS 'generic/platform=iOS Simulator' ;;
  *)    echo "usage: ${0:t} [mac|ios|both] [Debug|Release]" >&2; exit 2 ;;
esac

echo "==> products in $DERIVED/Build/Products/"
