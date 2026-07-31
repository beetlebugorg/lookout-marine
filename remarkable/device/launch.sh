#!/bin/sh
# SPDX-FileCopyrightText: 2024-2026 Jeremy Collins <jeremy.collins@beetlebug.org>
# SPDX-License-Identifier: MIT
#
# Run lookout-marine on the reMarkable's e-ink display. Runs ON the tablet.
#
#   ./launch.sh charts            # a folder of baked cells (one quilted chart)
#   ./launch.sh chart.pmtiles     # a single baked archive
#
# It uses the device's OWN Qt on reMarkable's "epaper" platform, which any rM2
# firmware whose stock Qt ships the epaper plugin provides. There is no bundled
# Qt and no rm2fb path here: the binary is built against the device SDK's Qt
# (see docker/sdk-build.sh), so it has the platform it needs already.
#
# The stock UI (xochitl) is stopped while running and restarted on exit. When
# launched from draft or oxide, which manage the framebuffer themselves, pass
# STOP_UI=0.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
CHART="${1:-$HERE/charts}"

export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-epaper}"
export QT_QUICK_BACKEND="${QT_QUICK_BACKEND:-epaper}"

# Touch orientation. The rM2 needs invertx; the rM1 does not. Override this if
# taps land in the wrong place.
export QT_QPA_EVDEV_TOUCHSCREEN_PARAMETERS="${QT_QPA_EVDEV_TOUCHSCREEN_PARAMETERS:-rotate=180:invertx}"
export LOOKOUT_FULLSCREEN=1

STOP_UI="${STOP_UI:-1}"
[ "$STOP_UI" = "1" ] && systemctl stop xochitl 2>/dev/null || true
trap '[ "$STOP_UI" = "1" ] && systemctl start xochitl 2>/dev/null || true' EXIT INT TERM

# Stop any previous instance so it releases the epaper framebuffer — otherwise
# the new one aborts with "Failed to lock epframebuffer. Is there another
# EPFramebuffer instance?" — and lets go of the executable file. SIGTERM, wait,
# then SIGKILL, which always frees the framebuffer fd. pidof/pgrep and kill are
# busybox-portable.
_prev="$(pidof lookout-marine 2>/dev/null || pgrep lookout-marine 2>/dev/null || true)"
if [ -n "$_prev" ]; then
    kill $_prev 2>/dev/null || true
    sleep 1
    kill -9 $_prev 2>/dev/null || true
    sleep 1
fi

exec "$HERE/lookout-marine" -platform "$QT_QPA_PLATFORM" "$CHART"
