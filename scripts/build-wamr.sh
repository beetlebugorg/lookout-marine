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
#   windows-x64    vendor/wamr-dist-windows-x64/    MSVC ABI on Windows — see WINDOWS below
#   windows-arm64  vendor/wamr-dist-windows-arm64/  MSVC ABI — see WINDOWS below
#   android-arm64  vendor/wamr-dist-android-arm64/  arm64-v8a, NDK API 24
#
#   apple          macos ios iossim
#   all            every target above except windows-arm64, which only builds
#                  on an ARM64 Windows machine (it needs the installed MSVC
#                  headers and Windows SDK)
#
# And one target that is not a runtime archive at all:
#
#   wamrc          vendor/wamr-dist-wamrc/bin/wamrc  the AOT compiler
#
# Each runtime dist holds lib/libvmlib.a + include/*.h and is consumed by
# build.zig behind -Dplugins, which picks the directory from the target. All
# are gitignored (vendor/wamr-dist*/).
#
# WAMRC is the ahead-of-time compiler, and it is a BUILD-MACHINE TOOL: it is
# never shipped in any app, and `all` does not build it. It turns the five core
# plugins into .aot, one file per architecture, and scripts/build-plugin-aot.sh
# drives it. It is separate because it is the only thing here that needs LLVM
# (18.x, the release WAMR pins); see build_wamrc for how that is found.
#
# The Apple targets need Xcode and run on macOS only. The four cross targets
# need zig and cmake and nothing else: WAMR is plain C, so `zig cc -target ...`
# is the cross compiler and `zig ar` writes the archive. See cross_toolchain.
#
# WINDOWS. Both Windows targets build the MSVC ABI, and they run ON the Windows
# machine itself, under Git Bash, where `zig cc -target <arch>-windows-msvc`
# finds the installed MSVC headers and Windows SDK — the same way the core is
# built there (windows/build-core.ps1) — so the archive meets the core. On that
# host cmake is the native Windows build, which cannot exec the shell wrappers
# cross_toolchain writes elsewhere and defaults to the Visual Studio generator;
# see cross_toolchain and build_one for the .bat/Ninja variant.
#
# Off Windows there is no MSVC ABI to be had: no other host carries those
# headers. windows-x64 then cross-builds the mingw ABI (x86_64-windows-gnu),
# which serves a mingw build and does not meet the shipping app, and
# `scripts/build-wamr.sh windows-x64 --print-msvc` prints the cmake command to
# run on a Windows machine instead. A dist directory is per platform and
# architecture, not per ABI, so the two Windows x64 archives share one and the
# last one written wins. windows-arm64 has no cross form at all.
#
# Idempotent per target: returns at once when that archive, its headers and its
# WAMR_VERSION stamp all match what this script builds now. A dist from an older
# feature set is rebuilt, not reused. Force a rebuild anyway with
# `rm -rf vendor/wamr-dist-<target>`; force a re-clone with `rm -rf vendor/wamr`.
set -euo pipefail

# Pinned WAMR release. Tag and commit move together; the commit is verified
# after the clone so a moved tag cannot change what gets built.
WAMR_TAG="WAMR-2.4.5"
WAMR_COMMIT="25bd7eb63e828e4bd242cc9b38d260b4b31c6605"
WAMR_URL="https://github.com/bytecodealliance/wasm-micro-runtime"

# Written into <dist>/WAMR_VERSION and compared on the next run. It names the
# feature set, not the release: a dist built before libc-wasi went on holds a
# runtime that cannot instantiate a Go or Rust plugin, and it is otherwise
# indistinguishable from a current one. Bump this string whenever wamr_flags
# changes in a way a built archive cannot show.
WAMR_FEATURES="interp+aot+wasi"

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

usage="usage: ${BASH_SOURCE[0]##*/} [macos|ios|iossim|linux-x64|linux-arm64|windows-x64|windows-arm64|android-arm64|apple|all|wamrc] [--print-msvc]"
target="${1:-macos}"
case "$target" in
    macos|ios|iossim|linux-x64|linux-arm64|windows-x64|windows-arm64|android-arm64) targets=("$target") ;;
    apple) targets=(macos ios iossim) ;;
    # wamrc is NOT in `all`: it is a build-machine tool, it needs LLVM, and
    # nothing that ships contains it. windows-arm64 is not in `all` either:
    # it builds only on the ARM64 Windows machine (see WINDOWS above).
    all)   targets=(macos ios iossim linux-x64 linux-arm64 windows-x64 android-arm64) ;;
    wamrc) targets=(wamrc) ;;
    *) echo "$usage" >&2; exit 2 ;;
