---
id: screenshots
title: Screenshot protocol
sidebar_position: 3
---

# Screenshot protocol

Each host draws the same chart with the same core. Therefore you must be able to
compare the screenshots of two hosts frame by frame. This is possible only if the
chart, the camera, the window size, and the capture method are the same. This page
gives that specification.

Verification is the difficult part of
[the experiment](https://github.com/beetlebugorg/lookout-marine#how-we-use-ai),
not generation. A shell can look correct alone, but it can still be soft, or the
wrong size, or it can lose its chrome. The same frame on each host makes these
faults easy to see.

## The specified frame

| Item | Value |
|---|---|
| **Chart** | The NOAA ENC library (a folder of baked cells). The labels and the anchorage areas are dense. |
| **Camera** | `-76.482,38.976,13.7` — Annapolis Harbor and the Naval Academy |
| **Scheme** | Day |
| **Logical size** | 1400 x 900 points |
| **Scale** | 2, which gives **2800 x 1800 px** |
| **Frames** | `day` (the chart and the floating chrome) and `settings` (the mariner panel above the chart) |
| **File names** | `docs/docs/img/<host>-<shot>.png`, for example `linux-day.png` or `macos-day.png` |

Two environment variables make the camera the same on each host:

```sh
LOOKOUT_OPEN=<chart|folder>        # what to open at start
LOOKOUT_VIEW=lon,lat,zoom[,rot]    # the first camera position
```

On iOS and iPadOS, `simctl launch` sends them as `SIMCTL_CHILD_LOOKOUT_OPEN` and
`SIMCTL_CHILD_LOOKOUT_VIEW`.

## Linux

```sh
cd linux
ninja -C build
./screenshots.sh all            # writes docs/docs/img/linux-day.png and docs/docs/img/linux-settings.png
```

The script starts the app in an **off-screen sway session**. Then it captures the
output with `grim`. This method gives three advantages:

- **No part of the desktop is in the frame.** There is no wallpaper at the corners.
  The compositor does not add round corners or a shadow to the image.
- **The size is exact.** The script sets the output size to the logical size
  multiplied by the scale. Therefore the frame is always 2800 x 1800, and the
  monitor of the developer has no effect. Do not set the output to the logical size.
  The minimum size of the app (720 x 520) is then larger than the output, and the
  compositor cuts the chrome out of the frame.
- **The GPU path is the same as in normal use.** sway is a true Wayland compositor
  and it uses the true GPU. Therefore the compositor shows the chart through the
  same subsurface path that a user gets. It does not use a software fallback. Refer
  to [the Linux host](hosts-linux.md).

The script does not send synthetic input to open the mariner panel. It activates the
window action through D-Bus. `GtkApplicationWindow` publishes the `win.*` actions on
the session bus:

```sh
gdbus call --session -d org.beetlebug.LookoutMarine \
  -o /org/beetlebug/LookoutMarine/window/1 \
  -m org.gtk.Actions.Activate settings '@av []' '@a{sv} {}'
```

## macOS

Use the same four values: the chart, the camera, the day scheme, and 1400 x 900 at
scale 2. Capture only the window. Do not capture the screen, and do not include the
desktop.

```sh
open -n --env LOOKOUT_OPEN=<chart|folder> \
        --env LOOKOUT_VIEW=-76.482,38.976,13.7 \
        --env LOOKOUT_WINDOW=1400x900 \
        build/Debug/LookoutMarine.app
# one window only, no shadow, written to the specified file name
screencapture -o -l"$(GetWindowID LookoutMarine)" docs/docs/img/macos-day.png
```

`LOOKOUT_WINDOW=WIDTHxHEIGHT` sets the content size, so the frame is the same on
each Mac. The window must fit on the display: a 1400 x 900 window needs a display
of more than 1400 x 930 points.

`-o` removes the window shadow. `-l<windowid>` captures one window. Together they
give the same result as the sway and grim method on Linux. A Retina display gives
scale 2 automatically. A display with scale 1 gives a 1400 x 900 frame. Label such a
frame correctly. Do not make it larger.

To make the settings frame, press **Command+,** or click the gear bubble to open the
mariner window. `LOOKOUT_OPEN_SETTINGS=1` opens it at start. Then capture the window
above the chart. The frame must agree with `linux-settings.png`.

## iPadOS and iOS

The simulator writes the frame itself, so no screen permission is necessary. The
`SIMCTL_CHILD_` variables must be in the environment of `simctl`. They are not
launch arguments.

```sh
xcrun simctl boot "iPad Pro 11-inch (M5)"
xcrun simctl install booted <path>/LookoutMarine.app
xcrun simctl status_bar booted override --time 9:41 \
  --batteryState charged --batteryLevel 100 --wifiMode active
SIMCTL_CHILD_LOOKOUT_OPEN=<chart|folder> \
SIMCTL_CHILD_LOOKOUT_VIEW=-76.482,38.976,13.7 \
  xcrun simctl launch booted org.beetlebug.lookout-marine-ios
sleep 60   # a 7,000-cell library takes about a minute to map and draw
xcrun simctl io booted screenshot docs/docs/img/ipad-day.png
```

Use the same steps on an iPhone device for `iphone-day.png`. Both frames are
portrait: `simctl` cannot rotate a device. To make a landscape frame, run the
`testFrameForScreenshot` UI test with `TEST_RUNNER_LOOKOUT_FRAME=1`, which turns the
device and then holds while you capture.

## How to examine a frame

Examine these four items in this sequence. Each item is a fault that this project
made and then found.

1. **Is the full window in the frame?** If the status bar or the headerbar is cut,
   the capture surface was smaller than the minimum size of the app.
2. **Does the chrome float above the chart?** If the chrome is in a bar below the
   chart, the host used a path that cannot composite.
3. **Are the text and the symbols sharp at 100%?** Examine the PNG file at 100%. Soft
   glyphs show that something resampled the chart. The size that the core drew and
   the size that the toolkit composited are not the same.
4. **Is the chart in the frame?** A frame of flat NODATA blue shows that the camera
   is away from the data. It does not show that the chart failed to draw.
