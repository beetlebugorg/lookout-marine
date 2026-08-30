#!/bin/sh
# Run a widget test with a display. The session's own display is used when one
# exists; otherwise Xvfb supplies one. With neither, the test binary exits 77
# and meson records a skip.
set -eu

if [ -n "${WAYLAND_DISPLAY:-}" ] || [ -n "${DISPLAY:-}" ]; then
  exec "$@"
fi

if command -v xvfb-run >/dev/null 2>&1; then
  exec xvfb-run -a -s "-screen 0 1600x1000x24" "$@"
fi

exec "$@"