esac

# Feature set for the prototype host. Identical on every target — the fast
# interpreter runs everywhere and is what makes iOS work at all.
#   * fast interpreter, plus the AOT LOADER, and no JIT of either flavour.
#     The interpreter is what runs every module by default and the only thing
#     that runs a third-party one; the AOT loader is here so the five core
#     plugins can be shipped as native code we compiled ourselves at build
#     time (scripts/build-plugin-aot.sh). Turning it on costs the aot/ loader
#     and relocation sources in the archive — about 200 KiB — and buys nothing
#     unless an .aot is actually present, because a plugin without one is
#     interpreted exactly as before.
#     NO JIT: Fast JIT is x86-64 only in this release and LLVM JIT would mean
#     bundling LLVM in the app. The AOT compiler runs on the BUILD machine.
#     ON iOS the loader is compiled in for one reason only — to keep the flag
#     matrix identical on every target — and shipping an iOS .aot is NOT
#     proven: the AOT text section is mapped MAP_JIT/PROT_EXEC, which an App
#     Store app cannot do. iOS runs the interpreter.
#   * libc-wasi ON, and it is a LANGUAGE FLOOR, not a capability surface. The
#     Go and Rust standard libraries do not boot without wasi_snapshot_preview1
#     resolving, so the runtime has to answer it. What a plugin can reach
#     through it is decided in src/plugin/wasm.zig, not here: zero filesystem
#     preopens, no argv, no environment, stdio backed by the null device, and
#     an override table that turns fd_write into a log line, refuses sock_open
#     and bounds the poll_oneoff sleep. Real I/O stays behind the `lookout`
#     import module. Zig plugins are still wasm32-freestanding and import none
#     of this; WASI is additive.
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
#   * hardware bound check OFF: this one now binds the AOT compiler too. See
#     AOT_FLAGS in scripts/build-plugin-aot.sh — an .aot compiled with wamrc's
#     default --bounds-checks=0 assumes the runtime traps out-of-range
#     accesses in a signal handler, and this runtime installs none, so every
#     core .aot is compiled with --bounds-checks=1. The reason the flag is off:
#     the alternative is WAMR installing
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
    -DWAMR_BUILD_AOT=1
    -DWAMR_BUILD_JIT=0
    -DWAMR_BUILD_FAST_JIT=0
    -DWAMR_BUILD_LIBC_BUILTIN=1
    -DWAMR_BUILD_LIBC_WASI=1
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
    echo "is not on this host. In a Visual Studio x64 Native Tools Command Prompt:" >&2
    echo >&2
    echo "x64 ONLY. The ARM64 Windows archive is not built this way: run" >&2
    echo "\`bash scripts/build-wamr.sh windows-arm64\` on the ARM64 Windows machine" >&2
    echo "itself, where zig cc targets the MSVC ABI directly and the archive lands" >&2
    echo "in vendor/wamr-dist-windows-arm64." >&2
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
    echo "        -DWAMR_BUILD_TARGET=X86_64 -DWAMR_ROOT_DIR=. ^" >&2
    echo "        -DCMAKE_C_FLAGS=\"/DWASM_API_EXTERN= /DWASM_RUNTIME_API_EXTERN=\"" >&2
    echo "    cmake --build build --config Release" >&2
    echo >&2
    echo "The two empty macros are required, not tidiness: under MSVC the WAMR" >&2
    echo "headers declare their API __declspec(dllimport), WAMR's own TUs then" >&2
    echo "reference __imp_wasm_runtime_begin_blocking_op, __imp_wasm_trap_delete" >&2
    echo "and __imp_wasm_runtime_end_blocking_op, and a static archive has no" >&2
    echo "import library to resolve them — the app's link ends in LNK2019. The" >&2
    echo "same holds for __imp_wasm_runtime_malloc and __imp_wasm_runtime_free," >&2
    echo "declared in core/shared/platform/include/platform_common.h behind no" >&2
    echo "overridable macro at all: see fix_msvc_dll_attrs in this script, which" >&2
    echo "adds the WASM_RUNTIME_STATIC_API escape the windows-arm64 target uses." >&2
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
        # wamrc is a native host tool. It needs a C++ compiler and LLVM, not zig.
        wamrc) ;;
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

