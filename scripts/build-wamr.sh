#!/usr/bin/env bash
# Build WAMR (wasm-micro-runtime) as a static archive for the plugin host.
#
#     scripts/build-wamr.sh [target]     (default: macos)
#
# One target per run, each into its own dist directory:
#
#   macos          vendor/wamr-dist/                host arch, the desktop app and the tests
#   ios            vendor/wamr-dist-ios/            arm64 device
#   iossim         vendor/wamr-dist-iossim/         arm64 simulator
#   linux-x64      vendor/wamr-dist-linux-x64/
#   linux-arm64    vendor/wamr-dist-linux-arm64/
#   windows-x64    vendor/wamr-dist-windows-x64/    mingw ABI — see WINDOWS below
#   android-arm64  vendor/wamr-dist-android-arm64/  arm64-v8a, NDK API 24
#
#   apple          macos ios iossim
#   all            every target above
#
# Each holds lib/libvmlib.a + include/*.h and is consumed by build.zig behind
# -Dplugins, which picks the directory from the target. All are gitignored
# (vendor/wamr-dist*/).
#
# The Apple targets need Xcode and run on macOS only. The four cross targets
# need zig and cmake and nothing else: WAMR is plain C, so `zig cc -target ...`
# is the cross compiler and `zig ar` writes the archive. See cross_toolchain.
#
# WINDOWS. This builds the mingw ABI (x86_64-windows-gnu). The shipping Windows
# app is MSVC — windows/build-core.ps1 selects aarch64-windows-msvc — and the
# two ABIs do not meet. `scripts/build-wamr.sh windows-x64 --print-msvc` prints
# the cmake command that builds the MSVC archive on a Windows machine. A dist
# directory is per platform and architecture, not per ABI, so the two Windows
# x64 archives share one and the last one written wins.
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
# minimum links into it silently — the reverse is what warns. 24 is the API
# level android/app/build.gradle declares as minSdk and build.zig defaults to.
MACOS_MIN="13.0"
IOS_MIN="15.0"
ANDROID_API="24"

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
src="$root/vendor/wamr"

usage="usage: ${BASH_SOURCE[0]##*/} [macos|ios|iossim|linux-x64|linux-arm64|windows-x64|android-arm64|apple|all] [--print-msvc]"
target="${1:-macos}"
case "$target" in
    macos|ios|iossim|linux-x64|linux-arm64|windows-x64|android-arm64) targets=("$target") ;;
    apple) targets=(macos ios iossim) ;;
    all)   targets=(macos ios iossim linux-x64 linux-arm64 windows-x64 android-arm64) ;;
    *) echo "$usage" >&2; exit 2 ;;
esac

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
#     interpreter speed. It keeps the Android archive out of the JVM's signal
#     handlers too.
# WAMR_BUILD_PLATFORM names the core/shared/platform/<name> layer; every cross
# target overrides the darwin default below.
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

# The recipe for the MSVC-ABI archive, which this host cannot build. Printed on
# request and whenever the mingw cross build fails, so the feature flags in the
# recipe are the same list the rest of the script uses.
print_msvc_recipe() {
    local f
    echo >&2
    echo "The MSVC-ABI archive is built on the Windows machine itself: the Windows SDK" >&2
    echo "is not on this host. In a Visual Studio x64 Native Tools Command Prompt" >&2
    echo "(the ARM64 prompt, -A ARM64 and -DWAMR_BUILD_TARGET=AARCH64 on an arm64 box):" >&2
    echo >&2
    echo "    git clone --depth 1 --branch $WAMR_TAG $WAMR_URL wamr" >&2
    echo "    cd wamr" >&2
    echo "    mkdir lookout-embed" >&2
    echo "    ... write lookout-embed\\CMakeLists.txt as ensure_src() in this script does:" >&2
    echo "        it includes build-scripts/runtime_lib.cmake and adds one STATIC vmlib" >&2
    echo "        from \${WAMR_RUNTIME_LIB_SOURCE}." >&2
    echo "    cmake -S lookout-embed -B build -A x64 ^" >&2
    for f in "${wamr_flags[@]}"; do
        case "$f" in
            -DWAMR_BUILD_PLATFORM=*) echo "        -DWAMR_BUILD_PLATFORM=windows ^" >&2 ;;
            *) echo "        $f ^" >&2 ;;
        esac
    done
    echo "        -DWAMR_BUILD_TARGET=X86_64 -DWAMR_ROOT_DIR=." >&2
    echo "    cmake --build build --config Release" >&2
    echo >&2
    echo "Copy build\\Release\\vmlib.lib to vendor/wamr-dist-windows-x64/lib/libvmlib.a" >&2
    echo "and core/iwasm/include/*.h to vendor/wamr-dist-windows-x64/include/. A dist" >&2
    echo "directory is per platform and architecture, not per ABI: it holds whichever" >&2
    echo "of the two archives was written there last." >&2
}

