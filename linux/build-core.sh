#!/bin/sh
# Build the Zig chart core and drop its archives + headers where meson expects.
#
# `zig build lib` installs into a --prefix of its own choosing (<prefix>/lib,
# <prefix>/include); meson wants each custom-target output at an exact path.
# This bridges the two. Mirrors android/build-libs.sh, which does the same job
# for the gradle/CMake build.
#
# usage: build-core.sh <core-root> <optimize> <out-lookout.a> <out-tile57.a> \
#                      <out-lookout.h> <out-tile57.h> [<out-vmlib.a>]
#
# The seventh argument turns the wasm plugin host on. It is the path meson wants
# the WAMR archive at, and giving it is what passes -Dplugins=true: off Apple the
# static core does not embed libvmlib.a (an ELF linker rejects a nested archive),
# so the executable has to link it alongside. No seventh argument builds the core
# with no plugin host, which is what an architecture scripts/build-wamr.sh has no
# archive for has to do.
set -eu

core_root=$1
optimize=$2
out_lookout_a=$3
out_tile57_a=$4
out_lookout_h=$5
out_tile57_h=$6
out_vmlib_a=${7-}

prefix=$(dirname "$out_lookout_a")/core-prefix

if [ -n "$out_vmlib_a" ]; then
  set -- -Dplugins=true
else
  set --
fi

# No -Dbackend: charttable picks Metal on Apple and Vulkan everywhere else,
# off the target, so there is nothing for this build to select.
zig build lib \
  --build-file "$core_root/build.zig" \
  -Doptimize="$optimize" \
  "$@" \
  --prefix "$prefix"

cp -f "$prefix/lib/liblookout_marine.a" "$out_lookout_a"
cp -f "$prefix/lib/libtile57.a" "$out_tile57_a"
cp -f "$prefix/include/lookout.h" "$out_lookout_h"
cp -f "$prefix/include/tile57.h" "$out_tile57_h"
if [ -n "$out_vmlib_a" ]; then
  cp -f "$prefix/lib/libvmlib.a" "$out_vmlib_a"
fi

# The shipped plugin set, staged beside the archives for meson's install
# script to place under datadir. `zig build plugins` writes the org.beetlebug
# pairs (own ship, AIS, NMEA 0183, Signal K, laylines) into
# <prefix>/plugins-bundled, which holds the shipped set and nothing else. The
# modules are wasm, so this needs no target and no optimize mode.
zig build plugins \
  --build-file "$core_root/build.zig" \
  --prefix "$prefix"

plugins_stage=$(dirname "$out_lookout_a")/plugins
rm -rf "$plugins_stage"
mkdir -p "$plugins_stage"
cp -f "$prefix"/plugins-bundled/* "$plugins_stage/"
