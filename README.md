# Lookout Marine

A native **chartplotter for macOS, iOS, and iPadOS**: S-52 electronic
nautical charts (NOAA ENC / S-57), rendered **directly with Metal**, designed
around a hard **60 fps** interaction target — pan, pinch-zoom, rotate, and
day/night switching never re-tessellate and never block the frame loop.

> **Not for navigation.** This is a prototype / proof-of-concept. It is not
> S-52 pixel-perfect and makes no claim of ECDIS correctness.

![Annapolis Harbor on iPad, day scheme](docs/ipad-day.png)

## What it does

- **Real S-52 portrayal** of real charts: depth areas and contours, buoys and
  beacons with proper symbology, lights with sector lines, soundings, anchorage
  areas, restricted areas, place names — portrayed by the [tile57] engine's
  embedded S-101 rule catalogue from stock NOAA ENC cells.
- **Chartplotter interaction at display rate**: one-finger pan with fling,
  pinch zoom anchored under your fingers, two-finger rotate, double-tap zoom,
  tap-to-identify, pointer/trackpad support on iPad, cursor readouts on macOS.
- **Whole chart libraries, not just cells.** Point it at a folder (or drop
  cells into Documents on iOS) and it composes them through tile57's runtime
  compositor — from a single harbor cell to a 7,000-cell coastline, opened
  without freezing the window (tessellation runs on a worker thread).
- **Day / dusk / night schemes** that switch instantly — colours live in
  per-scheme buffers, so a scheme change is a buffer swap, never a rebuild.
- **The full S-52 mariner panel** (⌘, / the gear): safety, shallow, and deep
  contours, safety depth, two- or four-shade water, display categories, sounding
  and text toggles, symbol sizing, date-dependent features. Visibility toggles
  apply live in the shader; geometry changes rebuild in the background while
  the old scene keeps drawing.
- **Coordinate go-to** in the search field ("38 58.5N 76 28.9W" and friends);
  feature/place-name search is stubbed pending a name index in the engine.

![Same view, night scheme — a colour-buffer swap, not a rebuild](docs/ipad-night.png)

## How it's put together

- **`src/` — the chart core, in Zig.** Opens a baked [tile57] chart or
  library, asks the engine for its **draw-ready GPU scene** (vertices, quads,
  paint order, per-scheme colour buffers), uploads it once, and then renders
  every frame by updating a single uniform block — camera MVP, palette,
  display-category gates, SCAMIN culling all happen in the vertex shader.
  Rendering is direct Metal: `src/metal_shim.m` (ObjC behind a C face) owns
  the device and four pipelines (chart / sprite / SDF text / pattern fills)
  and presents into the host view's `CAMetalLayer`; `shaders/lookout.metal`
  is compiled by the shim at runtime, so there is no offline shader toolchain.
- **`macos/` — the app.** A SwiftUI shell (menu bar / HUD / zoom controls /
  mariner settings / search) around one GPU-rendered chart view, driven
  through the core's C ABI (`include/lookout.h`). macOS and iOS/iPadOS share
  the Swift sources; iOS adds a plain-UIKit gesture surface under a
  pass-through SwiftUI chrome window. See `macos/README.md` for the
  architecture, testing, and the gotchas.
- **`zig-out/bin/lookout-marine-demo` — the headless render tool.** Renders a
  chart to day / night / zoomed PNGs and exits; it's the render-parity and
  smoke-test harness, not the app.

The heavy lifting — S-57 decoding, S-101 portrayal (embedded Lua rules),
tessellation, sprite/SDF atlases, tile compositing — lives in the
**[tile57]** engine, which this build consumes **as a Zig package
dependency**: a sibling `../tile57` checkout is used when present, otherwise
the commit pinned in `build.zig.zon` is fetched automatically. Either way
`libtile57.a` is built from source inside `zig build`; nothing needs to be
pre-built.

[tile57]: https://github.com/beetlebugorg/tile57

## Building the app (Xcode)

Prerequisites: **Xcode** (macOS 14+ SDK; iOS deployment floor is 15.0),
**Zig 0.16** (`brew install zig`), **XcodeGen** (`brew install xcodegen`).

```sh
cd macos
xcodegen generate          # writes LookoutMarine.xcodeproj from project.yml
open LookoutMarine.xcodeproj
```

Pick the **LookoutMarine** (macOS) or **LookoutMarine-iOS** target and Run.
That's it — the pre-build phase runs `zig build`, which fetches/builds tile57,
builds the lookout core, and installs the archives + headers into `zig-out*/`
for the app to link. The Zig cores are always built **ReleaseFast** (the
`build.zig` default); use Xcode's Release configuration for a fully
non-debug app.

No Xcode? `macos/build-dev.sh --zig` builds the macOS app with just the
Command Line Tools (swiftc + a hand-rolled bundle) into `macos/build/`.

## Getting charts

The app opens **baked tile57 PMTiles archives**, made from the S-57 ENC cells
that hydrographic offices distribute for free (for the US, the entire NOAA ENC
catalogue is a download away). Bake with the tile57 CLI:

```sh
tile57 bake CELL.000 -o out/      # one cell
tile57 bake ENC_ROOT -o out/      # a whole ENC_ROOT -> per-cell archives + partition
```

Then **File ▸ Open Chart…** opens a `.pmtiles` cell or a folder of them; on
iOS the Files-app picker imports into the app's Documents, and everything in
Documents composes into the startup library. Dev conveniences:
`LOOKOUT_OPEN=<chart|dir>` opens something at launch, and
`LOOKOUT_VIEW=lon,lat,zoom[,rot]` pins the opening camera (both forwarded by
`simctl launch` as `SIMCTL_CHILD_*` — that's how the screenshots above were
framed).

## Building the core alone

```sh
zig build                  # ReleaseFast by default; -Doptimize=Debug to develop
zig build test             # unit tests
./zig-out/bin/lookout-marine-demo chart.pmtiles [--png out.png] [--lon L --lat L --zoom Z]
```

`zig build` installs `liblookout_marine.a`, `libtile57.a`, `lookout.h`, and
`tile57.h` into `zig-out/`. The core is embeddable: create a native view, hand
its `CAMetalLayer` to `lookout_open_in_window(LOOKOUT_NATIVE_METAL_LAYER, …)`,
and drive it with `lookout_render` / `lookout_pan` / `lookout_zoom_at` /
`lookout_set_mariner` etc. — see `include/lookout.h`. Headless consumers can
skip the window and pull frames with `lookout_snapshot_rgba`.

## Layout

```
build.zig, build.zig.zon   build + the tile57 dependency pin
include/lookout.h          C ABI (the Swift↔Zig bridge)
shaders/lookout.metal      all four pipelines, compiled at runtime
src/camera.zig             web-mercator camera math (MVP, screen<->geo, SCAMIN)
src/root.zig               Lookout: scene lifecycle, worker-thread rebuilds
src/gpu.zig                Metal transport: pipelines, buffers, per-frame render
src/metal_shim.{h,m}       the ObjC Metal/CAMetalLayer shim behind a C face
src/atlas.zig, src/png.zig sprite/SDF atlas load, PNG encode
src/capi.zig, src/main.zig C ABI wrapper; the headless demo
macos/                     the SwiftUI app (macOS + iOS/iPadOS), XcodeGen spec
vendor/stb                 stb_image (atlas PNG decode)
```

The SDL3/`SDL_GPU`/Vulkan/MoltenVK predecessor of this renderer — and every
driver workaround it accumulated — lives at the `sdl-gpu` git tag.

## License

MIT — see `LICENSE`.
