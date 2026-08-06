#!/usr/bin/env bash
# Build WAMR (wasm-micro-runtime) as a static archive for the plugin host.
#
#     scripts/build-wamr.sh [macos|ios|iossim|all]     (default: macos)
#
# One Apple target per run, each into its own dist directory:
#
#   macos   vendor/wamr-dist/          host arch, the desktop app and the tests
#   ios     vendor/wamr-dist-ios/      arm64 device
#   iossim  vendor/wamr-dist-iossim/   arm64 simulator
#
# Each holds lib/libvmlib.a + include/*.h and is consumed by build.zig behind
# -Dplugins, which picks the directory from the target. All three are
# gitignored (vendor/wamr-dist*/).
#
# Idempotent per target: returns at once when that archive and its headers are
# already there. Force a rebuild with `rm -rf vendor/wamr-dist-<target>`; force
# a re-clone with `rm -rf vendor/wamr`.
set -euo pipefail

# Pinned WAMR release. Tag and commit move together; the commit is verified
# after the clone so a moved tag cannot change what gets built.
WAMR_TAG="WAMR-2.4.5"
WAMR_COMMIT="25bd7eb63e828e4bd242cc9b38d260b4b31c6605"
WAMR_URL="https://github.com/bytecodealliance/wasm-micro-runtime"

# Deployment minimums. 13.0 matches Zig's default macOS minimum, so ld64 raises
# no version warning. 15.0 is the app's stated iOS floor (macos/README.md); the
# Xcode project builds at a higher one, and an object built for an OLDER
# minimum links into it silently — the reverse is what warns.
MACOS_MIN="13.0"
IOS_MIN="15.0"

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
src="$root/vendor/wamr"

target="${1:-macos}"
case "$target" in
    macos|ios|iossim) targets=("$target") ;;
    all)              targets=(macos ios iossim) ;;
    *) echo "usage: ${BASH_SOURCE[0]##*/} [macos|ios|iossim|all]" >&2; exit 2 ;;
esac

if [ "$(uname -s)" != "Darwin" ]; then
    echo "build-wamr.sh: the plugin prototype targets Apple platforms only; this host is $(uname -s)" >&2
    exit 1
fi

for tool in git cmake; do
    command -v "$tool" >/dev/null 2>&1 || { echo "build-wamr.sh: $tool not found in PATH" >&2; exit 1; }
done

# The iOS SDKs live inside Xcode. The Command Line Tools have none, so an
# xcode-select pointed at them gives an empty sysroot and cmake fails on the
# compiler check. Find an Xcode the way macos/build.sh does; an exported
# DEVELOPER_DIR wins.
need_xcode() {
    [ -n "${DEVELOPER_DIR:-}" ] && return 0
    xcode-select -p 2>/dev/null | grep -q '\.app/Contents/Developer' && return 0
    for app in /Applications/Xcode.app /Applications/Xcode-beta.app \
               "$HOME"/Applications/Xcode*.app "$HOME"/Downloads/Xcode*.app; do
        if [ -x "$app/Contents/Developer/usr/bin/xcodebuild" ]; then
            export DEVELOPER_DIR="$app/Contents/Developer"
            echo "wamr: DEVELOPER_DIR=$DEVELOPER_DIR"
            return 0
        fi
    done
    echo "build-wamr.sh: no Xcode found, and the iOS SDKs are only in Xcode." >&2
    echo "               export DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer" >&2
    exit 1
}

