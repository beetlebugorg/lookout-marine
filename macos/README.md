# Lookout Marine — the app (macOS + iOS/iPadOS)

A native SwiftUI S-52 chartplotter wrapped around the Zig chart core, which
renders via **Metal directly** into the chart view's own `CAMetalLayer`.
All app chrome (menu bar, HUD, zoom controls, mariner settings, search) is
native SwiftUI; the chart itself is one GPU-rendered view driven through the
`lookout.h` C ABI. (The cross-platform SDL_GPU/Vulkan/MoltenVK predecessor
lives at the `sdl-gpu` git tag.)

## Prerequisites

- **Xcode** — the deployment target is macOS 26 / iOS 26 (`macos/project.yml`).
- **Zig 0.16.0** on `PATH` (`brew install zig`).
- **XcodeGen** to generate the project (`brew install xcodegen`).
- **CMake** to build the WAMR runtime (`brew install cmake`).

tile57 is NOT a prerequisite: it's a zig package dependency of the core. A
sibling checkout at `../../tile57` is used when present (dev setups — engine
edits rebuild live); otherwise the commit pinned in `../build.zig.zon` is
fetched automatically on first build.

## Build & run

```sh
cd macos
xcodegen generate            # writes LookoutMarine.xcodeproj from project.yml
open LookoutMarine.xcodeproj
```

Pick a target and Run. The pre-build script runs
`zig build -Doptimize=ReleaseFast -Dplugins=true`, which builds the tile57
engine + the lookout core and installs the archives and headers into
`../zig-out*/` (per-platform prefixes for iOS device vs simulator); the app
links the libtool-repacked pair as `liblookoutall.a`. The Zig cores are
ReleaseFast in every configuration — build the app itself with Xcode's Release
configuration for a fully non-debug binary.

Nothing has to be built by hand first. The same phase runs
`../scripts/build-wamr.sh` for the platform being built, which produces the
WAMR archive the plugin host links, and a post-build phase runs
`zig build plugins` and copies the shipped set into `Resources/Plugins`. Both
are idempotent and cost a fraction of a second once built; the first run clones
and builds the pinned WAMR and takes a few minutes. `-Dplugins=true` is
explicit because its default is off when the archive is absent, which builds a
working app with no plugin host inside it, so no own ship, no AIS and no
laylines. Ahead-of-time plugin compilation is not part of this build:
`scripts/build-plugin-aot.sh` needs LLVM, and `load_aot_modules` in
`src/plugin/host.zig` is false, so nothing reads its output yet.

**No Xcode?** `macos/build-dev.sh [--zig]` builds the same app with just the
Command Line Tools (swiftc + a hand-rolled bundle). It fills the slot the Xcode
build fills, `macos/build-mac/Build/Products/Debug/LookoutMarine.app` — one app
path on disk, so there is never a second bundle to launch by mistake.

You need a baked `.pmtiles` chart to see anything: **File ▸ Open Chart…** picks a
`.pmtiles` file (or a folder of cells to compose a library). On first launch the
app also probes `$LOOKOUT_OPEN` (a chart, or a folder of cells — handy for dev
runs from the terminal), then the last recent, then the demo default
`~/.cache/chartplotter/NOAA/tiles/d5/US5MD1MC.pmtiles`. A second dev hook,
`$LOOKOUT_VIEW="lon,lat,zoom[,rot]"`, pins the opening camera (deterministic
framing for screenshots; `simctl launch` forwards both as `SIMCTL_CHILD_*`).

## What's in here

| File | Role |
|------|------|
| `LookoutMarineApp.swift` | `@main` App: window `ZStack`, Settings scene, commands; iOS AppDelegate/SceneDelegate + the two-window stack |
| `ChartView.swift` | macOS: `NSViewRepresentable` + backing `NSView` (input, on-demand loop). iOS: the chrome `OverlayLayer` + `ChartUIView`, the plain-UIKit gesture surface |
| `ChartController.swift` | `@MainActor` owner of the `lookout*` handle; the one funnel for every `lookout_*` call, the display-link render loop, and the `LOOKOUT_VIEW` dev hook |
| `AppModel.swift` | Shared observable state; open paths (`LOOKOUT_OPEN`, Documents, recents); coordinate parser |
| `MarinerSettings.swift` | Swift mirror of `tile57_mariner` (round-trips engine-only fields; persists as a versioned dictionary) |
| `SettingsView.swift` | The S-52 mariner form (⌘, / the gear) |
| `HUDOverlay.swift` | Own ship's position, 1:N scale, the band, the raster pill, the chart menu, the scale entry |
| `ZoomControls.swift` | Floating +/−/north bubbles |
| `SearchField.swift` | Coordinate go-to (feature search stubbed) |
| `OpenPanel.swift` | The Open Chart… pickers (NSOpenPanel / fileImporter hand-off) |
| `Commands.swift` | Native menu bar (macOS) |
| `Platform.swift` | The macOS/iOS seam: typealiases, display-link/scale helpers, the chrome hit map, PassThroughWindow |
| `project.yml` | XcodeGen target definition (all build settings + the zig pre-build) |

## iOS

The bulk of the app is platform-neutral and reused verbatim on iOS: `AppModel`,
`MarinerSettings`, `SettingsView`, `HUDOverlay`, `ZoomControls`, `SearchField`,
`OverlayLayer`, and all of `ChartController` (including the open path and the
display-link render loop). Platform code is isolated behind `#if os(...)` and
`Platform.swift`.