if [ "${2:-}" = "--print-msvc" ]; then print_msvc_recipe; exit 0; fi
[ $# -le 1 ] || { echo "$usage" >&2; exit 2; }

for tool in git cmake; do
    command -v "$tool" >/dev/null 2>&1 || { echo "build-wamr.sh: $tool not found in PATH" >&2; exit 1; }
done

# The Apple SDKs are macOS-only. The cross targets are not: they need zig.
for t in "${targets[@]}"; do
    case "$t" in
        macos|ios|iossim)
            [ "$(uname -s)" = "Darwin" ] ||
                { echo "build-wamr.sh: target $t needs the Apple SDKs; this host is $(uname -s)" >&2; exit 1; }
            ;;
        *)
            command -v zig >/dev/null 2>&1 ||
                { echo "build-wamr.sh: zig not found in PATH, and it is the cross compiler for $t" >&2; exit 1; }
            ;;
    esac
done

ncpu() { sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4; }

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

# The NDK, for the android target's bionic headers. Same search as
# android/build-libs.sh: an explicit env var, then the highest ndk/<version>
# under a known SDK root.
find_ndk() {
    local d r v
    for d in "${ANDROID_NDK:-}" "${ANDROID_NDK_HOME:-}"; do
        [ -n "$d" ] && [ -d "$d" ] && { echo "$d"; return 0; }
    done
    for r in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" \
             "$HOME/Library/Android/sdk" "$HOME/Android/Sdk" \
             "/opt/homebrew/share/android-commandlinetools" \
             "/usr/local/share/android-commandlinetools"; do
        [ -n "$r" ] && [ -d "$r/ndk" ] || continue
        v="$(ls -1 "$r/ndk" 2>/dev/null | sort -V | tail -1)"
        [ -n "$v" ] && [ -d "$r/ndk/$v" ] && { echo "$r/ndk/$v"; return 0; }
    done
    return 1
}

# The NDK ships one host toolchain directory; the host-OS default comes first.
ndk_sysroot() {
    local h
    for h in darwin-x86_64 darwin-arm64 linux-x86_64 linux-aarch64; do
        if [ -d "$1/toolchains/llvm/prebuilt/$h/sysroot/usr/include" ]; then
            echo "$1/toolchains/llvm/prebuilt/$h/sysroot"; return 0
        fi
    done
    return 1
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

# One zig cross target, written as four one-line wrappers. cmake wants tools it
# can exec, not command lines with arguments in them. `zig ar` (llvm-ar) writes
# the archive: the host's ar cannot write an ELF or a COFF symbol index.
#   cross_toolchain <dir> <zig triple> [extra cc flags...]
cross_toolchain() {
    local dir="$1" triple="$2"
    shift 2
    mkdir -p "$dir"
    local extra=""
    local f
    for f in "$@"; do extra="$extra $(printf '%q' "$f")"; done
    printf '#!/bin/sh\nexec zig cc -target %s%s "$@"\n'  "$triple" "$extra" >"$dir/cc"
    printf '#!/bin/sh\nexec zig c++ -target %s%s "$@"\n' "$triple" "$extra" >"$dir/cxx"
    printf '#!/bin/sh\nexec zig ar "$@"\n'     >"$dir/ar"
    printf '#!/bin/sh\nexec zig ranlib "$@"\n' >"$dir/ranlib"
    chmod +x "$dir/cc" "$dir/cxx" "$dir/ar" "$dir/ranlib"
}

# A cross build must never hand back host objects. Read one member's machine.
verify_arch() {
    local archive="$1" want="$2" tmp member got
    tmp=$(mktemp -d)
    member=$(zig ar t "$archive" | head -1)
    ( cd "$tmp" && zig ar x "$archive" "$member" )
    got=$(file -b "$tmp/$member")
    rm -rf "$tmp"
    case "$got" in
        *"$want"*) echo "wamr: $member is $got" ;;
        *) echo "build-wamr.sh: $archive holds '$got', which is not '$want'" >&2; exit 1 ;;
    esac
}

