#!/usr/bin/env bash
# Build libpng and libwebp as static archives for an Apple device platform.
#
#     scripts/build-codecs.sh [target]     (default: visionos)
#
# One target per run, each into its own dist directory:
#
#   visionos     vendor/codecs-visionos/      arm64 Vision Pro
#   visionossim  vendor/codecs-visionossim/   arm64 visionOS simulator
#   ios          vendor/codecs-ios/           arm64 device
#   iossim       vendor/codecs-iossim/        arm64 simulator
#
#   apple        every target above
#
# Each dist holds lib/lib{png16,webp}.a + include/, and build.zig hands the
# directory to charttable with -Dcodec-dir. A device has no Homebrew, so the
# /opt/homebrew archives the macOS build links cannot serve it, and pkg-config
# answers with host paths that fail inside the SDK sysroot.
#
# The versions match what Homebrew installs on this machine, so a chart decodes
# the same bytes on macOS and on the device.
#
# zlib is not built here. libpng needs it, and every Apple SDK ships
# usr/lib/libz.tbd; charttable links that stub when it builds under a sysroot.
#
# Idempotent per target: returns at once when both archives, the headers and
# the version stamp match what this script builds now. Force a rebuild with
# `rm -rf vendor/codecs-<target>`; force a re-clone with `rm -rf vendor/libpng
# vendor/libwebp`.
set -euo pipefail

PNG_VERSION="1.6.58"
WEBP_VERSION="1.6.0"
PNG_REPO="https://github.com/pnggroup/libpng.git"
WEBP_REPO="https://github.com/webmproject/libwebp.git"
PNG_TAG="v$PNG_VERSION"
WEBP_TAG="v$WEBP_VERSION"

# 1.0 is the visionOS floor and 15.0 the app's iOS floor. An object built for
# an older minimum links into a newer one without a warning.
VISIONOS_MIN="1.0"
IOS_MIN="15.0"

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

usage="usage: ${BASH_SOURCE[0]##*/} [visionos|visionossim|ios|iossim|apple]"
target="${1:-visionos}"
case "$target" in
    visionos|visionossim|ios|iossim) targets=("$target") ;;
    apple) targets=(visionos visionossim ios iossim) ;;
    *) echo "$usage" >&2; exit 2 ;;
esac

[ "$(uname -s)" = "Darwin" ] ||
    { echo "build-codecs.sh: the Apple SDKs are macOS only; this host is $(uname -s)" >&2; exit 1; }
for tool in git cmake; do
    command -v "$tool" >/dev/null 2>&1 ||
        { echo "build-codecs.sh: $tool not found in PATH" >&2; exit 1; }
done

# The device SDKs live inside Xcode. The Command Line Tools have none, so an
# xcode-select pointed at them gives an empty sysroot and cmake fails on the
# compiler check. An exported DEVELOPER_DIR wins.
need_xcode() {
    [ -n "${DEVELOPER_DIR:-}" ] && return 0
    xcode-select -p 2>/dev/null | grep -q '\.app/Contents/Developer' && return 0
    for app in /Applications/Xcode.app /Applications/Xcode-beta.app \
               "$HOME"/Applications/Xcode*.app "$HOME"/Downloads/Xcode*.app; do
        if [ -x "$app/Contents/Developer/usr/bin/xcodebuild" ]; then
            export DEVELOPER_DIR="$app/Contents/Developer"
            echo "codecs: DEVELOPER_DIR=$DEVELOPER_DIR"
            return 0
        fi
    done
    echo "build-codecs.sh: no Xcode found, and the device SDKs are only in Xcode." >&2
    echo "                 export DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer" >&2
    exit 1
}

ncpu() { sysctl -n hw.ncpu 2>/dev/null || echo 4; }

# Shallow clone at the tag, or fetch the tag into an existing clone.
clone_at() {
    local dir="$1" repo="$2" tag="$3"
    if [ -d "$dir/.git" ]; then
        [ "$(git -C "$dir" describe --tags --exact-match 2>/dev/null || echo none)" = "$tag" ] && return 0
        git -C "$dir" fetch --depth 1 origin "refs/tags/$tag:refs/tags/$tag"
    else
        rm -rf "$dir"
        git clone --depth 1 --branch "$tag" "$repo" "$dir"
        return 0
    fi
    git -C "$dir" checkout -q "$tag"
}

