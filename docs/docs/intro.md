---
id: intro
title: Introduction
slug: /
sidebar_position: 1
---

# lookout

:::warning Not for navigation

This is a prototype / proof-of-concept, coded with AI (Claude) and human-reviewed.
It is **not** S-52 pixel-perfect and makes no claim of ECDIS correctness. **Do not
rely on it for real-world navigation.** See [Known limitations](./limitations.md).

:::

**lookout** is an embeddable **chart-rendering widget**. It opens a baked
[**tile57**](https://github.com/beetlebugorg/tile57) nautical chart (or composes a
whole library), and draws it as an interactive, pannable / zoomable S-52 chart on
the GPU using **SDL3's `SDL_GPU`** backend (Vulkan / Metal / D3D12). You drop it
into your own app — the host writes the shell (Swift/Cocoa, Win32, GTK, Qt, a game
engine) and lookout renders the chart into a native window or a pixel buffer.

![Annapolis Harbor, day scheme](/img/day.png)

## Why it exists

tile57 turns S-57 / S-101 charts into a **world-space, semantically-tagged
draw-call stream** — its *Surface interface*. That stream is designed to be
**tessellated once and transformed per frame**: geometry stays in web-mercator
space in GPU buffers, and pan / zoom / rotate / day-night / mariner toggles are
expressed as cheap per-frame state. lookout is the renderer that consumes that
stream on `SDL_GPU` and proves the pairing works.

The host never sees SDL. lookout owns the window transport, the GPU device, the
polygon tessellation, line stroking, glyph/symbol tessellation, paint ordering,
the camera, level-of-detail, and per-frame gating — and exposes a small, stable
C ABI (and a Zig API) meant to carry a chartplotter on top: a boat marker, a
route, tap-to-identify.

## What you get

- **Open** one baked chart or **compose** a directory of them (a chart library /
  ENC_ROOT cache), stitched through tile57's ownership partition.
- **Embed** into your app's native window (`NSWindow` / `NSView` / `HWND` / X11)
  — SDL is an internal detail — or pull **RGBA frames** to upload yourself.
- **Drive** the view: pan, cursor-anchored zoom, course-up rotation, resize,
  `screen ↔ geo` for overlays and picks.
- **Control** the full S-52 mariner state: day / dusk / night palette, display
  categories, safety contour, text and sounding gates, size scaling.
- **Smooth** by construction: tessellation runs on a worker thread (opening a big
  library never freezes the window), zooming across bands re-tessellates for fresh
  level-of-detail without blocking, and day/night is a color-buffer swap — never a
  geometry rebuild.

## Next

- [Installation](./installation.md) — toolchain and building.
- [Getting started](./getting-started.md) — open a chart and render a frame.
- [Embedding](./embedding.md) — put the widget in your app.
