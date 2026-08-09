#!/bin/sh
# Place the shipped wasm plugin set under datadir at `meson install` time.
#
# build-core.sh stages the pairs (<id>.wasm beside <id>.manifest.json) in the
# build directory; their names are build output, so they cannot be listed in
# meson.build and this runs as an install script instead.
#
# usage: install-plugins.sh <datadir-relative plugin dir>
#
# meson supplies MESON_INSTALL_DESTDIR_PREFIX (the prefix with DESTDIR already
# joined on) and MESON_BUILD_ROOT.
set -eu

rel=$1
src="$MESON_BUILD_ROOT/plugins"
dest="$MESON_INSTALL_DESTDIR_PREFIX/$rel"

# A build that never ran the core target has nothing to install. Say so and
# leave the install successful: the shell starts without plugins, it does not
# fail to install.
if [ ! -d "$src" ]; then
  echo "install-plugins: $src is absent; no plugins installed"
  exit 0
fi

mkdir -p "$dest"
rm -f "$dest"/*.wasm "$dest"/*.manifest.json
cp -f "$src"/* "$dest/"
echo "install-plugins: $(ls "$dest" | grep -c '\.wasm$') module(s) -> $dest"
