---
id: architecture
title: Architecture
sidebar_position: 1
---

# Architecture

Lookout has one shared chart core and several native app shells. The core does all
of the portable work. The core has no user interface, and it does not specify one.
Each shell controls how the app looks and behaves on its platform. The shells and
the core connect through one C ABI.

The SwiftUI shell for Mac and iPad is the reference for behavior. It came first and
it is the most complete. The Linux host and the Android host match its behavior in
their own idiom.

```
             macos/                 linux/                android/
        SwiftUI (Mac/iPad)      GTK4 in C            Java + SurfaceView
                │                    │                     │
                └────────────┬───────┴─────────────────────┘
                             ▼
                    include/lookout.h          the full contract
                             │
                    ┌────────┴─────────┐
                    │  lookout core    │       src/*.zig
                    │  camera · scene  │
                    │  GPU transport   │       Metal · Vulkan
                    └────────┬─────────┘
                             ▼
                        tile57 engine          S-57 decode, S-101 portrayal,
                                               tessellation, atlases, tiles
```

## The two parts

**The core** is in `src/`. The core opens a baked chart or a chart library. Then
the core asks the engine for a GPU scene. The scene contains vertices, quads, the
paint order, and a color buffer for each scheme. The core uploads the scene one
time.

The core then renders each frame. To render one frame, the core writes one uniform
block. The vertex shader applies the camera, the palette, the display-category
gates, and the SCAMIN limits. Therefore the core does not tessellate the chart
again when you pan it or when you change the scheme. Each frame is only a uniform
update.

**A shell** makes a native view. The shell gives the surface of that view to the
core. Then the shell controls the core:

```c
lookout *lk = lookout_open_charts_in_window(kind, native, paths, n, w, h, msaa);
lookout_set_view(lk, &view);          lookout_pan_logical(lk, dx, dy);
lookout_set_mariner(lk, &mariner);    lookout_zoom_at_logical(lk, dz, x, y);
lookout_render(lk);                   lookout_pick(lk, lon, lat, &cb);
```

The shell owns all of the other parts of the app. These parts include the menus,
the HUD, the settings forms, the gestures, and the persistence. The shell writes
them in the idiom of its platform. The core does not know that widgets exist.

**The engine** is [tile57]. The engine does the largest tasks: ISO 8211 and S-57
decode, S-101 portrayal with embedded Lua rules, tessellation, sprite and SDF
atlases, and tile composition. The build uses the engine as a Zig package
dependency. If a sibling `../tile57` checkout is available, the build uses it. If
it is not available, the build gets the commit that `build.zig.zon` specifies.
`zig build` then compiles the engine from source.

## Why the structure is correct

The ABI is the reason that many shells stay easy to maintain. Refer to
[the experiment](https://github.com/beetlebugorg/lookout-marine#how-we-use-ai).
A shell can use only `lookout.h` to reach the core. This limit gives three results:

- **One shell cannot depend on another shell.** There is no shared widget layer.
  A change to the GTK window cannot break SwiftUI.
- **A shell can be different from the other shells.** The Linux host draws the
  chart in a way that no other platform uses. It puts a Vulkan subsurface below a
  transparent hole in the window. The other shells do not see this difference,
  because the Linux host still calls `lookout_render`.
- **Each behavior has one specification.** One core function anchors the zoom below
  the pointer. Each shell only selects which gesture calls that function.

## GPU backends

The core has one design and four GPU transports. You select the transport when
you build the core with `-Dbackend=`.

| Backend | Platforms | Surface |
|---|---|---|
| `metal` | macOS, iOS/iPadOS | `CAMetalLayer` (`src/metal_shim.m`; the shim compiles the shaders at run time) |
| `vk` | Linux, Android | Wayland surface, X11 window, or `ANativeWindow`; precompiled SPIR-V |
| `d3d12` | Windows | A composition swapchain the host attaches to a `SwapChainPanel` (`src/d3d12_shim.c`; the shim compiles the HLSL at run time; WARP when there is no GPU driver) |
| `sdl` | Any platform for comparison | `SDL_GPU` |

The shaders are not in this repository. The shaders read the vertex, quad, and
uniform layouts that tile57 defines. Therefore the shaders stay with those layouts,
and this build embeds them from the dependency.

A headless program does not need a window. It gets each frame with
`lookout_snapshot_rgba`. `lookout-marine-demo` uses this function to write parity
PNG files.

## The hosts

| Host | Toolkit | Notes |
|---|---|---|
| macOS / iPadOS / iOS | SwiftUI | **The reference for behavior.** Mac and iOS share the Swift sources. Refer to `macos/README.md`. |
| [Linux](hosts-linux.md) | GTK4, C | A Vulkan subsurface below a transparent hole. The chrome floats above the chart. |
| Android | Java | Vulkan draws into a `SurfaceView`. The Java shell owns the Activity. Refer to `android/README.md`. |
| Windows | WinUI 3, C++/WinRT | The core's D3D12 composition swapchain on a `SwapChainPanel`; the XAML chrome floats above. Refer to `windows/README.md`. |

Each host captures its screenshots to one specification. You can then compare the
hosts frame by frame. Refer to [the screenshot protocol](screenshots.md).

## Files

```
build.zig, build.zig.zon   the build and the tile57 dependency pin
include/lookout.h          the C ABI — the full shell-to-core contract
src/root.zig               Lookout: the scene lifecycle and worker-thread rebuilds
src/camera.zig             web-mercator camera math (MVP, screen<->geo, SCAMIN)
src/gpu.zig                the backend switch
src/gpu_vk.zig             the Vulkan transport (Linux and Android)
src/gpu_metal.zig          the Metal transport (with src/metal_shim.{h,m})
src/gpu_d3d12.zig          the Direct3D 12 transport (with src/d3d12_shim.{h,c})
src/gpu_sdl.zig            the SDL_GPU transport
src/capi.zig               the C ABI wrapper
src/main.zig               the headless render and parity demo
macos/                     the SwiftUI app (macOS and iOS/iPadOS), XcodeGen spec
linux/                     the GTK4 app, meson
android/                   the Java shell, gradle
windows/                   the WinUI 3 app, msbuild
vendor/stb                 stb_image (it decodes the atlas PNG files)
```

[tile57]: https://github.com/beetlebugorg/tile57