ensure_src() {
    if [ ! -d "$src/.git" ]; then
        echo "wamr: cloning $WAMR_TAG into vendor/wamr"
        rm -rf "$src"
        git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$WAMR_TAG" "$WAMR_URL" "$src"
    fi

    head=$(git -C "$src" rev-parse HEAD)
    if [ "$head" != "$WAMR_COMMIT" ]; then
        echo "build-wamr.sh: vendor/wamr is at $head, the pin is $WAMR_COMMIT ($WAMR_TAG)." >&2
        echo "               Delete vendor/wamr and re-run to get the pinned tree." >&2
        exit 1
    fi

    # The runtime archive is not a target WAMR ships: product-mini builds an iwasm
    # executable and links vmlib into it. This project file adds vmlib alone from
    # the same source list.
    mkdir -p "$src/lookout-embed"
    cat >"$src/lookout-embed/CMakeLists.txt" <<'CMAKE'
cmake_minimum_required (VERSION 3.14)
project (wamr_vmlib C ASM)
if (NOT DEFINED WAMR_ROOT_DIR)
    set (WAMR_ROOT_DIR ${CMAKE_CURRENT_LIST_DIR}/..)
endif ()
include (${WAMR_ROOT_DIR}/build-scripts/runtime_lib.cmake)
add_library (vmlib STATIC ${WAMR_RUNTIME_LIB_SOURCE})
target_include_directories (vmlib PUBLIC ${WAMR_ROOT_DIR}/core/iwasm/include)
CMAKE
}

# Feature set for the prototype host. Identical on every target — the runtime
# is the fast interpreter everywhere, which is also what makes iOS work at all.
#   * fast interpreter only — no AOT, no JIT of either flavour. On iOS this is
#     not a preference: the OS refuses executable pages to an App Store app, so
#     the interpreter is the only runtime that can ship there.
#   * no WASI: plugins are wasm32-freestanding and reach the outside world
#     only through the `lookout` import module.
#   * libc-builtin ON: the small printf/memory builtins a module may import.
#   * bulk memory, reference types and extended const expressions ON because
#     the Zig wasm32 default CPU (lime1) emits them; SIMD, tail call, GC,
#     memory64, multi-memory and threads stay off — nothing emits them and
#     each one costs loader and interpreter code.
#   * thread manager ON, and it is the WATCHDOG that needs it. With it off,
#     wasm_runtime_terminate only writes the instance's exception string, and
#     nothing in the interpreter reads that string, so a plugin spinning in a
#     `while (true)` never notices and the terminate call does nothing. With it
#     on, wasm_set_exception routes through wasm_cluster_set_exception, which
#     also raises WASM_SUSPEND_FLAG_TERMINATE, and the fast interpreter's
#     CHECK_SUSPEND_FLAGS — compiled in only under this flag — tests it at every
#     branch, loop back edge and call, so the stuck frame returns at once. Cost:
#     one relaxed atomic load per back edge, plus a cluster object per instance.
#     LIB_PTHREAD stays off; plugins still cannot spawn threads.
#   * PIC: the archive is linked into liblookout_marine.a and from there into
#     app binaries.
#   * hardware bound check OFF: the alternative is WAMR installing
#     process-wide SIGSEGV/SIGBUS handlers beside Metal's and tile57's, and
#     mprotecting a guard page on every thread that calls into wasm — which
#     fails on macOS for stacks >= 8 MiB, Zig's thread default being 16 MiB.
#     Bounds are checked in the interpreter instead, at a few percent of
#     interpreter speed.
wamr_flags=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON
    -DWAMR_BUILD_PLATFORM=darwin
    -DWAMR_BUILD_INTERP=1
    -DWAMR_BUILD_FAST_INTERP=1
    -DWAMR_BUILD_AOT=0
    -DWAMR_BUILD_JIT=0
    -DWAMR_BUILD_FAST_JIT=0
    -DWAMR_BUILD_LIBC_BUILTIN=1
    -DWAMR_BUILD_LIBC_WASI=0
    -DWAMR_BUILD_LIBC_UVWASI=0
    -DWAMR_BUILD_LIB_PTHREAD=0
    -DWAMR_BUILD_LIB_WASI_THREADS=0
    -DWAMR_BUILD_THREAD_MGR=1
    -DWAMR_BUILD_MULTI_MODULE=0
    -DWAMR_BUILD_SHARED_MEMORY=0
    -DWAMR_BUILD_BULK_MEMORY=1
    -DWAMR_BUILD_REF_TYPES=1
    -DWAMR_BUILD_EXTENDED_CONST_EXPR=1
    -DWAMR_BUILD_SIMD=0
    -DWAMR_BUILD_TAIL_CALL=0
    -DWAMR_BUILD_GC=0
    -DWAMR_BUILD_MEMORY64=0
    -DWAMR_BUILD_MULTI_MEMORY=0
    -DWAMR_BUILD_MINI_LOADER=0
    -DWAMR_BUILD_DEBUG_INTERP=0
    -DWAMR_DISABLE_HW_BOUND_CHECK=1
)

