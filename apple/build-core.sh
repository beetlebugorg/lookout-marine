#!/usr/bin/env bash
# Build the zig cores for whichever Apple platform Xcode is building, and hand
# the app one archive to link.
#
# Every Apple target runs this as its pre-build phase, so the recipe lives here
# once instead of drifting between three copies of it in project.yml. It reads
# Xcode's own environment ($PLATFORM_NAME, $SDKROOT, the deployment minimums)
# and can also be run from a terminal with PLATFORM_NAME set:
#
#     PLATFORM_NAME=xros apple/build-core.sh
#
# What it does, in order:
#
#   1. the WAMR plugin runtime for this platform, if it is not already built
#   2. libpng and libwebp, cross-built, for every platform but macOS, which
#      takes Homebrew's
#   3. the tile57 engine and the lookout core, into zig-out[-$PLATFORM_NAME]
#   4. a repack of both archives into liblookoutall.a, because ld64 rejects
#      zig's archive members
#   5. a stamp that forces Xcode to relink when the core changed
#
# Steps 1, 2 and 4 are idempotent and return at once when nothing moved.
set -e
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

platform="${PLATFORM_NAME:-macosx}"

# The zig target, the archive suffix the vendor directories are named for, and
# the install prefix. macOS builds into zig-out, which the demo and the tests
# share; every cross build gets its own prefix, because a device and its
# simulator are separate mach-o platforms whose objects do not interchange.
case "$platform" in
    macosx)
        # Versioned at the deployment minimum: an unversioned native build
        # stamps objects with the build machine's OS, and ld warns "built for
        # newer macOS version than being linked" on every object.
        zig_target="$(uname -m | sed s/arm64/aarch64/)-macos.${MACOSX_DEPLOYMENT_TARGET:-26.0}"
        suffix=macos
        prefix="zig-out"
        ;;
    iphoneos)
        zig_target="aarch64-ios.${IPHONEOS_DEPLOYMENT_TARGET:-26.0}"
        suffix=ios
        prefix="zig-out-$platform"
        ;;
    iphonesimulator)
        zig_target="aarch64-ios.${IPHONEOS_DEPLOYMENT_TARGET:-26.0}-simulator"
        suffix=iossim
        prefix="zig-out-$platform"
        ;;
    xros)
        zig_target="aarch64-visionos.${XROS_DEPLOYMENT_TARGET:-26.0}"
        suffix=visionos
        prefix="zig-out-$platform"
        ;;
    xrsimulator)
        zig_target="aarch64-visionos.${XROS_DEPLOYMENT_TARGET:-26.0}-simulator"
        suffix=visionossim
        prefix="zig-out-$platform"
        ;;
    *)
        echo "build-core.sh: no zig target for PLATFORM_NAME=$platform" >&2
        exit 1
        ;;
esac

# Provenance: the build log states exactly which sources these cores came from.
# tile57 is a zig package dependency, a sibling checkout when present and else
# the zon pin.
T57="$root/../tile57"
echo "zig cores: lookout=$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo '?') | tile57=$([ -f "$T57/build.zig" ] && git -C "$T57" rev-parse --short HEAD 2>/dev/null || echo 'fetched: build.zig.zon pin')"

# $SDKROOT is set by Xcode to the active SDK, so this works even when the
# shell's xcrun points at the Command Line Tools, which carry no device SDK.
sysroot="${SDKROOT:-$(xcrun --sdk "$platform" --show-sdk-path)}"

# The wasm plugin host, before the core that embeds it. Own ship, AIS, NMEA
# 0183, Signal K and laylines are all plugins, so a core built without the host
# is a chart with no traffic.
scripts/build-wamr.sh "$suffix"
# libpng and libwebp. A device has no package manager, and Homebrew's copies
# are host-platform objects, so every platform but macOS links cross-built
# archives.
if [ "$platform" != "macosx" ]; then
    scripts/build-codecs.sh "$suffix"
fi

# -Dplugins is explicit: its default is off when the archive is absent, which
# would build a working app with no plugin host inside it. Explicit turns that
# into a build error naming the script above.
zig build -Doptimize=ReleaseFast \
    -Dplugins=true \
    -Dtarget="$zig_target" \
    --sysroot "$sysroot" \
    -p "$prefix"

# Zig's outputs are deterministic, so an unchanged core hashes identically.
# Used twice: to skip the repack, and to force Xcode to relink when the core
# did change.
core_hash=$(cat "$prefix/lib/liblookout_marine.a" "$prefix/lib/libtile57.a" | /usr/bin/shasum | cut -d' ' -f1)

# ld64 AND libtool both reject zig-emitted archive members ("64-bit mach-o not
# 8-byte aligned"), so the raw archives are never linked directly: extract to
# loose objects (which have no offset-alignment problem; zig also records
# mode-0 permissions, hence the chmod) and repack from those.
repack_stamp="$prefix/lib/.liblookoutall.stamp"
if [ "$(cat "$repack_stamp" 2>/dev/null)" != "$core_hash" ] || [ ! -f "$prefix/lib/liblookoutall.a" ]; then
    repack="$prefix/repack"
    rm -rf "$repack"; mkdir -p "$repack/lookout" "$repack/tile57"
    (cd "$repack/lookout" && ar x ../../lib/liblookout_marine.a)
    (cd "$repack/tile57"  && ar x ../../lib/libtile57.a)
    chmod 644 "$repack"/lookout/*.o "$repack"/tile57/*.o
    xcrun -sdk "$platform" libtool -static \
        -o "$prefix/lib/liblookoutall.a" \
        "$repack"/lookout/*.o "$repack"/tile57/*.o 2>/dev/null
    echo "$core_hash" > "$repack_stamp"
fi

# Xcode does not track libraries fed in through OTHER_LDFLAGS -l flags, so a
# rebuilt core would never RELINK the app and the bundle would keep a stale
# one. Force the link by removing the previous executable, which costs the link
# and nothing else. The stamp lives in TARGET_BUILD_DIR: per configuration and
# platform, like the executable it guards.
if [ -n "${TARGET_BUILD_DIR:-}" ] && [ -n "${EXECUTABLE_PATH:-}" ]; then
    link_stamp="$TARGET_BUILD_DIR/.zigcore.stamp"
    if [ "$(cat "$link_stamp" 2>/dev/null)" != "$core_hash" ]; then
        mkdir -p "$TARGET_BUILD_DIR"
        echo "$core_hash" > "$link_stamp"
        rm -f "$TARGET_BUILD_DIR/$EXECUTABLE_PATH"
    fi
fi
