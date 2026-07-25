#!/bin/zsh
# Dev-build the Lookout Marine macOS app WITHOUT Xcode: swiftc + a hand-rolled
# .app bundle (Command Line Tools are enough). Repacks the Zig archives through
# libtool (ld64 alignment). Rendering is direct Metal.
#
#   macos/build-dev.sh [--zig]     # --zig also rebuilds the Zig cores first
#
# tile57 is a zig package dependency (sibling ../tile57 checkout if present,
# else fetched per ../build.zig.zon) — `zig build` installs both archives and
# headers into zig-out/. Overridable: OUT (build dir).
set -e
REPO="${0:A:h:h}"
OUT="${OUT:-$REPO/macos/build}"
SDK=$(xcrun --show-sdk-path)
mkdir -p "$OUT"
cd "$REPO"

if [[ "$1" == "--zig" ]]; then
  echo "==> zig build cores (lookout + tile57 dependency)"
  zig build -Doptimize=ReleaseFast
fi

echo "==> repack + merge zig archives (ld64 alignment)"
# ld64 AND libtool silently DROP zig-emitted archive members whose offsets
# aren't 8-byte aligned — feeding the archives to libtool directly can lose
# symbols depending on member sizes. Extract to loose objects (zig also records
# mode-0 member permissions, hence the chmod) and repack from those.
rm -rf "$OUT/repack"; mkdir -p "$OUT/repack/lookout" "$OUT/repack/tile57"
(cd "$OUT/repack/lookout" && ar x "$REPO/zig-out/lib/liblookout_marine.a")
(cd "$OUT/repack/tile57"  && ar x "$REPO/zig-out/lib/libtile57.a")
chmod 644 "$OUT"/repack/lookout/*.o "$OUT"/repack/tile57/*.o
xcrun libtool -static -o "$OUT/liblookoutall.a" \
  "$OUT"/repack/lookout/*.o "$OUT"/repack/tile57/*.o 2>/dev/null

echo "==> swiftc app"
xcrun swiftc -swift-version 5 -sdk "$SDK" -target arm64-apple-macosx26.0 \
  -O \
  -import-objc-header macos/LookoutMarine/Bridging-Header.h \
  -I zig-out/include \
  -L "$OUT" \
  -llookoutall \
  -framework Metal -framework QuartzCore \
  -framework CoreGraphics -framework UniformTypeIdentifiers \
  -o "$OUT/LookoutMarine" macos/LookoutMarine/*.swift 2>&1 \
  | grep -v "was built for newer\|not an allowed client of it" || true

echo "==> bundle"
APP="$OUT/LookoutMarine.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$OUT/LookoutMarine" "$APP/Contents/MacOS/LookoutMarine"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>LookoutMarine</string>
  <key>CFBundleIdentifier</key><string>org.beetlebug.lookout-marine</string>
  <key>CFBundleName</key><string>Lookout Marine</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - --entitlements macos/LookoutMarine/LookoutMarine.entitlements "$APP" 2>/dev/null || true
echo "==> built $APP"
