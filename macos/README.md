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

## iOS

The bulk of the app is platform-neutral and reused verbatim on iOS: `AppModel`,
`MarinerSettings`, `SettingsView`, `HUDOverlay`, `ZoomControls`, `SearchField`,
`OverlayLayer`, and all of `ChartController` (including the open path and the
display-link render loop). Platform code is isolated behind `#if os(...)` and
`Platform.swift`.

**How the chart is embedded (differs from macOS by necessity).** SDL3 has no
create-property for wrapping an existing `UIView` (its only iOS embed hook is
`SDL_PROP_WINDOW_CREATE_WINDOWSCENE_POINTER`), so the originally sketched
`LOOKOUT_NATIVE_UIKIT_VIEW` kind isn't implementable. Instead:

- The ABI kind is **`LOOKOUT_NATIVE_UIKIT_WINDOWSCENE`**: the host passes its
  `UIWindowScene` (or NULL for the active scene) and lookout/SDL creates its own
  **full-screen chart `UIWindow` inside that scene**.
- iOS uses the **UIKit lifecycle** (AppDelegate + SceneDelegate, no
  WindowGroup) and a three-window stack, bottom → top:
  1. **SDL's chart window** (created at open; renders the chart),
  2. the **input window** — `ChartUIView` in plain UIKit. This split exists
     because SwiftUI's hosting view hit-tests as itself across its whole
     window and *never* forwards touches to UIKit subviews or window-attached
     recognizers (measured; see `LookoutMarine-iOS/UITests`) — a gesture
     surface inside SwiftUI renders fine but never hears a touch.
  3. the **chrome window** — the SwiftUI overlay in a `PassThroughWindow`
     (empty areas return nil from hitTest and fall through to the input
     window; controls keep their touches). Its hosting-view background must be
     re-cleared after content attaches or it paints over the chart
     (`hostWindowAboveChart`).
- Gestures on the input window: one-finger pan with velocity fling, pinch zoom
  anchored at the centroid (a two-finger drag pans via the centroid at the same
  time), two-finger twist to rotate, tap to identify, double-tap /
  two-finger-tap to zoom in/out, pointer scroll-to-zoom + hover readout
  (trackpad/mouse). Pinch/pan verified end-to-end by the XCUITests.
- **Gotcha:** FrontBoard caches scene sessions per install. After changing the
  scene configuration (e.g. this lifecycle switch), a plain reinstall keeps the
  stale session and the SceneDelegate silently never connects — `simctl
  uninstall` (or delete the app) first.
- Charts arrive as files: the Files-app picker imports (copies) a `.pmtiles`
  cell or a folder of cells into `Documents/Charts`, and anything dropped into
  the app's Documents via Files/Finder sharing composes into the startup
  library.
- The Zig core calls `SDL_SetMainReady()` before `SDL_Init` (the host app owns
  `main()`, which SDL's UIKit backend otherwise objects to).

**Building the iOS target.** `xcodegen generate` also emits a
`LookoutMarine-iOS` target, but its native deps must be built for iOS first —
none come from Homebrew:

1. **SDL3 static for iOS** → `ios-deps/sdl3/` (`include/SDL3` + `lib/libSDL3.a`),
   e.g. `cmake -B build-ios -DCMAKE_SYSTEM_NAME=iOS -DSDL_STATIC=ON` from an SDL
   checkout.
2. **MoltenVK.xcframework** → `ios-deps/molten-vk/` (from a MoltenVK release or
   `make ios` in its repo). It is embedded in the app; if SDL's Vulkan loader
   doesn't find it at runtime, point the `SDL_VULKAN_LIBRARY` hint at the
   framework binary.
3. **tile57 for iOS**: `cd $TILE57_DIR && zig build -Dtarget=aarch64-ios
   --sysroot "$(xcrun --sdk iphoneos --show-sdk-path)" -p zig-out-ios`.
4. The target's pre-build script cross-builds `liblookout_marine.a` the same way
   (into `zig-out-ios/`), picking `aarch64-ios-simulator` automatically for
   simulator builds — build SDL3/tile57 for the simulator too in that case.

**Status: verified rendering in the iOS 27 simulator** (iPhone 17 Pro, Xcode 27
beta): the chart draws full-screen with the SwiftUI chrome floating above it,
charts auto-open from Documents, and the window layering works as designed.
What made it work (all baked in, no env vars needed at runtime):

- `SDL_SetMainReady()` + the `SDL_VULKAN_LIBRARY` hint pointing at
  `@rpath/MoltenVK.framework/MoltenVK` (src/gpu.zig — iOS has no system
  Vulkan loader).
- GPU device creation opts out of the Vulkan features SDL requests by default
  (`clip distance`, `depth clamping`, `indirect-draw first-instance`,
  `anisotropy`) — unused by 2D chart rendering, and the simulator GPU (GPU
  Family Apple 2) fails SDL's suitability check on them.
- **A local patch to our vendored SDL build** —
  `macos/sdl-ios-simulator-device-features.patch`, applied to
  `ios-deps/SDL-src` — demotes SDL's three always-required features
  (`independentBlend`/`imageCubeArray`/`sampleRateShading`) to
  disabled-when-unsupported so the simulator device isn't rejected outright.
  Local build only; do **not** submit upstream (SDL does not accept
  AI-authored contributions).
- The sprite atlas shrinks its bake density until it fits the device's max
  texture dimension (8192 on the simulator; a 3x bake is ~10.9k tall and an
  oversized Metal texture aborts, it doesn't error) — `src/root.zig
  loadSpriteAtlas`, with `atlas_scale` keeping scene UVs in step.
- On the simulator only, MoltenVK's Metal argument buffers are disabled
  (`MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0` set in-process): the simulator's
  Metal XPC service crashes encoding them. Real devices keep the default.
- The Zig archives are extracted to loose objects and repacked with `libtool`
  (project.yml pre-build script; `build-dev.sh` does the same for macOS) — both
  ld64 and libtool silently DROP zig-emitted archive members over an
  offset-alignment quirk.
- If you build from the CLI with `CODE_SIGNING_ALLOWED=NO`, ad-hoc sign the
  products before installing (`codesign -f -s -` on the MoltenVK framework
  binary, `LookoutMarine.debug.dylib`, and the app) — even the simulator
  refuses to dyld-load an unsigned embedded framework. Building in Xcode with
  default signing does this for you.

Still untested on a REAL device (needs a signing team + device builds of the
deps): the rotation gesture's sign (flagged in `ChartUIView.onRotate`), Metal
argument buffers on-device, and full-density (16384-cap) atlas baking.

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
- **iOS target.** Code-complete (see "iOS" above) but not yet built or run on a
  device: it needs Xcode plus iOS builds of SDL3, MoltenVK, and tile57.
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
