# Lookout Marine — the app (Windows / WinUI 3)

A native **WinUI 3** (Windows App SDK, C++/WinRT) chartplotter around the Zig
chart core. The Windows counterpart of the SwiftUI shell on macOS/iOS, the GTK4
shell on Linux, and the Java shell on Android: same core, same C ABI, same
behaviour.

![Annapolis Harbor and the Naval Academy, day scheme](../docs/docs/img/windows-day.webp)

The core renders with **Direct3D 12**, the Windows form of the macOS Metal
transport. The core owns the device, the pipelines (HLSL, compiled at
runtime), and a composition swapchain. The shell attaches that swapchain to a
`SwapChainPanel` (`ISwapChainPanelNative::SetSwapChain`) and the XAML chrome
floats over the chart. On a machine with no GPU driver the core selects
**WARP**, the in-box software rasterizer, so the app runs everywhere.

## Prerequisites

- **Windows 11**, **Visual Studio 2022+** with the C++ workload, **Windows SDK
  10.0.22621+**.
- **Zig 0.16** on `PATH`.
- NuGet restores `Microsoft.WindowsAppSDK` and `Microsoft.Windows.CppWinRT`
  on the first build.

tile57 is **not** a prerequisite: it is a Zig package dependency of the core.

## Build & run

```powershell
pwsh windows/build-core.ps1     # zig build lib -Dbackend=d3d12 -> ../zig-out
cd windows
msbuild LookoutMarine.vcxproj -t:Restore /p:Configuration=Release /p:Platform=ARM64
msbuild LookoutMarine.vcxproj /p:Configuration=Release /p:Platform=ARM64
.\ARM64\Release\LookoutMarine.exe
```

Use `/p:Platform=x64` on an x64 machine. The app is unpackaged and
self-contained: the build copies the Windows App SDK runtime next to the exe.

### Plugins

Own ship, AIS, NMEA 0183, Signal K and laylines are wasm plugins, and the host
that runs them needs a WAMR archive built for this platform. Build it once:

```powershell
bash scripts/build-wamr.sh windows-arm64   # or windows-x64
```

Both targets write the **MSVC-ABI** archive with `zig cc`, into
`vendor/wamr-dist-windows-arm64` or `-x64`. The ABI matters: the mingw archive
the cross targets produce does not meet the shipping app, and the headers must
be compiled with `WASM_API_EXTERN` and `WASM_RUNTIME_API_EXTERN` empty or the
runtime declares its own API `dllimport` and the app's link ends in three
unresolved `__imp_` symbols. On a machine without the Windows SDK,
`bash scripts/build-wamr.sh windows-x64 --print-msvc` prints the cmake command
to run there instead.

With the archive in place `build-core.ps1` passes `-Dplugins=true` and
normalizes `libvmlib.a` to `vmlib.lib`, which the vcxproj links after
`lookout_marine.lib`. Without it the script builds a core with no host, warns,
and removes any stale `vmlib.lib` — that build is a chartplotter with no own
ship, no traffic and no instrument input.

The modules travel beside the exe in `$(OutDir)plugins`, and the app loads them
at every chart open, then the set a mariner installed under
`%APPDATA%\Lookout Marine\Plugins`. `LOOKOUT_PLUGINS=<dir>` overrides both.

Plugin settings are filed with the chart settings they belong to: an AIS alarm
lands under **Alarms**, connections under **Connections**. Those tabs appear
only while a plugin puts something in them.

You need a baked `.pmtiles` chart to see anything. Open one from the empty
state's **Open Charts…**, with **Ctrl+O**, or from **Settings ▸ Charts** (the
recents live there too). On first launch the app probes `$LOOKOUT_OPEN`, then
the last recent, then the repo's bundled test cell.

Environment variables: `LOOKOUT_OPEN=<chart|dir>` opens at startup.
`LOOKOUT_VIEW=lon,lat,zoom[,rot]` pins the opening camera. `LOOKOUT_WARP=1`
forces the software rasterizer. `LOOKOUT_OPEN_SETTINGS=1` opens the mariner
settings at startup, and `LOOKOUT_OPEN_SETTINGS=<section>` (`connections`,
`plugins`, …) opens them on one section (screenshots). `LOOKOUT_SHOW=pick` (or
`pick:0.5x0.85`, a view fraction) runs a cursor pick 3 s after the chart
opens — the screenshot protocol's pick frame. `LOOKOUT_NMEA=host:port` seeds
the NMEA 0183 plugin with one connection, and `LOOKOUT_PLUGINS=<dir>` loads a
developer copy of a plugin ahead of the bundled set.

Raster charts (see `docs/docs/user-guide/raster-charts.md`): **Ctrl+Shift+I**
adds `.mbtiles` files (Settings ▸ Charts also takes a folder), **Ctrl+I** steps
between the sets covering the view, **Ctrl+Shift+H** hides the ENC where a
picture covers it. The pill at the right of the readouts opens the same list.