build_one() {
    local t="$1"
    local dist build label sdk osx_arch wamr_target wamr_platform
    local triple="" check_arch="" ndk sysroot
    local -a platform_flags cc_flags
    platform_flags=()
    cc_flags=()

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
        linux-x64)
            dist="$root/vendor/wamr-dist-linux-x64"
            triple="x86_64-linux-gnu"; wamr_platform=linux; wamr_target=X86_64
            platform_flags=(-DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=x86_64)
            check_arch="ELF 64-bit LSB relocatable, x86-64"
            label="$triple"
            ;;
        linux-arm64)
            dist="$root/vendor/wamr-dist-linux-arm64"
            triple="aarch64-linux-gnu"; wamr_platform=linux; wamr_target=AARCH64
            platform_flags=(-DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=aarch64)
            check_arch="ELF 64-bit LSB relocatable, ARM aarch64"
            label="$triple"
            ;;
        windows-x64)
            dist="$root/vendor/wamr-dist-windows-x64"
            triple="x86_64-windows-gnu"; wamr_platform=windows; wamr_target=X86_64
            platform_flags=(-DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=AMD64)
            check_arch="amd64 COFF"
            label="$triple (mingw ABI)"
            ;;
        android-arm64)
            dist="$root/vendor/wamr-dist-android-arm64"
            triple="aarch64-linux-android.$ANDROID_API"; wamr_platform=android; wamr_target=AARCH64
            # CMAKE_SYSTEM_NAME stays Linux. Naming Android brings in cmake's
            # own NDK toolchain machinery, which then fights the compiler set
            # here. WAMR takes its platform layer from WAMR_BUILD_PLATFORM.
            platform_flags=(-DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=aarch64)
            check_arch="ELF 64-bit LSB relocatable, ARM aarch64"
            ndk="$(find_ndk)" || {
                echo "build-wamr.sh: Android NDK not found. Set ANDROID_NDK=/path/to/ndk/<version>" >&2
                echo "               (or install one: sdkmanager 'ndk;27.2.12479018')." >&2
                exit 1
            }
            sysroot="$(ndk_sysroot "$ndk")" || {
                echo "build-wamr.sh: no sysroot under $ndk/toolchains/llvm/prebuilt" >&2; exit 1
            }
            # zig carries no bionic headers. Hand it the NDK's, the way
            # build.zig's android libc file does for the Zig core.
            cc_flags=(-isystem "$sysroot/usr/include"
                      -isystem "$sysroot/usr/include/aarch64-linux-android")
            label="android arm64-v8a, API $ANDROID_API, NDK ${ndk##*/}"
            ;;
    esac

    if [ -f "$dist/lib/libvmlib.a" ] && [ -f "$dist/include/wasm_export.h" ]; then
        echo "wamr: ${dist#$root/} already built ($(cat "$dist/WAMR_VERSION" 2>/dev/null || echo unknown))"
        return 0
    fi

    ensure_src
    # One build directory per target, so the configurations do not overwrite
    # each other's cmake cache.
    build="$src/build-lookout-$t"

    if [ -n "$triple" ]; then
        cross_toolchain "$build/toolchain" "$triple" ${cc_flags[@]+"${cc_flags[@]}"}
        # CMAKE_TRY_COMPILE_TARGET_TYPE makes cmake's compiler probes compile
        # without linking. That is what lets android configure with no NDK link
        # libraries, and it keeps every probe off whatever libc zig would pick
        # for an executable.
        platform_flags+=(
            -DCMAKE_C_COMPILER="$build/toolchain/cc"
            -DCMAKE_CXX_COMPILER="$build/toolchain/cxx"
            -DCMAKE_AR="$build/toolchain/ar"
            -DCMAKE_RANLIB="$build/toolchain/ranlib"
            -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
            -DWAMR_BUILD_PLATFORM="$wamr_platform"
            -DWAMR_BUILD_TARGET="$wamr_target"
        )
    fi

    echo "wamr: configuring $t ($WAMR_TAG, $label, fast interpreter)"
    if ! cmake -S "$src/lookout-embed" -B "$build" \
        "${wamr_flags[@]}" "${platform_flags[@]}" \
        -DWAMR_ROOT_DIR="$src" \
        >"$build.log" 2>&1
    then
        cat "$build.log" >&2
        if [ "$t" = windows-x64 ]; then print_msvc_recipe; fi
        exit 1
    fi

    echo "wamr: building $t"
    if ! cmake --build "$build" --parallel "$(ncpu)" >>"$build.log" 2>&1; then
        tail -40 "$build.log" >&2
        if [ "$t" = windows-x64 ]; then print_msvc_recipe; fi
        exit 1
    fi

    if [ -n "$check_arch" ]; then verify_arch "$build/libvmlib.a" "$check_arch"; fi

    rm -rf "$dist"
    mkdir -p "$dist/lib" "$dist/include"
    cp "$build/libvmlib.a" "$dist/lib/libvmlib.a"
    cp "$src"/core/iwasm/include/*.h "$dist/include/"
    echo "$WAMR_TAG $WAMR_COMMIT $t" >"$dist/WAMR_VERSION"

    echo "wamr: ${dist#$root/}/lib/libvmlib.a ($(du -h "$dist/lib/libvmlib.a" | cut -f1)) from $WAMR_TAG"
}

for t in "${targets[@]}"; do build_one "$t"; done