build_one() {
    local t="$1" dist build label sdk wamr_target osx_arch
    local -a platform_flags

    case "$t" in
        macos)
            dist="$root/vendor/wamr-dist"
            case "$(uname -m)" in
                arm64|aarch64) wamr_target="AARCH64"; osx_arch="arm64" ;;
                x86_64)        wamr_target="X86_64";  osx_arch="x86_64" ;;
                *) echo "build-wamr.sh: unsupported host arch $(uname -m)" >&2; exit 1 ;;
            esac
            # No CMAKE_SYSTEM_NAME: a native build, and cmake finds the macOS SDK.
            platform_flags=(
                -DCMAKE_OSX_ARCHITECTURES="$osx_arch"
                -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN"
                -DWAMR_BUILD_TARGET="$wamr_target"
            )
            label="macOS $osx_arch, min $MACOS_MIN"
            ;;
        ios|iossim)
            need_xcode
            # CMAKE_SYSTEM_NAME=iOS is what makes this a cross build: cmake then
            # drives clang with -target arm64-apple-ios<min>[-simulator], picked
            # from the sysroot below. Devices and simulators are separate
            # mach-o platforms and their objects do not interchange, hence two
            # dists.
            if [ "$t" = ios ]; then
                dist="$root/vendor/wamr-dist-ios"; sdk="iphoneos"
            else
                dist="$root/vendor/wamr-dist-iossim"; sdk="iphonesimulator"
            fi
            platform_flags=(
                -DCMAKE_SYSTEM_NAME=iOS
                -DCMAKE_OSX_SYSROOT="$sdk"
                -DCMAKE_OSX_ARCHITECTURES=arm64
                -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN"
                -DWAMR_BUILD_TARGET=AARCH64
            )
            label="$sdk arm64, min $IOS_MIN"
            ;;
    esac

    if [ -f "$dist/lib/libvmlib.a" ] && [ -f "$dist/include/wasm_export.h" ]; then
        echo "wamr: ${dist#$root/} already built ($(cat "$dist/WAMR_VERSION" 2>/dev/null || echo unknown))"
        return 0
    fi

    ensure_src
    # One build directory per target, so the three configurations do not
    # overwrite each other's cmake cache.
    build="$src/build-lookout-$t"

    echo "wamr: configuring $t ($WAMR_TAG, $label, fast interpreter)"
    cmake -S "$src/lookout-embed" -B "$build" \
        "${wamr_flags[@]}" "${platform_flags[@]}" \
        -DWAMR_ROOT_DIR="$src" \
        >"$build.log" 2>&1 || { cat "$build.log" >&2; exit 1; }

    echo "wamr: building $t"
    cmake --build "$build" --parallel "$(sysctl -n hw.ncpu)" >>"$build.log" 2>&1 ||
        { tail -40 "$build.log" >&2; exit 1; }

    rm -rf "$dist"
    mkdir -p "$dist/lib" "$dist/include"
    cp "$build/libvmlib.a" "$dist/lib/libvmlib.a"
    cp "$src"/core/iwasm/include/*.h "$dist/include/"
    echo "$WAMR_TAG $WAMR_COMMIT $t" >"$dist/WAMR_VERSION"

    echo "wamr: ${dist#$root/}/lib/libvmlib.a ($(du -h "$dist/lib/libvmlib.a" | cut -f1)) from $WAMR_TAG"
}

for t in "${targets[@]}"; do build_one "$t"; done
