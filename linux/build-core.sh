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
