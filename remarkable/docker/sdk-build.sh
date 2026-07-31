#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2024-2026 Jeremy Collins <jeremy.collins@beetlebug.org>
# SPDX-License-Identifier: MIT
#
# Runs INSIDE docker/Dockerfile.sdk, which holds the reMarkable SDK at
# /opt/rm-sdk. Cross-compiles the Qt shell against the device's own Qt and links
# it to the chart core mounted read-only at /core, producing a bare epaper
# binary at /work/build-<device>-sdk/lookout-marine.
#
# The core itself is NOT built here — `make core` cross-builds it with Zig on the
# host first, which needs no toolchain and no container.
#
#   /work/docker/sdk-build.sh rm2
set -euo pipefail

DEVICE="${1:-rm2}"

echo "== [1/2] activate the reMarkable SDK =="
[ -f /core/include/lookout.h ] || {
    echo "no chart core at /core — run 'make core' on the host first" >&2
    exit 2
}
env_setup="$(find /opt/rm-sdk -maxdepth 3 -name 'environment-setup-*' | head -n1 || true)"
[ -n "$env_setup" ] || { echo "no SDK environment-setup script under /opt/rm-sdk" >&2; exit 1; }
echo "   $env_setup"
# shellcheck disable=SC1090
source "$env_setup"

echo "== [2/2] cross-compile the shell against the device Qt =="
BUILD="/work/build-${DEVICE}-sdk"
# The build dir persists between runs so Ninja rebuilds only what changed.
# `make clean` wipes it; CLEAN=1 forces a from-scratch configure.
[ "${CLEAN:-0}" = "1" ] && rm -rf "$BUILD"
OE_TOOLCHAIN="${OECORE_NATIVE_SYSROOT:-}/usr/share/cmake/OEToolchainConfig.cmake"

args=( -S /work -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release
       -DLOOKOUT_ROOT=/core )
if [ -f "$OE_TOOLCHAIN" ]; then
    echo "   using the SDK's OE toolchain: $OE_TOOLCHAIN"
    args+=( -DCMAKE_TOOLCHAIN_FILE="$OE_TOOLCHAIN" )
else
    echo "   OE toolchain not found; using cmake/remarkable.toolchain.cmake"
    : "${SDKTARGETSYSROOT:?the SDK environment did not set SDKTARGETSYSROOT}"
    args+=( -DCMAKE_TOOLCHAIN_FILE=/work/cmake/remarkable.toolchain.cmake
            -DREMARKABLE_DEVICE="$DEVICE" -DREMARKABLE_SYSROOT="$SDKTARGETSYSROOT" )
fi
[ -n "${QT_HOST_PATH:-}" ] && args+=( -DQT_HOST_PATH="$QT_HOST_PATH" )

# Configure only when the build tree is not set up; Ninja re-runs CMake itself
# when CMakeLists.txt changes, so later builds go straight to compiling.
[ -f "$BUILD/build.ninja" ] || cmake "${args[@]}"
cmake --build "$BUILD"
file "$BUILD/lookout-marine"
echo "== done: $BUILD/lookout-marine (device-Qt binary; runs on epaper) =="
