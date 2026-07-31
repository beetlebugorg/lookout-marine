---
id: remarkable
title: reMarkable
sidebar_position: 6
---

# reMarkable

A native **Qt Quick** shell around the Zig chart core, drawn for **e-ink**. Same
core, same C ABI, same behaviour as the SwiftUI, GTK4, WinUI 3 and Java shells —
with one difference that shapes the whole host: this device has no GPU an app can
reach.

## The problem, and the shape of the answer

The reMarkable 2 is an i.MX7 — a Cortex-A7 with no Vulkan driver — and its
display is driven by reMarkable's own `epaper` Qt platform plugin. Every other
shell hands the core a native surface (a `CAMetalLayer`, an `ANativeWindow`, a
Wayland subsurface, a `SwapChainPanel`) and the core presents into it. There is
nothing here to hand over.

So the core keeps everything it normally owns and gives up only the last step:

**`-Dbackend=none`.** `src/gpu_null.zig` implements the whole `Gpu` API with
nothing behind it — `init` makes no device, the scene calls hold no memory, and
the render calls report that no frame was drawn. A build that selects it links no
graphics library at all, which is what lets `liblookout_marine.a` cross-compile
for a device that ships none. It is the fifth backend beside metal, vk, d3d12 and
sdl, and `src/gpu.zig` selects it the same way.

**`lookout_render_view_canvas`.** The host asks for a view as pixel-space draw
calls, in paint order, through tile57's canvas callbacks, and paints them with
its own rasterizer. The core supplies the chart set, the composition and the
mariner state; the host supplies `QPainter`. A canvas render and a GPU frame
portray the same chart under the same settings.

```c
int lookout_render_view_canvas(lookout *h, double lon, double lat, double zoom,
                               uint32_t width, uint32_t height,
                               const tile57_canvas_cb *cb);
```

The view is stated outright rather than read from the camera, because a host
drawing this way is filling a **tile pyramid**: it wants the view centred on each
tile, not the one on screen. Pass `lookout_get_view`'s values to draw what the
camera sees.

This is the path a printer or a PDF export would take too. Nothing about it is
specific to this tablet beyond the choice of rasterizer.

## The chart: a raster tile pyramid

`ChartView` is a `QQuickPaintedItem` that composites 512-px web-mercator tiles.
`RenderWorker` owns the `lookout` handle and paints one tile at a time on its own
thread; the GUI thread posts the set it wants, centre-out, and paints whatever
has arrived. A missing tile is filled instantly from a coarser cached ancestor,
scaled — blurry beats blank, and it means a zoom never flashes white before the
panel has refreshed.

The core locks its own API, so confining the handle to one thread is not about
safety; it is about latency. A canvas render holds that lock for as long as it
takes to paint a tile, which on an i.MX7 is tens of milliseconds.

### The zoom convention, which has an off-by-one in it

The core's camera and every zoom crossing `lookout.h` use a **256-px** world tile
— the convention behind its 1:N display scale. The pyramid paints **512-px**
tiles. So at core zoom Z the world is 2^(Z-1) tiles across, and a tile is exactly
the 512-px view at core zoom Z centred on it.

Getting that wrong produces a chart that still looks like a chart, at twice the
ground it should cover, so `remarkable/src/mercator.h` names the two apart
everywhere: `zoom` is always the core's, `level` is always the pyramid's, and
`tileLevel()` / `coreZoom()` convert.

## The chrome follows the Apple shell

Per [the architecture](architecture.md), the Apple shell is the reference for
behaviour, and this one follows it: the readouts capsule, the zoom bubbles, the
scale bar, the scale entry with its band presets, the ranked pick report with its
notes and diagrams, and the settings in the same five groups. `Theme.qml` carries
the same numbers as `Chrome.swift`, and `coordformat.h` is a port of
`CoordFormat` so every host prints the same string for the same view.

Two adaptations, both forced by the panel:

**Size.** Apple's numbers are points at the iPad's 132 ppi point density. This
panel is 226 ppi, so `Theme.ui` is 226/132 and every metric comes out the same
*physical* size as on an iPad. It describes the glass, not a taste.

**Colour.** There is none. The accent blue, the amber dot and the overscale
orange become weight, fill and inversion.

And two Apple controls are absent, both because the tiles are axis-aligned:

- **Zoom snaps to whole levels.** A pyramid is sharp only at its own levels.
- **No rotation, so no north bubble.** A turned view would repaint every tile.

## Building

The core cross-compiles with Zig, which needs no toolchain installed; the shell
needs the device's own Qt, which comes from reMarkable's SDK inside Docker.

```sh
cd remarkable
make image      # once: bake the reMarkable SDK (Qt6 + epaper) into an image
make            # -> build-rm2-sdk/lookout-marine
make run        # build + deploy + launch on the device
make host       # a desktop build against a local Qt 6, for the UI
```

The core alone:

```sh
zig build lib -Dbackend=none                                    # this machine
zig build lib -Dbackend=none -Dtarget=arm-linux-gnueabihf.2.31 \
    -Dcpu=cortex_a7 -p zig-out-rm2                              # the rM2
```

`remarkable/README.md` covers deployment, the touch orientation, the ink colour
profile and the e-ink display notes.

## Verifying

The shell honours the shared knobs, so
[the screenshot protocol](screenshots.md) drives it like any other host:
`LOOKOUT_OPEN`, `LOOKOUT_VIEW`, `LOOKOUT_OPEN_SETTINGS`, plus `LOOKOUT_SHOT` to
grab the window once it settles and exit. `LOOKOUT_VIEW` accepts a rotation and
ignores it, since this view is always north-up.
