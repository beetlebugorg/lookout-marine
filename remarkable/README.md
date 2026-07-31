# Lookout Marine on the reMarkable

The chart core behind a Qt Quick shell, drawn for e-ink.

This is a peer of `macos/`, `linux/`, `windows/` and `android/`: a native shell
above the same chart core, reaching it only through `include/lookout.h`. The
chrome follows the **Apple shell** — the same readouts, the same ranked pick
report with its notes and diagrams, the same settings in the same five groups —
written in Qt Quick instead of SwiftUI, and monochrome instead of colour.

> **Not for navigation.** A prototype, like the rest of this repo.

## What is different, and why

The reMarkable has **no GPU an app can use**: the rM2 is an i.MX7 with no Vulkan
driver, and the panel is driven by reMarkable's own `epaper` Qt platform. Every
other shell hands the core a surface and lets it present into it. This one
cannot, so two things change and nothing else does.

**The core is built with no renderer.** `-Dbackend=none` selects `src/gpu_null.zig`,
which implements the `Gpu` API with nothing behind it, so `liblookout_marine.a`
links no graphics library and cross-compiles for a device that ships none.

**The shell rasterizes the chart itself.** `lookout_render_view_canvas` asks the
core for a view as pixel-space draw calls in paint order; `src/lookoutchart.cpp`
paints them with `QPainter`. The core still owns everything else — the chart set,
the composition, the camera, the mariner state — so a canvas render and a GPU
frame portray the same chart under the same settings.

Two pieces of the Apple UI are missing as a result, both because the chart is a
raster **tile pyramid**:

- **Zoom snaps to whole levels.** A pyramid is only sharp at its own levels, and
  an e-ink panel cannot animate the in-between. A pinch shows a scaled preview
  and settles on the nearest level.
- **There is no rotation, and so no north bubble.** Tiles are axis-aligned;
  turning the view would repaint every one of them on a CPU that takes tens of
  milliseconds each. The core still holds the rotation — it just stays at zero.

Everything else is the Apple chrome at the same **physical** size. `Theme.ui` is
226/132, the ratio of this panel's dpi to the iPad's point density, so a 48pt
bubble measures the same on the glass as it does on an iPad.

## Layout

```
src/lookoutchart.{h,cpp}   the one door to the core: lookout.h + the QPainter sink
src/renderworker.{h,cpp}   the core's thread — open, render, pick, aux
src/chartview.{h,cpp}      the tile pyramid and the model QML binds to (AppModel's part)
src/marinersettings.{h,cpp} the S-52 options, seeded FROM the core
src/s57.{h,cpp}            the attribute payload as report rows (HUDOverlay.swift's S57)
src/coordformat.h          the readout strings — must match every other shell
src/formats.h              those strings, as the QML singleton `Fmt`
src/mercator.h             tile addressing and the physical scale
qml/                       the chrome: Theme, Main, the panels and the controls
cmake/, docker/, scripts/  the cross build; device/, packaging/  the tablet
```

## Building

The core cross-compiles with Zig, which needs no toolchain installed. The shell
needs the device's Qt, which comes from reMarkable's SDK inside Docker.

```sh
make image      # once: bake the reMarkable SDK (Qt6 + epaper) into an image
make            # -> build-rm2-sdk/lookout-marine   (device-Qt epaper binary)
make deploy     # copy it and your charts to the tablet
make run        # build + deploy + launch on the device
```

`make help` lists every target; `make sdk-url` prints the SDK URL it will use.
Override defaults inline or in a git-ignored `config.mk`: `HOST` (ssh target),
`CHART` (file or folder), `SDK_URL` (other firmware — see
[developer.remarkable.com/links](https://developer.remarkable.com/links)).

> **Apple Silicon Mac:** `make` builds a native `linux/arm64` container — no
> emulation — and picks the aarch64 SDK itself.

To iterate on the UI without a tablet, build against a local Qt 6:

```sh
make host
./build/lookout-marine charts/
```

### The core alone

```sh
cd .. && zig build lib -Dbackend=none                      # this machine
cd .. && zig build lib -Dbackend=none \
    -Dtarget=arm-linux-gnueabihf.2.31 -Dcpu=cortex_a7 \
    -p zig-out-rm2                                         # the rM2
```

## Charts

The shell renders; it never bakes. Bake on the desktop with the
[tile57](https://github.com/beetlebugorg/tile57) CLI, then let `make deploy`
copy the archives over.

```sh
tile57 bake CELL.000 -o out/      # one cell
tile57 bake ENC_ROOT -o out/      # a whole catalogue
```

Point the app at one `out/tiles/<CELL>.pmtiles`, or at a folder of them to quilt
every cell into one seamless chart.

## Running on the tablet

Enable developer mode and SSH
([rM2](https://remarkable.guide/tech/developer-mode.html)); over USB the tablet
is `root@10.11.99.1`. `make run` deploys and launches. By hand:

```sh
/home/root/lookout-marine/launch.sh /home/root/lookout-marine/charts
```

`launch.sh` stops the stock UI, sets the touch orientation, and runs fullscreen
on the `epaper` platform. If taps land in the wrong place, override
`QT_QPA_EVDEV_TOUCHSCREEN_PARAMETERS` (the rM2 default is
`rotate=180:invertx`). Drop [`packaging/rm2.draft`](packaging/rm2.draft) in
`/opt/etc/draft/` so you do not need SSH each time.

## Display notes

- The chrome is black on white paper. The **chart** goes through the monochrome
  ink S-52 colour profile in `assets/colorProfile.ink.xml`, which `main.cpp`
  points `TILE57_COLORPROFILE` at.
- Antialiasing is off. On e-ink a hard edge beats a grey fringe the panel has to
  dither, and it renders faster.
- Rendering is coarse-then-sharp: a pan or zoom shows cached tiles, or a scaled
  coarser ancestor, and sharp tiles stream in — one refresh per settle, not one
  per tile.
- The scale readout is a **ruler-on-the-glass** value at this panel's pixel pitch
  (rM2 ≈ 0.1124 mm, 226 dpi). That is deliberately not the engine's S-52 display
  scale, which is defined at 96 dpi; the band comes from the engine's, because a
  band is a property of the chart rather than of the glass. Set
  `ChartView.pixelPitchMm` for another panel.

## Environment knobs

Shared with the other hosts, so
[the screenshot protocol](../docs/docs/developer-guide/screenshots.md) drives
this shell too: `LOOKOUT_OPEN=<chart|folder>`,
`LOOKOUT_VIEW=lon,lat,zoom[,rot]` (the rotation is accepted and ignored),
`LOOKOUT_OPEN_SETTINGS=1`, `LOOKOUT_SHOT=out.png` (grab the window once it
settles, then exit), `LOOKOUT_SHOT_DELAY=<ms>`, `LOOKOUT_FULLSCREEN=1`,
`LOOKOUT_SIZE=WxH`.