# A defect in the pinned tree, in a file only libc-wasi compiles. Three comment
# lines in core/shared/platform/windows/win_file.c end with a backslash and a
# trailing space. clang splices the next source line into the comment and the
# code after it stops parsing:
#
#     win_file.c:1300:20: error: expected identifier
#
# MSVC does not splice across the space, so upstream never sees it; the mingw
# cross build here is clang and does. Nothing depended on this file before
# libc-wasi went on, which is why the Windows target built until now.
#
# The fix puts one character after the backslash so the line no longer ends in
# one. It is a comment, so the character is arbitrary. Idempotent, and re-applied
# after every clone.
fix_win_file_comments() {
    local f="$src/core/shared/platform/windows/win_file.c"
    [ -f "$f" ] || return 0
    grep -q '//.*\\[[:space:]]\+$' "$f" || return 0
    echo "wamr: patching trailing backslashes in ${f#$src/} (see fix_win_file_comments)"
    # Through a temporary rather than sed -i: the two seds spell that flag
    # differently, and the Linux host that cross-builds these targets has the
    # other one.
    sed -E 's,(//.*\\)[[:space:]]+$,\1.,' "$f" >"$f.lookout-tmp" && mv "$f.lookout-tmp" "$f"
}

# A second defect in the pinned tree, hit only by the windows-arm64 target.
# invokeNative_aarch64.s marks its symbol with the ELF `.type` directive, which
# LLVM's COFF assembler rejects ("expected absolute expression"). The file's
# own #ifndef lines are comments to an unpreprocessed GAS parse — `#` opens a
# line comment on aarch64 — so on ELF targets nothing changes when the
# directive gains a preprocessor guard. The windows-arm64 target assembles the
# file WITH the preprocessor (-x assembler-with-cpp in its as.bat wrapper, see
# cross_toolchain), where BH_PLATFORM_WINDOWS is on the command line and the
# guard excludes the directive. Idempotent, re-applied after every clone.
fix_invoke_native_type() {
    local f="$src/core/iwasm/common/arch/invokeNative_aarch64.s"
    [ -f "$f" ] || return 0
    grep -q 'BH_PLATFORM_WINDOWS' "$f" && return 0
    echo "wamr: guarding the ELF .type directive in ${f#$src/} (see fix_invoke_native_type)"
    sed -e 's|^\([[:space:]]*\)\(\.type[[:space:]][[:space:]]*invokeNative.*\)$|#ifndef BH_PLATFORM_WINDOWS\n\1\2\n#endif|' \
        "$f" >"$f.lookout-tmp" && mv "$f.lookout-tmp" "$f"
}

# The third defect, and the same disease as the two empty EXTERN macros the
# windows-arm64 target passes (see its cc_flags). platform_common.h declares
# BH_MALLOC and BH_FREE — which are wasm_runtime_malloc and wasm_runtime_free —
# __declspec(dllimport) under _MSC_BUILD, and that declaration is behind NO
# macro a command line can override: the only escape upstream offers is
# COMPILING_WASM_RUNTIME_API, whose other branch is dllexport, which would
# export runtime symbols from whatever binary links the archive. Eleven members
# of the archive (bh_common, win_thread, str, ...) reference
# __imp_wasm_runtime_malloc without it, and a static archive has no import
# library, so the app's link fails.
#
# The patch gives that block the override it lacks. WASM_RUNTIME_STATIC_API is
# this project's macro, defined only by the windows-arm64 cc_flags; with it the
# declarations are the plain ones every non-MSVC target already uses.
# Idempotent, re-applied after every clone.
fix_msvc_dll_attrs() {
    local f="$src/core/shared/platform/include/platform_common.h"
    [ -f "$f" ] || return 0
    grep -q 'WASM_RUNTIME_STATIC_API' "$f" && return 0
    echo "wamr: adding the WASM_RUNTIME_STATIC_API escape to ${f#$src/} (see fix_msvc_dll_attrs)"
    sed -e 's|^#if defined(_MSC_BUILD)$|#if defined(_MSC_BUILD) \&\& !defined(WASM_RUNTIME_STATIC_API)|' \
        "$f" >"$f.lookout-tmp" && mv "$f.lookout-tmp" "$f"
}