**Architecture.** iOS uses the UIKit lifecycle (AppDelegate + SceneDelegate, no
WindowGroup) with a two-window stack, bottom → top:

1. the **input window** — `ChartUIView` in plain UIKit, whose backing layer IS
   the chart's `CAMetalLayer` (lookout renders straight into it). Plain UIKit
   because SwiftUI's hosting view hit-tests as itself across its whole window
   and never forwards touches to UIKit subviews or window-attached recognizers
   (measured; see `LookoutMarine-iOS/UITests`) — a gesture surface inside
   SwiftUI renders fine but never hears a touch.
2. the **chrome window** — the SwiftUI overlay in a `PassThroughWindow`. Empty
   areas fall through to the input window; controls keep their touches. SwiftUI
   controls have no distinct hit-test views, so the pass-through decision
   consults the accessibility tree (interactive-trait element frames). Its
   hosting-view background must be re-cleared after content attaches or it
   paints over the chart (`hostWindowAboveChart`).

Gestures on the input window: one-finger pan with velocity fling, pinch zoom
anchored at the centroid, two-finger twist to rotate past a dead zone, and
double-tap / two-finger-tap to zoom in and out. A plain tap closes a pinned
bubble and does nothing else: what is at a point is asked for by name, from
the menu a press raises there, which this shell does not carry yet. There is no
scroll-to-zoom recognizer: `allowedScrollTypesMask` also fires on a pointer
drag, which then zoomed instead of panning. Pinch, pan and the chrome buttons
are verified end to end by the XCUITests.

**Building.** No dependency beyond this repo (tile57 arrives as the core's zig
package dependency; no SDL, no MoltenVK — rendering is direct Metal). Just
`xcodegen generate` and build/run the **LookoutMarine-iOS** scheme: the
pre-build script runs one `zig build` that cross-compiles the tile57 engine +
`liblookout_marine.a` for the active `PLATFORM_NAME` (device vs simulator,
separate `zig-out-*` prefixes) and repacks the archives for ld64 (both ld64
and libtool silently DROP zig-emitted archive members over an offset-alignment
quirk — the script extracts to loose objects and repacks; `build-dev.sh` does
the same for macOS). It resolves the iOS SDK from Xcode's own `$SDKROOT`, so
it works even when the shell's `xcode-select` points at the Command Line Tools
(which have no iOS SDK — the `xcrun … --show-sdk-path` you'd run by hand comes
back empty).

**Gotchas.** FrontBoard caches scene sessions per install: after changing the
scene configuration, a plain reinstall keeps the stale session and the
SceneDelegate silently never connects — `simctl uninstall` (or delete the app)
first. Charts arrive as files: the Files-app picker imports (copies) a
`.pmtiles` cell or a folder into `Documents/Charts`, and anything dropped into
the app's Documents via Files/Finder sharing composes into the startup
library. Still untested on a real device (needs a signing team): the rotation
gesture's sign (flagged in `ChartUIView.onRotate`).

## Rendering (Metal)

The core renders via Metal directly (`src/metal_shim.m` + the engine's
runtime-compiled `shaders/lookout.metal`): the host passes its `CAMetalLayer`
(`LOOKOUT_NATIVE_METAL_LAYER`) and lookout attaches a device, four pipelines
(chart / sprite / SDF / pattern) and presents drawables into it. Offscreen
snapshots render to a shared-storage texture and read back. This replaced the
SDL_GPU → Vulkan → MoltenVK stack and with it every driver workaround that
stack accumulated (indexed-draw corruption, swapchain-recreation
rasterization loss, validation-layer crashes, simulator argument-buffer
crashes, atlas-size aborts — see the `sdl-gpu` tag for the archaeology). The
Metal port was verified pixel-identical against the SDL renderer on the
snapshot suite (day / night palette / MVP zoom) before the switch.

## Testing

- **Core unit tests:** `zig build test` from the repo root (camera math, scene
  lifecycle).
- **Render parity / smoke:** `zig-out/bin/lookout-marine-demo <chart.pmtiles>`
  renders day / night / zoomed PNGs headlessly — the same core the app links.
- **Touch delivery (XCUITest):**
  ```sh
  xcodebuild test -project LookoutMarine.xcodeproj -scheme LookoutMarine-iOS \
    -destination 'platform=iOS Simulator,id=<UDID>'
  ```
  Pinch-zoom, pan, rotation survival, and chrome-button delivery — the
  contracts the two-window stack can silently break.
- **Env-gated helpers** (skipped in the normal plan): pass
  `TEST_RUNNER_LOOKOUT_SOAK=1` for a 60-second interaction soak (profiling a
  hot render loop), or `TEST_RUNNER_LOOKOUT_FRAME=1` to frame the chart in
  landscape and hold it for an outside `simctl io screenshot`.

## Deferred (noted so they aren't dropped)

- **Feature / place-name search.** The search field's coordinate go-to works now;
  name/feature search is stubbed and labelled "coming soon". It needs a name
  index in tile57 plus a matching `lookout_*` query — out of Phase-1 scope. We do
  not fake results.
- **Real-device run.** The simulator app is built and XCUITest-verified; a
  physical-device run still needs a signing team (and a check of the rotation
  gesture's sign — see `ChartUIView.onRotate`).
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
