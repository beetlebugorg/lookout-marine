---
id: architecture
title: Architecture
sidebar_position: 9
---

# Architecture

lookout consumes tile57's **Surface interface** — a world-space, semantically
tagged draw-call stream — and follows its core contract: **tessellate once,
transform per frame**.

## One vertex format, one pipeline

The whole chart is a single flat-color pipeline. Every vertex carries:

- a **world** position in web-mercator `[0,1]` (stored camera-relative as f32 so
  precision holds anywhere on earth);
- a **local** reference-px offset the shader adds in *screen* space — line
  half-width, glyph/symbol px — so marks hold a constant screen size;
- a **SCAMIN** denominator and packed **flags** (display category, kind, rotation
  alignment).

The vertex shader (`shaders/chart.vert`) applies a per-frame MVP and **culls live
from uniforms**: display-category mask, current display-scale vs. the vertex's
SCAMIN, and text/sounding kind flags. Culled triangles collapse off-clip. Colors
come from a **per-scheme color buffer** bound alongside the geometry, so day ↔
night is a buffer swap — never a geometry rebuild.

Because line width and symbol/text size live in the `local` px channel and are
added *after* the MVP, pan / zoom / rotate are pure per-frame transforms, and
symbols and text stay a constant screen size while contour lines stay a constant
screen width.

## The two phases

**Build (worker thread).** Drive the Surface with recording callbacks that
tessellate areas (libtess2, holes + even-odd), stroke lines, and tessellate
symbol/glyph outline rings, packed into one interleaved vertex stream + one color
stream per palette, sorted into S-52 paint order (class-major, then draw
priority, then emission). Soundings arrive through `draw_symbol` (`cls=="SOUNDG"`)
as digit glyphs; text arrives already decluttered by the engine.

**Frame (UI thread).** Update the MVP from the camera, resolve the active palette
and gates into uniforms, and issue the draws. Nothing re-tessellates.

## Scaling: overscan, coverage, on-demand

Following [chartplotter-fyne](https://github.com/beetlebugorg/chartplotter-go)'s
performant model:

- The build **overscans** the viewport (1.5×), so panning within the margin
  re-transforms the same buffers.
- A rebuild fires **only when the view pans or zooms out of coverage**, on the
  worker thread; the old scene renders until the new one lands (no flicker, no
  freeze — opening a big library never blocks the window).
- Rendering is **on demand**: `needsRedraw()` is true only when the view/state
  changed or a build is filling in, so a static chart burns no CPU.
- The CPU tessellation is **freed as soon as it is uploaded** to the GPU — the two
  copies never coexist.

## SDL is internal

SDL3 is the window transport + `SDL_GPU` device, wrapped entirely inside lookout.
Hosts embed via a native window handle or a pixel readback and never link SDL.
Shaders are precompiled SPIR-V (no runtime compilation). MSAA is used when the
device supports it, resolving into the swapchain (windowed) or the readback target
(offscreen).

## Where the design deviates from the S-52 ideal

lookout is a prototype. Line joins are a simple miter, dashes render solid, text
halos are dropped, pattern fills render as the engine's flat tint, and the SCAMIN→
display-scale mapping is approximate. See [Known limitations](./limitations.md).