# The fourth defect, and the one that decides whether the runtime WORKS.
# wasm_runtime_invoke_native marshals a wasm call's arguments into the layout
# the arch's invokeNative assembly reads, and it picks that layout from _WIN32
# ALONE:
#
#     #if defined(_WIN32) || defined(_WIN32_)
#     #define MAX_REG_FLOATS 4          <- the Win64 x86-64 convention
#     #define MAX_REG_INTS 4
#     ...
#     #define n_fps n_ints              <- and its SHARED register index
#
# That is x86-64's calling convention, not the machine's. Windows on ARM64
# follows AAPCS64 like every other aarch64 platform: eight integer registers
# (x0-x7) and eight floating ones (d0-d7), indexed SEPARATELY — which is
# exactly what core/iwasm/common/arch/invokeNative_aarch64.s reads, argv[0..7]
# into d0-d7 and argv[8..15] into x0-x7. With the Windows numbers the
# marshaller writes exec_env into argv[4] and the assembly reads x0 from
# argv[8], so EVERY native receives zeros: the first one dereferences a NULL
# exec_env and the process dies with an access violation inside the first
# plugin's lk_start. Upstream never sees this because WAMR ships no Windows
# ARM64 support at all.
#
# The patch excludes aarch64 from both Windows branches, which puts this target
# on the AAPCS64 path the assembly already implements. It cannot reach any
# other target: both edits are guarded by BUILD_TARGET_AARCH64, which only an
# aarch64 build defines, and the Windows branches only a _WIN32 one takes.
# Idempotent, re-applied after every clone.
fix_win_arm64_native_abi() {
    local f="$src/core/iwasm/common/wasm_runtime_common.c"
    [ -f "$f" ] || return 0
    grep -q '!defined(BUILD_TARGET_AARCH64)' "$f" && return 0
    echo "wamr: giving Windows aarch64 the AAPCS64 native-call layout in ${f#$src/} (see fix_win_arm64_native_abi)"
    awk '
      # The MAX_REG_FLOATS/MAX_REG_INTS block: identified by the line after it,
      # so the identical-looking #if above the SIMD v128 typedef is left alone.
      /^#if defined\(_WIN32\) \|\| defined\(_WIN32_\)$/ {
          keep = $0
          if ((getline nxt) > 0) {
              if (nxt == "#define MAX_REG_FLOATS 4")
                  print "#if (defined(_WIN32) || defined(_WIN32_)) && !defined(BUILD_TARGET_AARCH64)"
              else
                  print keep
              print nxt
              next
          }
          print keep
          next
      }
      # The n_fps/n_ints aliasing: one shared argument index is x86-64 too.
      /^#if defined\(_WIN32\) \|\| defined\(_WIN32_\) \|\| defined\(BUILD_TARGET_RISCV64_LP64\)$/ {
          print "#if ((defined(_WIN32) || defined(_WIN32_)) && !defined(BUILD_TARGET_AARCH64)) || defined(BUILD_TARGET_RISCV64_LP64)"
          next
      }
      { print }
    ' "$f" >"$f.lookout-tmp" && mv "$f.lookout-tmp" "$f"
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

    fix_win_file_comments
    fix_invoke_native_type
    fix_msvc_dll_attrs
    fix_win_arm64_native_abi

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

# A Windows host (Git Bash driving the native Windows cmake) needs three
# accommodations that a POSIX host does not: the wrapper tools must be .bat
# files because the native cmake execs through CreateProcess, which runs a
# batch file but not a shebang script; every path handed to cmake must be a
# Windows one; and a generator must be named, because the Windows default is
# Visual Studio, which ignores CMAKE_C_COMPILER entirely.
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) host_windows=1 ;;
    *) host_windows="" ;;
esac
tool_ext=""; [ -n "$host_windows" ] && tool_ext=".bat"

# A path as the native cmake wants it: C:/... with forward slashes on the
# Windows host, unchanged elsewhere.
cmpath() {
    if [ -n "$host_windows" ]; then cygpath -m "$1"; else echo "$1"; fi
}