build_one() {
    local t="$1" dist sdk min
    need_xcode
    case "$t" in
        visionos)    dist="$root/vendor/codecs-visionos";    sdk="xros";           min="$VISIONOS_MIN"; system=visionOS ;;
        visionossim) dist="$root/vendor/codecs-visionossim"; sdk="xrsimulator";    min="$VISIONOS_MIN"; system=visionOS ;;
        ios)         dist="$root/vendor/codecs-ios";         sdk="iphoneos";       min="$IOS_MIN";      system=iOS ;;
        iossim)      dist="$root/vendor/codecs-iossim";      sdk="iphonesimulator"; min="$IOS_MIN";     system=iOS ;;
    esac
    local stamp="$dist/VERSIONS"
    local want="libpng $PNG_VERSION libwebp $WEBP_VERSION"
    if [ -f "$dist/lib/libpng16.a" ] && [ -f "$dist/lib/libwebp.a" ] &&
       [ -f "$dist/include/png.h" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$want" ]; then
        echo "codecs: $t up to date ($want)"
        return 0
    fi

    local sysroot
    sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)
    echo "codecs: building $t ($sdk arm64, min $min)"

    clone_at "$root/vendor/libpng" "$PNG_REPO" "$PNG_TAG"
    clone_at "$root/vendor/libwebp" "$WEBP_REPO" "$WEBP_TAG"

    rm -rf "$dist"
    mkdir -p "$dist/lib" "$dist/include"

    local -a common=(
        -DCMAKE_SYSTEM_NAME="$system"
        -DCMAKE_OSX_SYSROOT="$sysroot"
        -DCMAKE_OSX_ARCHITECTURES=arm64
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$min"
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON
        -DBUILD_SHARED_LIBS=OFF
    )

    # libpng. The SDK's zlib is a .tbd stub, which cmake's FindZLIB accepts as
    # the import library; the symbols resolve against the OS copy at link time.
    local png_build="$root/vendor/libpng/build-lookout-$t"
    rm -rf "$png_build"; mkdir -p "$png_build"
    cmake -S "$root/vendor/libpng" -B "$png_build" "${common[@]}" \
        -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_FRAMEWORK=OFF \
        -DPNG_TESTS=OFF -DPNG_TOOLS=OFF -DPNG_HARDWARE_OPTIMIZATIONS=ON \
        -DZLIB_INCLUDE_DIR="$sysroot/usr/include" \
        -DZLIB_LIBRARY="$sysroot/usr/lib/libz.tbd" \
        >"$png_build/configure.log" 2>&1 ||
        { echo "build-codecs.sh: libpng configure failed; see $png_build/configure.log" >&2; exit 1; }
    cmake --build "$png_build" --target png_static -j "$(ncpu)" \
        >"$png_build/build.log" 2>&1 ||
        { echo "build-codecs.sh: libpng build failed; see $png_build/build.log" >&2; exit 1; }
    cp "$png_build/libpng16.a" "$dist/lib/libpng16.a"
    cp "$root/vendor/libpng/png.h" "$root/vendor/libpng/pngconf.h" "$dist/include/"
    cp "$png_build/pnglibconf.h" "$dist/include/"

    # libwebp. Only the decoder is used, but the full library is one target and
    # the linker drops what nothing calls.
    local webp_build="$root/vendor/libwebp/build-lookout-$t"
    rm -rf "$webp_build"; mkdir -p "$webp_build"
    cmake -S "$root/vendor/libwebp" -B "$webp_build" "${common[@]}" \
        -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
        -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
        -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF \
        >"$webp_build/configure.log" 2>&1 ||
        { echo "build-codecs.sh: libwebp configure failed; see $webp_build/configure.log" >&2; exit 1; }
    cmake --build "$webp_build" --target webp -j "$(ncpu)" \
        >"$webp_build/build.log" 2>&1 ||
        { echo "build-codecs.sh: libwebp build failed; see $webp_build/build.log" >&2; exit 1; }
    cp "$webp_build/libwebp.a" "$dist/lib/libwebp.a"
    mkdir -p "$dist/include/webp"
    cp "$root"/vendor/libwebp/src/webp/*.h "$dist/include/webp/"

    printf '%s' "$want" >"$stamp"
    local png_sz webp_sz
    png_sz=$(du -h "$dist/lib/libpng16.a" | cut -f1 | tr -d ' ')
    webp_sz=$(du -h "$dist/lib/libwebp.a" | cut -f1 | tr -d ' ')
    echo "codecs: ${dist#"$root/"}/lib/libpng16.a ($png_sz), libwebp.a ($webp_sz)"
}

for t in "${targets[@]}"; do build_one "$t"; done