Plugins: an alarm a plugin raises shows at the top of the chart and sounds
until acknowledged. The AIS bubble by the search opens the vessel tables the
plugins declare. The GPS pill in the readouts names the position source and
opens Settings at Connections; the north bubble is the follow lock (tap to
follow own ship, tap again for course up; a pan lets go). A `.lkplug` dropped
on the chart shows its permissions before anything installs; capability grants
live in Settings ▸ Plugins. One copy runs per machine (`LOOKOUT_MULTI=1`
lifts it); `LOOKOUT_CLEAN=1` keeps every plugin on its manifest defaults for
captures.

## The source tree

`src/` has a directory per area of the app, and each one holds **both** the
WinUI that draws that area and the model that drives it: the pick report card
sits with the pick decoder, the raster pill with the raster paths, the
connection list with the registry reader. A change to one feature is a change
in one directory.

The model files carry no WinRT — that is what lets `build-tests.ps1` link them
into a test binary with no XAML host (see **Tests** below). The vcxproj marks
each of them `NotUsing` for the precompiled header to keep it honest.

| Directory | What it is |
|---|---|
| `src/app/` | The two XAML types (`App`, `MainWindow`), the window shell and the render thread, the menu bubble, and the glue that compiles the XAML-generated TUs a command-line build does not auto-register |
| `src/chart/` | The chart surface: the open flow and the panel, gestures and commands, the mariner's markers, the pick report card and the files a pick points at, and `lk_pick` — the report envelope decoder |
| `src/hud/` | The readout capsule and the scale bar, the startup loader phases, the overlay bubbles and the GPS and follow pills, the zoom-to-scale panel, and `lk_format` — the readout formatting and the chrome palette |
| `src/library/` | The charts aboard: the sets and their switches, charts by link, the raster underlay and its pill, the import and bake, and `lk_paths` / `lk_bake` behind them |
| `src/plugins/` | Everything the wasm plugins reach: their settings sections and connection lists, the `.lkplug` consent sheet and install, the table windows, the alert strip and siren, DNS-SD discovery, and the `lk_plugin_registry` / `lk_alerts` models |
| `src/settings/` | The mariner settings window: the section list, the pages, the debounced apply |
| `src/about/` | About and the licences screen, over the `lk_licenses` manifest model |
| `src/engine/` | The seams: `lk_controller` (the one `lookout*` handle and every `lookout_*` call), `lk_store` (`%APPDATA%\lookout-marine`), `lk_backdrop` (the transparent backdrop) |
| `src/util/` | What every area uses and none of them owns: `lk_json`, `lk_utf8`, `lk_coord` |
| `test/` | The model layer's tests and the check harness they are written against |

At the root: `build-core.ps1` builds the Zig core where the vcxproj expects its
outputs, `build-tests.ps1` builds and runs the tests, `pch.h` is the WinRT
precompiled header, and `LookoutMarine.rc` / `resource.h` / `LookoutMarine.ico`
are the app icon as a Win32 ICON resource.

## Tests

```powershell
pwsh windows/build-tests.ps1
```

The suite covers the shell's **model**: the coordinate and scale parsers, the
JSON reader every seam with the core goes through, the pick report decoder, the
licence manifest, the plugin registry and the config object that goes back, and
the alert rules. Not the WinUI layer, which needs a XAML host.

It builds with `zig`, not MSVC, on purpose: `zig` is already a prerequisite of
this shell, so the tests run for anyone who can build the app — including on a
machine with no Visual Studio. Nothing in the suite links the core or WinRT,
which is what keeps that true.

## The app icon

This app is unpackaged (`WindowsPackageType=None`, `AppxPackage=false`), so
there is no `Package.appxmanifest` and no `Logo` element to point at. The icon
reaches the executable the classic way instead: `LookoutMarine.rc` declares it
as `IDI_APPICON ICON "LookoutMarine.ico"` and the vcxproj compiles that with
`ResourceCompile`. The id is 1, because Explorer, the taskbar and Alt-Tab show
the ICON resource with the lowest id.

That covers the executable. A window is separate — an HWND wears whatever
`WM_SETICON` gave it — so `MainWindow`'s constructor loads the same resource at
the system icon sizes and sets it on the window, or the titlebar keeps the stock
WinUI mark. That is what `user32.lib` is in the link line for.

Regenerate the `.ico` from the brand master with `assets/brand/mkico.py`, which
packs the 256 frame as PNG and the rest as DIBs (ImageMagick's one-liner writes
every frame uncompressed, tripling the file for no gain).

Notes:

- The core renders on a dedicated thread. WARP frames can take tens of ms; on
  the UI thread they starve XAML's own rendering.
- The panel's visual carries the XAML composition scale. The swapchain is in
  device pixels, so the shell sets the inverse scale on the swapchain
  (`IDXGISwapChain2::SetMatrixTransform`) after attach and on a DPI change.