# The Windows SDK's rc.exe, for the Windows host. cmake's Windows-Clang
# platform file insists on an RC compiler even for a static library that
# compiles no .rc file, so the tool is named but never runs. Newest SDK,
# host-arch flavour first.
find_rc() {
    local arch d
    for arch in arm64 x64 x86; do
        for d in "/c/Program Files (x86)/Windows Kits/10/bin"/10.*; do
            [ -x "$d/$arch/rc.exe" ] && echo "$d/$arch/rc.exe"
        done | sort -V | tail -1 | grep . && return 0
    done
    return 1
}

# MSVC's MASM, for the Windows host. runtime_lib.cmake enables ASM_MASM
# whenever the platform is windows; the AARCH64 build compiles no .asm file
# through it (invokeNative is the GAS-syntax .s, via zig cc), but the language
# still has to enable, and left to itself cmake goes looking for a bare `ml`
# that is not on PATH. Any real MASM binary satisfies it.
find_masm() {
    local d a
    for d in "/c/Program Files/Microsoft Visual Studio"/*/*/VC/Tools/MSVC/*/bin/Hostarm64/arm64 \
             "/c/Program Files/Microsoft Visual Studio"/*/*/VC/Tools/MSVC/*/bin/Hostx64/x64; do
        for a in ml64.exe armasm64.exe; do
            [ -x "$d/$a" ] && { echo "$d/$a"; return 0; }
        done
    done
    return 1
}

# ninja for the Windows host. PATH first; Visual Studio ships one with its
# cmake component, and this machine builds the shell with VS anyway.
find_ninja() {
    command -v ninja >/dev/null 2>&1 && { echo ninja; return 0; }
    local n
    for n in "/c/Program Files/Microsoft Visual Studio"/*/*/Common7/IDE/CommonExtensions/Microsoft/CMake/Ninja/ninja.exe; do
        [ -x "$n" ] && { cygpath -m "$n"; return 0; }
    done
    return 1
}

