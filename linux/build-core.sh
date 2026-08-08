#!/bin/sh
# Build the Zig chart core and drop its archives + headers where meson expects.
#
# `zig build lib` installs into a --prefix of its own choosing (<prefix>/lib,
# <prefix>/include); meson wants each custom-target output at an exact path.
# This bridges the two. Mirrors android/build-libs.sh, which does the same job
# for the gradle/CMake build.
#
# usage: build-core.sh <core-root> <optimize> <out-lookout.a> <out-tile57.a> \
#                      <out-lookout.h> <out-tile57.h>
set -eu

core_root=$1
optimize=$2
out_lookout_a=$3
out_tile57_a=$4
out_lookout_h=$5
out_tile57_h=$6

prefix=$(dirname "$out_lookout_a")/core-prefix

zig build lib \
  --build-file "$core_root/build.zig" \
  -Dbackend=vk \
  -Doptimize="$optimize" \
  --prefix "$prefix"

cp -f "$prefix/lib/liblookout_marine.a" "$out_lookout_a"
cp -f "$prefix/lib/libtile57.a" "$out_tile57_a"
cp -f "$prefix/include/lookout.h" "$out_lookout_h"
cp -f "$prefix/include/tile57.h" "$out_tile57_h"

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
