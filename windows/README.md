# Lookout Marine — the app (Windows / WinUI 3)

A native **WinUI 3** (Windows App SDK, C++/WinRT) chartplotter around the Zig
chart core. The Windows counterpart of the SwiftUI shell on macOS/iOS, the GTK4
shell on Linux, and the Java shell on Android: same core, same C ABI, same
behaviour.

The chart presents through one of two paths. The app selects the path at open:

1. **DXGI composition (default).** The shell owns a D3D12 device and a
   composition swapchain on a `SwapChainPanel`. The core imports two shared
   textures and a shared fence (`LOOKOUT_NATIVE_DXGI_TARGET`), renders with
   Vulkan, and signals the fence. The shell copies to the back buffer and
   presents. XAML chrome floats over the chart with no window tricks. This is
   the Windows form of the macOS `CAMetalLayer` transport. It needs a GPU whose
   Vulkan driver has `VK_KHR_external_memory_win32`.
2. **Child HWND (fallback).** On a device with no Vulkan/D3D12 interop, the
   core presents into a child HWND placed over the XAML content. A window
   region cuts holes where the chrome is. The chrome shows and receives input
   through the holes.

## Prerequisites

- **Windows 11**, **Visual Studio 2022+** with the C++ workload, **Windows SDK
  10.0.22621+**.
- **Zig 0.16** on `PATH`.
- **Vulkan SDK** (the loader import library, `vulkan-1.lib`).
- NuGet restores `Microsoft.WindowsAppSDK` and `Microsoft.Windows.CppWinRT`
  on the first build.

tile57 is **not** a prerequisite: it is a Zig package dependency of the core.

## Build & run

```powershell
pwsh windows/build-core.ps1     # zig build lib -Dbackend=vk -> ../zig-out
cd windows
msbuild LookoutMarine.vcxproj -t:Restore /p:Configuration=Release /p:Platform=ARM64
msbuild LookoutMarine.vcxproj /p:Configuration=Release /p:Platform=ARM64
.\ARM64\Release\LookoutMarine.exe
```

Use `/p:Platform=x64` on an x64 machine. The app is unpackaged and
self-contained: the build copies the Windows App SDK runtime next to the exe.

You need a baked `.pmtiles` chart to see anything. **Open** (top-left bubble)
takes one chart or a folder of cells. On first launch the app probes
`$LOOKOUT_OPEN`, then the last recent, then the repo's bundled test cell.

Environment variables: `LOOKOUT_OPEN=<chart|dir>` opens at startup.
`LOOKOUT_FORCE_HWND=1` skips the DXGI path. `LOOKOUT_OPEN_SETTINGS=1` opens the
mariner pane at startup (screenshots).

## What's in here

| File | Role |
|------|------|
| `ui/MainWindow.xaml.cpp` | Window construction, chrome wiring, the render thread |
| `ui/MainWindow.Open.cpp` | Open flow, layers flyout, pickers, both present paths |
| `ui/MainWindow.ChartHost.cpp` | Fallback child HWND, inverse region, Win32 chart input |
| `ui/MainWindow.Input.cpp` | Gestures, commands, pick, coordinate search |
| `ui/MainWindow.Hud.cpp` | Readout capsule and the scale bar |
| `ui/MainWindow.Settings.cpp` | The mariner pane: tabbed pages, debounced apply |
| `ui/winrt_glue.cpp` | Compiles the XAML-generated TUs a command-line build does not auto-register |
| `src/lk_controller.*` | The one `lookout*` handle; every `lookout_*` call; render-loop helpers |
| `src/lk_d3d.*` | D3D12 device, composition swapchain, shared textures + fence |
| `src/lk_store.*` | Camera pose, recents and mariner settings in `%APPDATA%\lookout-marine\settings.ini` |
| `src/lk_coord.*` | Coordinate go-to parser and DMS formatting |
| `src/lk_paths.*`, `src/lk_format.*`, `src/lk_backdrop.*` | Chart discovery, HUD formatting, the transparent backdrop |
| `build-core.ps1` | Builds the Zig core where the vcxproj expects its outputs |

Notes:

- The core renders on a dedicated thread. Software Vulkan frames take over
  100 ms; on the UI thread they starve XAML's own rendering.
- Do not set a window region on WinUI's content bridge window. The second
  region change permanently blanks the island's content. The fallback clips
  the chart child instead (an inverse region).
- On a machine with no Vulkan driver, install a software ICD (Mesa lavapipe)
  and register its JSON under `HKLM\SOFTWARE\Khronos\Vulkan\Drivers`.