# One zig cross target, written as four one-line wrappers. cmake wants tools it
# can exec, not command lines with arguments in them. `zig ar` (llvm-ar) writes
# the archive: the host's ar cannot write an ELF or a COFF symbol index.
# On the Windows host the wrappers are .bat files (see above).
#   cross_toolchain <dir> <zig triple> [extra cc flags...]
cross_toolchain() {
    local dir="$1" triple="$2"
    shift 2
    mkdir -p "$dir"
    local extra=""
    local f
    if [ -n "$host_windows" ]; then
        local zigexe
        zigexe="$(cygpath -w "$(command -v zig)")"
        for f in "$@"; do extra="$extra $f"; done
        printf '@"%s" cc -target %s%s %%*\r\n'  "$zigexe" "$triple" "$extra" >"$dir/cc.bat"
        printf '@"%s" c++ -target %s%s %%*\r\n' "$zigexe" "$triple" "$extra" >"$dir/cxx.bat"
        # The assembler runs the preprocessor, so the #if guards inside WAMR's
        # .s files (invokeNative_aarch64.s) are real here — that is what keeps
        # the ELF-only .type directive away from the COFF assembler (see
        # fix_invoke_native_type).
        printf '@"%s" cc -target %s%s -x assembler-with-cpp %%*\r\n' "$zigexe" "$triple" "$extra" >"$dir/as.bat"
        printf '@"%s" ar %%*\r\n'     "$zigexe" >"$dir/ar.bat"
        printf '@"%s" ranlib %%*\r\n' "$zigexe" >"$dir/ranlib.bat"
        return 0
    fi
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
    # What cmake names the archive it builds. Every dist stores it as
    # lib/libvmlib.a whatever it was called; on the MSVC-ABI target cmake's
    # Windows naming produces vmlib.lib.
    local built="libvmlib.a"
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
            wamr_platform=windows; wamr_target=X86_64
            platform_flags=(-DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=AMD64)
            if [ -n "$host_windows" ]; then
                # On the Windows machine itself zig cc resolves
                # -target x86_64-windows-msvc against the installed MSVC headers
                # and Windows SDK, exactly as windows/build-core.ps1 builds the
                # core there, so this archive meets it. The DLL macros are the
                # windows-arm64 case's, and not cosmetic: see it for why.
                triple="x86_64-windows-msvc"
                built="vmlib.lib"
                # Git Bash's `file` names this machine differently from the
                # `file` on the hosts that cross-build the mingw archive.
                check_arch="x86-64 COFF"
                cc_flags=(-DWASM_API_EXTERN= -DWASM_RUNTIME_API_EXTERN= -DWASM_RUNTIME_STATIC_API)
                label="$triple (MSVC ABI)"
            else
                # Elsewhere zig cross-compiles, and the MSVC ABI is out of
                # reach: no host carries those headers. The mingw archive
                # serves a mingw build and does not meet the shipping app.
                triple="x86_64-windows-gnu"
                check_arch="amd64 COFF"
                label="$triple (mingw ABI)"
            fi
            ;;
        windows-arm64)
            # MSVC ABI, and only on the ARM64 Windows machine itself: zig cc
            # resolves -target aarch64-windows-msvc against the installed MSVC
            # headers and Windows SDK, which is exactly how the core is built
            # there (windows/build-core.ps1). On any other host the compiler
            # probe fails for want of those headers, and that is correct.
            [ -n "$host_windows" ] || {
                echo "build-wamr.sh: windows-arm64 builds the MSVC ABI against the installed" >&2
                echo "               MSVC headers and Windows SDK, so it runs only on the" >&2
                echo "               Windows machine itself (under Git Bash)." >&2
                exit 1
            }
            dist="$root/vendor/wamr-dist-windows-arm64"
            triple="aarch64-windows-msvc"; wamr_platform=windows; wamr_target=AARCH64
            platform_flags=(-DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=ARM64)
            check_arch="ARM64 COFF"
            built="vmlib.lib"
            # THE DLL MACROS, AND THEY ARE NOT COSMETIC. wasm_export.h and
            # wasm_c_api.h expand their EXTERN macro to __declspec(dllimport)
            # whenever _MSC_BUILD is defined and WAMR's own "I am building the
            # runtime" macro is not — and clang defines _MSC_BUILD for
            # aarch64-windows-msvc. WAMR's own TUs then call three of its
            # functions through __imp_*, and a STATIC archive has no import
            # library behind those symbols, so the shell's link ends in
            #   LNK2019 unresolved __imp_wasm_runtime_begin_blocking_op
            #   LNK2019 unresolved __imp_wasm_runtime_end_blocking_op
            #   LNK2019 unresolved __imp_wasm_trap_delete
            # Both headers guard the macro with #ifndef, so defining each one
            # empty on the command line makes every declaration a plain
            # extern — which is what a static library wants. dllexport would
            # also resolve them, but it would additionally export the whole
            # runtime API from any DLL that links this archive.
            # WASM_RUNTIME_STATIC_API belongs to fix_msvc_dll_attrs above and
            # closes the same hole in platform_common.h, which no upstream
            # macro can reach.
            cc_flags=(-DWASM_API_EXTERN= -DWASM_RUNTIME_API_EXTERN= -DWASM_RUNTIME_STATIC_API)
            label="$triple (MSVC ABI)"
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

    local stamp="$WAMR_TAG $WAMR_COMMIT $WAMR_FEATURES $t"
    if [ -f "$dist/lib/libvmlib.a" ] && [ -f "$dist/include/wasm_export.h" ]; then
        local have
        have=$(cat "$dist/WAMR_VERSION" 2>/dev/null || echo unknown)
        if [ "$have" = "$stamp" ]; then
            echo "wamr: ${dist#$root/} already built ($have)"
            return 0
        fi
        echo "wamr: ${dist#$root/} is '$have', this script builds '$stamp' — rebuilding"
        rm -rf "$dist"
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
            -DCMAKE_C_COMPILER="$(cmpath "$build/toolchain/cc$tool_ext")"
            -DCMAKE_CXX_COMPILER="$(cmpath "$build/toolchain/cxx$tool_ext")"
            -DCMAKE_AR="$(cmpath "$build/toolchain/ar$tool_ext")"
            -DCMAKE_RANLIB="$(cmpath "$build/toolchain/ranlib$tool_ext")"
            -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
            -DWAMR_BUILD_PLATFORM="$wamr_platform"
            -DWAMR_BUILD_TARGET="$wamr_target"
        )
        if [ -n "$host_windows" ]; then
            # The Windows default generator is Visual Studio, which picks its
            # own compiler; Ninja obeys the one set above. The .s files go
            # through the as.bat zig cc wrapper (cc plus the preprocessor) —
            # left unset, cmake would go hunting for an assembler of its own.
            local ninja_exe rc_exe masm_exe
            ninja_exe="$(find_ninja)" || {
                echo "build-wamr.sh: no ninja found (PATH or a Visual Studio cmake component)" >&2
                exit 1
            }
            rc_exe="$(find_rc)" || {
                echo "build-wamr.sh: no Windows SDK rc.exe found under 'Windows Kits/10/bin'" >&2
                exit 1
            }
            masm_exe="$(find_masm)" || {
                echo "build-wamr.sh: no MASM (ml64.exe/armasm64.exe) found under the VS MSVC tools" >&2
                exit 1
            }
            platform_flags+=(
                -G Ninja
                -DCMAKE_MAKE_PROGRAM="$ninja_exe"
                -DCMAKE_ASM_COMPILER="$(cmpath "$build/toolchain/as$tool_ext")"
                -DCMAKE_RC_COMPILER="$(cmpath "$rc_exe")"
                -DCMAKE_ASM_MASM_COMPILER="$(cmpath "$masm_exe")"
            )
        fi
    fi

    echo "wamr: configuring $t ($WAMR_TAG, $label, fast interpreter)"
    if ! cmake -S "$(cmpath "$src/lookout-embed")" -B "$(cmpath "$build")" \
        "${wamr_flags[@]}" "${platform_flags[@]}" \
        -DWAMR_ROOT_DIR="$(cmpath "$src")" \
        >"$build.log" 2>&1
    then
        cat "$build.log" >&2
        if [ "$t" = windows-x64 ] && [ -z "$host_windows" ]; then print_msvc_recipe; fi
        exit 1
    fi

    echo "wamr: building $t"
    if ! cmake --build "$(cmpath "$build")" --parallel "$(ncpu)" >>"$build.log" 2>&1; then
        tail -40 "$build.log" >&2
        if [ "$t" = windows-x64 ] && [ -z "$host_windows" ]; then print_msvc_recipe; fi
        exit 1
    fi

    if [ -n "$check_arch" ]; then verify_arch "$build/$built" "$check_arch"; fi

    rm -rf "$dist"
    mkdir -p "$dist/lib" "$dist/include"
    cp "$build/$built" "$dist/lib/libvmlib.a"
    cp "$src"/core/iwasm/include/*.h "$dist/include/"
    echo "$stamp" >"$dist/WAMR_VERSION"

    echo "wamr: ${dist#$root/}/lib/libvmlib.a ($(du -h "$dist/lib/libvmlib.a" | cut -f1)) from $WAMR_TAG"
}

# ---- wamrc, the AOT compiler ----
#
# LLVM. wamr-compiler/CMakeLists.txt takes one of two paths. Left alone it
# insists on core/deps/llvm/build — WAMR's own from-source LLVM, which
# build-scripts/build_llvm.py clones (release/18.x) and configures with five
# backends. That build is tens of GB of objects and the better part of an hour
# even on an idle machine, and it produces nothing a release LLVM does not
# already have. With WAMR_BUILD_WITH_CUSTOM_LLVM=1 the file drops straight to
# `find_package(LLVM CONFIG)`, so ANY LLVM install with its cmake package is
# enough — a Homebrew keg, a distribution's llvm-18-dev, an SDK's.
#
# THE VERSION IS NOT FREE. WAMR 2.4.5 pins release/18.x and means it: on
# LLVM 21 this tree fails to compile, because aot_llvm.c calls
# LLVMOrcThreadSafeContextGetContext, which that release removed from the C
# API. 18 builds clean. find_llvm therefore looks for 18 by name and says so
# when it cannot find one, rather than picking up whatever llvm-config is
# first in PATH and failing 90 seconds later inside a compile.
find_llvm() {
    local d
    # An explicit LLVM_DIR wins, whatever version it is: someone who sets it
    # has a reason, and cmake will report the version it found.
    if [ -n "${LLVM_DIR:-}" ] && [ -f "$LLVM_DIR/LLVMConfig.cmake" ]; then
        echo "$LLVM_DIR"; return 0
    fi
    for d in /opt/homebrew/opt/llvm@18 /usr/local/opt/llvm@18 /usr/lib/llvm-18 \
             /opt/homebrew/opt/llvm /usr/local/opt/llvm; do
        [ -f "$d/lib/cmake/llvm/LLVMConfig.cmake" ] || continue
        # Only take an unversioned prefix if it happens to BE 18.
        case "$d" in
            *@18|*llvm-18) echo "$d/lib/cmake/llvm"; return 0 ;;
            *) [ -x "$d/bin/llvm-config" ] &&
               case "$("$d/bin/llvm-config" --version 2>/dev/null)" in
                   18.*) echo "$d/lib/cmake/llvm"; return 0 ;;
               esac ;;
        esac
    done
    return 1
}

build_wamrc() {
    local dist="$root/vendor/wamr-dist-wamrc"
    local build="$src/build-lookout-wamrc"
    local stamp="$WAMR_TAG $WAMR_COMMIT wamrc"
    local llvm_dir

    if [ -x "$dist/bin/wamrc" ]; then
        local have
        have=$(cat "$dist/WAMR_VERSION" 2>/dev/null || echo unknown)
        if [ "$have" = "$stamp" ]; then
            echo "wamr: ${dist#$root/} already built ($have)"
            return 0
        fi
        echo "wamr: ${dist#$root/} is '$have', this script builds '$stamp' — rebuilding"
        rm -rf "$dist" "$build"
    fi

    llvm_dir="$(find_llvm)" || {
        echo "build-wamr.sh: no LLVM 18 with a cmake package found, and wamrc needs one." >&2
        echo "               WAMR $WAMR_TAG pins LLVM release/18.x; 21 does not compile" >&2
        echo "               (LLVMOrcThreadSafeContextGetContext is gone from its C API)." >&2
        echo >&2
        echo "               macOS:  brew install llvm@18            (~1.8 GB installed)" >&2
        echo "               Debian: apt install llvm-18-dev" >&2
        echo "               Or point at one you have: LLVM_DIR=/path/to/lib/cmake/llvm" >&2
        echo >&2
        echo "               The from-source route WAMR ships —" >&2
        echo "               vendor/wamr/wamr-compiler/build_llvm.sh — is the same release" >&2
        echo "               built with five backends, and wants tens of GB and the better" >&2
        echo "               part of an hour. A release LLVM is the same compiler." >&2
        exit 1
    }

    ensure_src
    echo "wamr: configuring wamrc ($WAMR_TAG, LLVM at ${llvm_dir})"
    if ! cmake -S "$src/wamr-compiler" -B "$build" \
        -DCMAKE_BUILD_TYPE=Release \
        -DWAMR_BUILD_WITH_CUSTOM_LLVM=1 \
        -DLLVM_DIR="$llvm_dir" \
        -DWAMR_BUILD_PLATFORM="$(uname -s | tr '[:upper:]' '[:lower:]')" \
        >"$build.log" 2>&1
    then
        cat "$build.log" >&2
        exit 1
    fi
    grep -E "^-- Found LLVM " "$build.log" || true

    echo "wamr: building wamrc"
    if ! cmake --build "$build" --parallel "$(ncpu)" >>"$build.log" 2>&1; then
        tail -40 "$build.log" >&2
        exit 1
    fi

    rm -rf "$dist"
    mkdir -p "$dist/bin"
    # cmake writes wamrc-<version> and a `wamrc` symlink beside it. Copy the
    # real file under the plain name, so the dist holds no dangling link.
    local bin="$build/wamrc"
    [ -L "$bin" ] && bin="$build/$(readlink "$bin")"
    cp "$bin" "$dist/bin/wamrc"
    chmod +x "$dist/bin/wamrc"
    echo "$stamp" >"$dist/WAMR_VERSION"

    echo "wamr: ${dist#$root/}/bin/wamrc ($("$dist/bin/wamrc" --version), $(du -h "$dist/bin/wamrc" | cut -f1))"
}

for t in "${targets[@]}"; do
    if [ "$t" = wamrc ]; then build_wamrc; else build_one "$t"; fi
done
