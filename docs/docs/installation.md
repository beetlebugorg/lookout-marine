---
id: installation
title: Installation
sidebar_position: 2
---

# Installation

lookout is built with **Zig** and links the prebuilt tile57 engine plus system
SDL3. It vendors its only other dependency (libtess2).

## Requirements

| Dependency | What it's for | Notes |
|---|---|---|
| **Zig 0.16** | builds everything | the library, the demo, the C sources |
| **SDL3 ≥ 3.2** (with `SDL_gpu.h`) | window + GPU transport | `libsdl3-dev` / `brew install sdl3`. Internal — your app never links it. |
| **libtile57.a** | the chart engine | prebuilt from [tile57](https://github.com/beetlebugorg/tile57) (`zig build lib`) |
| **glslangValidator** | GLSL → SPIR-V | only for `zig build shaders`; compiled SPIR-V is committed |
| **libtess2** | polygon / glyph tessellation | vendored under `vendor/` — nothing to install |

A Vulkan (or Metal / D3D12) driver is needed at run time. On a headless Linux box,
Mesa **lavapipe** (software Vulkan) works for offscreen rendering.

## Build

```sh
zig build                 # builds liblookout.a + the lookout demo into zig-out/
zig build -Dtile57=/path/to/tile57   # point at your tile57 checkout
zig build test            # unit tests
zig build shaders         # recompile GLSL -> SPIR-V (needs glslangValidator)
```

`-Dtile57` defaults to a sibling checkout; it expects `<dir>/include/tile57.h` and
`<dir>/zig-out/lib/libtile57.a`. Build tile57 first with its own `zig build lib`.

Outputs:

- `zig-out/lib/liblookout.a` — the static library (the core).
- `zig-out/include/lookout.h` — the C ABI header.
- `zig-out/bin/lookout` — the demo executable.

## Shaders

The renderer uses a single flat-color pipeline; its two shaders
(`shaders/chart.vert`, `shaders/chart.frag`) are authored in GLSL 450 and the
compiled **SPIR-V is committed** (`shaders/*.spv`, embedded via `@embedFile`), so a
normal build needs no shader compiler and there is **no runtime shader
compilation**. `zig build shaders` regenerates the SPIR-V if you edit the GLSL.
