# Lookout Marine

A native **chartplotter app for Mac, iPad, iPhone, Android and Linux**. It draws
real S-52 electronic nautical charts (NOAA ENC / S-57) directly with Metal on
Apple and Vulkan elsewhere, and stays fluid at **60 fps** — pan, pinch-zoom,
rotate, and day/night switching never stutter and never wait on a rebuild.

> **Not for navigation.** This is a prototype / proof-of-concept. It is not
> S-52 pixel-perfect and makes no claim of ECDIS correctness.

![Annapolis Harbor on iPad, day scheme](docs/ipad-day.png)

## What you can do with it

- **Read real charts, properly drawn.** Depth areas and contours, buoys and
  beacons with correct symbology, lights with sector lines, soundings, anchorage
  and restricted areas, place names — full **S-52 portrayal** of stock NOAA ENC
  cells, straight from the source data.
- **Move around like a chartplotter should.** One-finger pan with fling, pinch
  zoom anchored under your fingers, two-finger rotate, double-tap to zoom, and
  tap-to-identify any feature. On iPad and Mac, pointer/trackpad and cursor
  readouts too.
- **Open a whole coastline, not just one chart.** Point it at a folder — or drop
  cells into the app on iPhone/iPad — and Lookout stitches them into one seamless
  chart, from a single harbor to a 7,000-cell coastline, without ever freezing.
- **Flip between day, dusk, and night** instantly — the scheme changes the moment
  you tap it, with no reload.
- **Tune the chart to your eye.** The full S-52 mariner panel: safety, shallow,
  and deep contours, safety depth, two- or four-shade water, display categories,
  sounding and text toggles, symbol sizing, date-dependent features — applied
  live as you change them.
- **Jump to a position** by typing coordinates into search
  ("38 58.5N 76 28.9W" and friends).

![Same view, night scheme — an instant colour swap, not a rebuild](docs/ipad-night.png)

## Loading charts

Lookout opens **chart archives** baked from the S-57 ENC cells that hydrographic
offices give away for free — for the US, the entire NOAA ENC catalogue is one
download.

- **On Mac:** **File ▸ Open Chart…** opens a single chart or a whole folder of
  them.
- **On Linux:** **Open** in the headerbar takes a chart or a folder of cells.
- **On iPhone / iPad:** import cells through the Files picker; everything in the
  app's Documents folder is composed into your chart library at launch.

Charts are baked with the [tile57] engine's command-line tool:

```sh
tile57 bake CELL.000 -o out/      # one cell
tile57 bake ENC_ROOT -o out/      # a whole ENC_ROOT -> a ready chart library
```

## Getting the app

There's no App Store build yet — you build it from source with **Xcode**
(macOS 14+ SDK; iOS deployment floor 15.0). You'll also need **Zig 0.16**
(`brew install zig`) and **XcodeGen** (`brew install xcodegen`).

```sh
cd macos
xcodegen generate          # writes LookoutMarine.xcodeproj from project.yml
open LookoutMarine.xcodeproj
```

Pick the **LookoutMarine** (Mac) or **LookoutMarine-iOS** target and Run. The
pre-build phase runs `zig build`, which pulls in the chart engine and installs
everything the app links against — nothing needs to be pre-built. For a fully
non-debug app, use Xcode's Release configuration.

No Xcode? `macos/build-dev.sh --zig` builds the Mac app with just the Command
Line Tools into `macos/build/`.

---

## How we use AI

Cross-platform UI usually forces a choice. Use one toolkit everywhere and the app
feels slightly wrong on every platform — the scrolling, the menu placement, the
settings panel. Or write a native front end per platform and maintain several
codebases that drift apart the moment one gains a feature first.

We're testing a third option: a genuinely native shell for every platform, written
with AI — and, the open question, kept in step that way too. Below is the method as
it stands, including the parts we haven't proven.

**The core owns what gets drawn, and has no opinion about the UI.** Everything
portable — S-57 decode, S-52 portrayal, tessellation, camera, GPU scene — sits in a
Zig core behind one C ABI (`include/lookout.h`). Nothing in it knows a widget
exists, and it says nothing about menus, HUD layout or gestures. A shell may only
reach the core through that header, so no shell can couple to another and there's no
shared widget layer to regress.

**The Apple shell is the source of record for behaviour.** SwiftUI on Mac and iPad
came first and is the most complete, so it's the reference the others are written
against. The Linux and Android shells say so in their own source: the GTK
accelerators mirror the macOS menu bar with Ctrl for Command, its display menu
follows the macOS Chart menu, and its render loop mirrors the macOS display link.
When two shells disagree about how something should behave, macOS is right by
default.

**A change should start as prose, not as a diff — this part is still unproven.** The
intent is to describe the behaviour once, or point at what the Apple shell already
does, then write each shell separately to express it in its own platform's idiom:
GTK4 in C on Linux, Java on Android. So far the shells have been built one at a time,
by hand-carrying the behaviour across. Whether AI can keep several native shells in
step from one description is the part of this experiment still to be tested.

**We write real platform code, not a themed abstraction.** Each shell uses its
toolkit the way that toolkit's own documentation says to — `GtkOverlay` and
`GAction` on Linux, SwiftUI idioms on Apple. That's the whole point. A common
abstraction with platform skins would put us back in the compromise we're trying to
avoid.

**We let AI try several designs and throw most of them away.** Getting the chart on
screen under GTK took three: Vulkan into a child surface, then a dmabuf texture in
GTK's scene graph, then a subsurface below a transparent hole in the window. Only
the third is both sharp and able to float the chrome. Writing all three was cheap,
and that's what made it affordable to be wrong twice.

