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

## What's in here

| File | Role |
|------|------|
| `ui/MainWindow.xaml.cpp` | Window construction, chrome wiring, the render thread |
| `ui/MainWindow.Open.cpp` | Open flow, pickers, the chart panel |
| `ui/MainWindow.Input.cpp` | Gestures, commands, coordinate search |
| `ui/MainWindow.Hud.cpp` | Readout capsule and the scale bar |
| `ui/MainWindow.Loader.cpp` | The startup loader phases (atlas / mapping / tessellating) |
| `ui/MainWindow.Pick.cpp` | The pick report card: ranked pick, object list, decoded rows, raw fold |
| `ui/MainWindow.Scale.cpp` | The zoom-to-scale panel on the HUD's 1:N readout |
| `ui/MainWindow.Raster.cpp` | The raster pill and its menu, the add flow, the re-install at every open |
| `ui/MainWindow.PickAux.cpp` | The files a pick points at (TXTDSC/PICREP) and the picture viewer |
| `ui/MainWindow.Settings.cpp` | The mariner settings window: the section list, the pages, debounced apply |
| `ui/MainWindow.Plugins.cpp` | The plugin-declared settings sections, the connection list, capability grants, apply and save |
| `ui/MainWindow.Alerts.cpp` | The alert strip and the siren: an alarm sounds and repeats until acknowledged |
| `ui/MainWindow.Vessels.cpp` | Plugin table windows (AIS Targets): shell-side units, seq-gated reload, reveal on chart |
| `ui/MainWindow.PluginInstall.cpp` | The .lkplug consent sheet, install, and the dropped-file router |
| `ui/MainWindow.Overlay.cpp` | The bubble pinned to an overlay object, the hover tip, the GPS pill, the follow lock |
| `src/lk_plugin_model.h` | The shape the plugin registry takes on this side |
| `ui/winrt_glue.cpp` | Compiles the XAML-generated TUs a command-line build does not auto-register |
| `src/lk_controller.*` | The one `lookout*` handle; every `lookout_*` call; render-loop helpers |
| `src/lk_store.*` | Camera pose, recents, mariner settings and the raster chart list in `%APPDATA%\lookout-marine\settings.ini` |
| `src/lk_coord.*` | Coordinate go-to parser and DMS formatting |
| `src/lk_paths.*`, `src/lk_format.*`, `src/lk_backdrop.*` | Chart discovery, HUD formatting, the transparent backdrop |
| `build-core.ps1` | Builds the Zig core where the vcxproj expects its outputs |
| `LookoutMarine.rc`, `resource.h` | The app icon as a Win32 ICON resource |
| `LookoutMarine.ico` | The icon itself: 16/32/48/64/128/256 in one container |

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
