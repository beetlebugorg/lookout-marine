---
id: embedding
title: Embedding
sidebar_position: 4
---

# Embedding in your app

lookout is a **widget**. You bring the app — Swift/Cocoa on macOS, Win32 or WinUI
on Windows, GTK or Qt on Linux, a game engine, whatever — create a native window,
and hand lookout the handle. **Your app never links or sees SDL**; lookout owns the
window transport, the GPU device, and all the rendering internally.

There are two ways in, depending on whether you want lookout to render *into your
window* (accelerated) or just *hand you pixels* (universal).

## 1. Into your native window (accelerated)

Pass the OS window/view handle. lookout wraps it with SDL internally and
renders + presents into it. You keep your own run loop and event handling.

```c
#include "lookout.h"

// kind: NSWindow (1), NSView (2), HWND (3), or X11 Window XID cast to void* (4)
lookout *lk = lookout_open_in_window(LOOKOUT_NATIVE_COCOA_WINDOW, nsWindow,
                                     "chart.pmtiles", 1280, 960, /*msaa*/1);

// each frame in YOUR loop:
lookout_render(lk);                 // draws + presents into your window

// forward YOUR input events:
lookout_pan(lk, dx_px, dy_px);
lookout_zoom_at(lk, dz, mouse_x_px, mouse_y_px);
lookout_resize(lk, width_pt, height_pt);   // on native resize

lookout_close(lk);
```

On a macOS Swift shell that looks like:

```swift
let lk = lookout_open_in_window(LOOKOUT_NATIVE_COCOA_WINDOW,
                                Unmanaged.passUnretained(window).toOpaque(),
                                "chart.pmtiles", 1280, 960, 1)
// in your CVDisplayLink / timer:
lookout_render(lk)
// in mouse/scroll handlers: lookout_pan(lk, …) / lookout_zoom_at(lk, …)
```

:::tip HiDPI / Retina
lookout renders at the window's true pixel size. Mouse events usually arrive in
**logical points**; use the `_logical` variants (`lookout_pan_logical`,
`lookout_zoom_at_logical`) and lookout scales by the pixel density for you. Query
it with `lookout_pixel_density`.
:::

## 2. Give me pixels (any host)

If you don't want to hand over a window — you're compositing in Qt, uploading to
your own GL/Metal texture, or running server-side — render offscreen and take the
RGBA8 frame:

```c
lookout *lk = lookout_open("chart.pmtiles", 1024, 1024, /*window*/0, /*msaa*/1);
uint8_t *buf = malloc(1024 * 1024 * 4);
lookout_snapshot_rgba(lk, buf, 1024 * 1024 * 4);   // top-down RGBA8
// upload `buf` to your own texture / canvas
```

This costs a GPU→CPU readback per frame, but works with no SDL exposure and no
window handle at all.

## Overlays: screen ↔ geo

To draw a boat marker, a route, or a cursor pick on top of the chart, convert
between screen pixels and geographic coordinates:

```c
double lon, lat;
lookout_screen_to_geo(lk, mouse_x, mouse_y, &lon, &lat);   // where did I tap?

float x, y;
lookout_geo_to_screen(lk, boat_lon, boat_lat, &x, &y);     // where to draw the boat
```

For tap-to-identify, feed the geo point to [`lookout_pick`](./c-api.md#pick),
which reports every S-57 feature under it (class + full attribute JSON + source
cell) — the S-52 §10.8 cursor pick.

## What runs where

lookout runs its tessellation on a **worker thread**, so:

- Opening a chart or a big library **does not freeze** your window — it appears
  immediately (showing the S-52 NODATA background) and fills in when ready.
- **Zooming across bands** triggers a background re-tessellation for fresh
  level-of-detail; the previous frame keeps rendering until the new one lands (no
  flicker).
- **Day/night and mariner visibility toggles** are per-frame — no rebuild.

Call `lookout_render` from one thread (your UI thread). `lookout_pan` / `zoom` /
`set_view` just move the camera and are cheap; call them from the same thread.