**The hardware decides, not the reasoning.** That dmabuf design read correctly and
was still soft on a fractional-scale display, for reasons no amount of argument
about render density fixed. We found the answer by running it and looking. So we run
the app, capture it, and compare — [docs/screenshots.md](docs/screenshots.md) fixes
the chart, camera and window size every host captures, so platforms can be compared
frame to frame instead of by impression.

**Verification is the bottleneck now, not writing code.** A plausible native shell
is the easy part. Knowing it draws correctly — the right GPU on a dual-GPU machine,
the right scale on a fractional display, the chrome where it belongs — is the work,
and it's where the review effort goes.

**Contributors send requirements or prototypes, not patches.** Describe what you
want, or build a rough version that shows it. That's the most useful input to this
workflow.

For the architecture of each host, and the faults each one exposed, see
[Linux/GTK4](docs/hosts-linux.md), `macos/README.md`, and `android/README.md`.

## Under the hood

Lookout is a thin native app over a shared **chart core written in Zig**. The
core opens a baked chart or library, asks the engine for a **draw-ready GPU
scene** (vertices, quads, paint order, per-scheme colour buffers), uploads it
once, and then renders every frame by updating a single uniform block — camera,
palette, display-category gates, and SCAMIN culling all happen in the vertex
shader. That's why panning and day/night switching never re-tessellate: the work
is done once, and each frame is a uniform update. Rendering is direct Metal
(`src/metal_shim.m` owns the device and pipelines; the engine's
`shaders/lookout.metal` is compiled at runtime, so there's no offline shader
toolchain).

The **app shells** are each platform-native around that one core: `macos/` is
SwiftUI (menu bar, HUD, zoom controls, the mariner settings panel, search) with
Mac and iOS/iPadOS sharing the Swift sources; `android/` is a Java shell over a
`SurfaceView`; `linux/` is GTK4 in C, presenting Vulkan into a subsurface below a
transparent hole in the window so the chrome floats over the chart. Each drives
the same `lookout.h` C ABI. See [docs/architecture.md](docs/architecture.md),
[docs/hosts-linux.md](docs/hosts-linux.md), `macos/README.md` and
`android/README.md` for the per-shell architecture and gotchas.

The heavy lifting — S-57 decoding, S-101 portrayal (embedded Lua rules),
tessellation, sprite/SDF atlases, tile compositing — lives in the **[tile57]**
engine, consumed here as a Zig package dependency: a sibling `../tile57` checkout
is used when present, otherwise the commit pinned in `build.zig.zon` is fetched
automatically, and `libtile57.a` is built from source inside `zig build`.

[tile57]: https://github.com/beetlebugorg/tile57

## For developers: building & embedding the core

The chart core builds and runs on its own, and is embeddable in any native app:

```sh
zig build                  # ReleaseFast by default; -Doptimize=Debug to develop
zig build test             # unit tests
```

`zig build` installs `liblookout_marine.a`, `libtile57.a`, `lookout.h`, and
`tile57.h` into `zig-out/`. To embed: create a native view, hand its
`CAMetalLayer` to `lookout_open_in_window(LOOKOUT_NATIVE_METAL_LAYER, …)`, and
drive it with `lookout_render` / `lookout_pan` / `lookout_zoom_at` /
`lookout_set_mariner` etc. — see `include/lookout.h`. Headless consumers can skip
the window and pull frames with `lookout_snapshot_rgba`.

`zig-out/bin/lookout-marine-demo` is the render-parity and smoke-test harness
(not the app): it renders a chart to day / night / zoomed PNGs and exits.

```sh
./zig-out/bin/lookout-marine-demo chart.pmtiles [--png out.png] [--lon L --lat L --zoom Z]
```

Two launch-time conveniences help when iterating: `LOOKOUT_OPEN=<chart|dir>`
opens something at startup, and `LOOKOUT_VIEW=lon,lat,zoom[,rot]` pins the
opening camera (both forwarded by `simctl launch` as `SIMCTL_CHILD_*` — how the
screenshots above were captured).

### Layout

```
build.zig, build.zig.zon   build + the tile57 dependency pin
include/lookout.h          C ABI (the Swift<->Zig bridge)
src/camera.zig             web-mercator camera math (MVP, screen<->geo, SCAMIN)
src/root.zig               Lookout: scene lifecycle, worker-thread rebuilds
src/gpu.zig                backend switch (metal | vk | sdl)
src/gpu_vk.zig             Vulkan transport (Linux/Android): pipelines, swapchain
src/gpu_metal.zig          Metal transport  (+ src/metal_shim.{h,m}, the ObjC shim)
src/atlas.zig, src/png.zig sprite/SDF atlas load, PNG encode
src/capi.zig, src/main.zig C ABI wrapper; the headless demo
docs/                      architecture, per-host notes, screenshot protocol
macos/                     the SwiftUI app (macOS + iOS/iPadOS), XcodeGen spec
android/                   the Java shell (Vulkan onto a SurfaceView)
linux/                     the GTK4 app (Vulkan into a subsurface), meson
vendor/stb                 stb_image (atlas PNG decode)
```

The shaders are not here: they read the vertex, quad and uniform layouts the
engine defines, so they live with those, in tile57's `shaders/`. This build
embeds them straight from the dependency.

The SDL3/`SDL_GPU`/Vulkan/MoltenVK predecessor of this renderer — and every
driver workaround it accumulated — lives at the `sdl-gpu` git tag.

## Contributing

This project is built with AI assistance — see [How we use AI](#how-we-use-ai). Use
AI tools freely. The most useful contribution is a clear set of requirements, or a
rough prototype of what you want, rather than a patch.

[docs/](docs/) has the architecture, the per-host notes, and the screenshot protocol
used to compare hosts.

## License

MIT — see `LICENSE`.
