# lookout-marine — macOS app

A native SwiftUI macOS S-52 chartplotter wrapped around the Zig `SDL_GPU` chart
core. All app chrome (menu bar, HUD, zoom controls, mariner settings, search) is
native SwiftUI; the chart itself is one GPU-rendered `NSView` driven through the
`lookout.h` C ABI.

## Prerequisites

- **Xcode** (or Command Line Tools) — macOS 14+ deployment target.
- **Zig 0.16.0** on `PATH` (`brew install zig`).
- **tile57** checked out and built:
  ```sh
  cd ../../tile57            # your tile57 checkout
  git submodule update --init --recursive   # portrayal catalogue
  zig build                                  # produces zig-out/lib/libtile57.a
  ```
- **SDL3** (`brew install sdl3`). It is keg-only; the project points at
  `/opt/homebrew/opt/sdl3` by default (override `SDL3_DIR`).
- **XcodeGen** to generate the project (`brew install xcodegen`).

## Build & run

```sh
cd macos
xcodegen generate            # writes LookoutMarine.xcodeproj from project.yml
open LookoutMarine.xcodeproj
```

In Xcode, set **TILE57_DIR** (and `SDL3_DIR` if needed) in the project's build
settings if the defaults don't match your machine, then Run. The project's
pre-build script runs `zig build -Dtile57=$TILE57_DIR -Doptimize=ReleaseFast`,
producing `../zig-out/lib/liblookout_marine.a`, which the app links together with
`libtile57.a` and SDL3.

**No Xcode?** `macos/build-dev.sh [--zig]` builds the same app with just the
Command Line Tools (swiftc + a hand-rolled bundle) into `macos/build/`.
Override `TILE57` / `SDL3` / `OUT` in the environment if the defaults don't fit.

You need a baked `.pmtiles` chart to see anything: **File ▸ Open Chart…** picks a
`.pmtiles` file (or a folder of cells to compose a library). On first launch the
app also probes `$LOOKOUT_OPEN` (a chart, or a folder of cells — handy for dev
runs from the terminal), then the last recent, then the demo default
`~/.cache/chartplotter/NOAA/tiles/d5/US5MD1MC.pmtiles`.

> The SDL3 dylib is loaded from the Homebrew keg at runtime via an rpath (dev
> convenience). For distribution, bundle `SDL3` inside the app and add an
> `@rpath`/`@executable_path/../Frameworks` runpath instead. MoltenVK/Vulkan must
> be discoverable for `SDL_GPU` (the same requirement as the Zig demo).

## What's in here

| File | Role |
|------|------|
| `LookoutMarineApp.swift` | `@main` App: window `ZStack`, Settings scene, commands |
| `ChartView.swift` | `NSViewRepresentable` + backing `NSView`: input, on-demand loop |
| `ChartController.swift` | `@MainActor` owner of the `lookout*` handle; the one funnel for every `lookout_*` call and the display-link render loop |
| `AppModel.swift` | Shared observable state; menu/search actions; coordinate parser |
| `MarinerSettings.swift` | Swift mirror of `tile57_mariner` (round-trips engine-only fields) |
| `SettingsView.swift` | The S-52 mariner form (⌘,) |
| `HUDOverlay.swift` | Cursor lat/lon, 1:N scale, scheme, compass, identify results |
| `ZoomControls.swift` | Floating +/−/fit/north buttons |
| `SearchField.swift` | Coordinate go-to (feature search stubbed) |
| `Commands.swift` | Native menu bar (macOS) |
| `Platform.swift` | The macOS/iOS seam (typealiases + display-link/scale helpers) |
| `project.yml` | XcodeGen target definition (all build settings) |

## iOS reuse

The app is structured so the bulk of it is platform-neutral and reused verbatim
on iOS. Shared as-is: `AppModel`, `MarinerSettings`, `SettingsView`, `HUDOverlay`,
`ZoomControls`, `SearchField`, and all of `ChartController`'s logic. Platform-
specific code is isolated behind `#if os(...)` and `Platform.swift`:

- **Backing view** — `PlatformView` = `NSView` / `UIView`.
- **Display link** — `Platform.makeDisplayLink` (macOS 14 `NSView.displayLink`
  vs iOS `CADisplayLink`).
- **Backing scale** — `Platform.backingScale`.
- **Input** — macOS `NSEvent` overrides vs iOS `UIGestureRecognizer` (the iOS
  `ChartView` is a scaffold).
- **Menu bar** — macOS-only `Commands`; the actions live in `AppModel`, so iOS
  can surface the same commands as toolbar buttons.

To bring up an actual iOS target you additionally need **one small ABI
addition**: a `LOOKOUT_NATIVE_UIKIT_VIEW` kind (sibling to
`LOOKOUT_NATIVE_COCOA_VIEW`) backed by a `CAMetalLayer` `UIView`, wired the same
way `lookout_open_in_window` already handles the Cocoa view.

## Driver-stack workarounds (SDL_GPU Vulkan → MoltenVK → Metal)

Three silent faults in this stack are worked around in `src/gpu.zig` — each was
isolated with the data verified at every prior step:

- **Indexed draws resolve wrong vertices** (polygons shred into giant wedges).
  The scene is de-indexed at upload (`uploadGpuScene`) and drawn non-indexed.
- **After any swapchain recreation (window resize / full screen), geometry
  stops rasterizing** — clears still land, so the chart shows only background,
  forever. An 80-line SDL_GPU triangle app reproduces it. On every resize the
  window is released and re-claimed on the GPU device, which rebuilds the
  swapchain cleanly and restores rasterization.
- **`SDL_SetWindowSize` on a wrapped native window re-enters AppKit layout**
  (unbounded recursion → abort during the full-screen transition). In embed
  mode the host owns the window size; the renderer adopts the acquired
  swapchain size each frame instead.

Scene uploads are also read back and verified (retried on mismatch), and
`SDL_CreateGPUDevice` debug mode is opt-in (`LOOKOUT_GPU_DEBUG=1`) — with it
on, an installed Khronos validation layer gets injected into every run and can
itself crash across swapchain recreations.

## Deferred (noted so they aren't dropped)

- **Feature / place-name search.** The search field's coordinate go-to works now;
  name/feature search is stubbed and labelled "coming soon". It needs a name
  index in tile57 plus a matching `lookout_*` query — out of Phase-1 scope. We do
  not fake results.
- **iOS target.** Scaffolded (see above); needs the UIKit native-view ABI kind
  and gesture input.
- **WASM plugin canvas.** Out of scope this phase; the architecture keeps the
  chart `NSView` a clean surface and `ChartController` the single render/state
  owner so the plugin host can hook the same tick later.

## ABI additions this app introduced

Added to `../include/lookout.h` + `../src/capi.zig` (all verified building and
exporting from `liblookout_marine.a`):

- `lookout_rotate_drag_logical`, `lookout_reset_rotation`, `lookout_fling_start`,
  `lookout_animating`, `lookout_tick_anim`, `lookout_is_building`,
  `lookout_scale_denominator` — the smooth-interaction surface (Task B).
- `lookout_open_charts_in_window` — embed a composed chart **library** (a folder
  of cells) into a host view, so directory-open composes into the app's `NSView`
  instead of spawning a detached window.
