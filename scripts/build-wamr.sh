#!/usr/bin/env bash
# Build WAMR (wasm-micro-runtime) as a static archive for the plugin host.
#
# Output: vendor/wamr-dist/lib/libvmlib.a + vendor/wamr-dist/include/*.h,
# consumed by build.zig behind -Dplugins. Both vendor dirs are gitignored.
#
# Idempotent: returns at once when the archive and headers are already there.
# Force a rebuild with `rm -rf vendor/wamr-dist`; force a re-clone with
# `rm -rf vendor/wamr`.
set -euo pipefail

# Pinned WAMR release. Tag and commit move together; the commit is verified
# after the clone so a moved tag cannot change what gets built.
WAMR_TAG="WAMR-2.4.5"
WAMR_COMMIT="25bd7eb63e828e4bd242cc9b38d260b4b31c6605"
WAMR_URL="https://github.com/bytecodealliance/wasm-micro-runtime"

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
src="$root/vendor/wamr"
dist="$root/vendor/wamr-dist"
build="$src/build-lookout"

if [ -f "$dist/lib/libvmlib.a" ] && [ -f "$dist/include/wasm_export.h" ]; then
    echo "wamr: vendor/wamr-dist already built ($(cat "$dist/WAMR_VERSION" 2>/dev/null || echo unknown))"
    exit 0
fi

if [ "$(uname -s)" != "Darwin" ]; then
    echo "build-wamr.sh: the plugin prototype targets macOS only; this host is $(uname -s)" >&2
    exit 1
fi

for tool in git cmake; do
    command -v "$tool" >/dev/null 2>&1 || { echo "build-wamr.sh: $tool not found in PATH" >&2; exit 1; }
done

case "$(uname -m)" in
    arm64|aarch64) wamr_target="AARCH64"; osx_arch="arm64" ;;
    x86_64)        wamr_target="X86_64";  osx_arch="x86_64" ;;
    *) echo "build-wamr.sh: unsupported host arch $(uname -m)" >&2; exit 1 ;;
esac

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

# Feature set for the prototype host:
#   * fast interpreter only — no AOT, no JIT of either flavour (iOS/AOT is out
#     of scope this branch, and the interpreter is the portable floor).
#   * no WASI: plugins are wasm32-freestanding and reach the outside world
#     only through the `lookout` import module.
#   * libc-builtin ON: the small printf/memory builtins a module may import.
#   * bulk memory, reference types and extended const expressions ON because
#     the Zig wasm32 default CPU (lime1) emits them; SIMD, tail call, GC,
#     memory64, multi-memory and threads stay off — nothing emits them and
#     each one costs loader and interpreter code.
#   * PIC: the archive is linked into liblookout_marine.a and from there into
#     app binaries.
# 13.0 matches Zig's default macOS minimum, so ld64 raises no version warning.
echo "wamr: configuring ($WAMR_TAG, $wamr_target, fast interpreter)"
cmake -S "$src/lookout-embed" -B "$build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_OSX_ARCHITECTURES="$osx_arch" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DWAMR_ROOT_DIR="$src" \
    -DWAMR_BUILD_PLATFORM=darwin \
    -DWAMR_BUILD_TARGET="$wamr_target" \
    -DWAMR_BUILD_INTERP=1 \
    -DWAMR_BUILD_FAST_INTERP=1 \
    -DWAMR_BUILD_AOT=0 \
    -DWAMR_BUILD_JIT=0 \
    -DWAMR_BUILD_FAST_JIT=0 \
    -DWAMR_BUILD_LIBC_BUILTIN=1 \
    -DWAMR_BUILD_LIBC_WASI=0 \
    -DWAMR_BUILD_LIBC_UVWASI=0 \
    -DWAMR_BUILD_LIB_PTHREAD=0 \
    -DWAMR_BUILD_LIB_WASI_THREADS=0 \
    -DWAMR_BUILD_THREAD_MGR=0 \
    -DWAMR_BUILD_MULTI_MODULE=0 \
    -DWAMR_BUILD_SHARED_MEMORY=0 \
    -DWAMR_BUILD_BULK_MEMORY=1 \
    -DWAMR_BUILD_REF_TYPES=1 \
    -DWAMR_BUILD_EXTENDED_CONST_EXPR=1 \
    -DWAMR_BUILD_SIMD=0 \
    -DWAMR_BUILD_TAIL_CALL=0 \
    -DWAMR_BUILD_GC=0 \
    -DWAMR_BUILD_MEMORY64=0 \
    -DWAMR_BUILD_MULTI_MEMORY=0 \
    -DWAMR_BUILD_MINI_LOADER=0 \
    -DWAMR_BUILD_DEBUG_INTERP=0 \
    >"$build.log" 2>&1 || { cat "$build.log" >&2; exit 1; }

echo "wamr: building"
cmake --build "$build" --parallel "$(sysctl -n hw.ncpu)" >>"$build.log" 2>&1 ||
    { tail -40 "$build.log" >&2; exit 1; }

rm -rf "$dist"
mkdir -p "$dist/lib" "$dist/include"
cp "$build/libvmlib.a" "$dist/lib/libvmlib.a"
cp "$src"/core/iwasm/include/*.h "$dist/include/"
echo "$WAMR_TAG $WAMR_COMMIT" >"$dist/WAMR_VERSION"

echo "wamr: vendor/wamr-dist/lib/libvmlib.a ($(du -h "$dist/lib/libvmlib.a" | cut -f1)) from $WAMR_TAG"
