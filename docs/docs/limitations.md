---
id: limitations
title: Known limitations
sidebar_position: 10
---

# Known limitations

lookout is a **prototype / proof-of-concept** — it proves the tile57 Surface
interface pairs well with `SDL_GPU`, and gives a usable embeddable chart widget.
It is **not** for navigation, not S-52 pixel-perfect, and makes no claim of ECDIS
correctness.

## Rendering fidelity

- **Line joins** are a simple miter; no true round/bevel joins or caps.
- **Dashes** are recorded but drawn solid.
- **Text halos** are dropped (fill only).
- **Pattern fills** render as the flat translucent tint the engine emits when the
  pattern callback is left off — no pattern atlas.
- Constant-width lines use an **isotropic-scale approximation** for the
  screen-space normal (fine north-up at chart aspect ratios).
- Symbols and text use the engine's tessellated **outline-ring** fallback, not an
  SDF / sprite atlas.
- **Decluttering** is whatever the engine resolves per view (or per tile for the
  compose path); there is no additional cross-tile label suppression.

## Portrayal

- The **SCAMIN → display-scale** mapping is approximate, not matched to the
  engine's exact cutoff.
- **Rotation** (course-up) is wired — the MVP rotates and MAP-aligned marks follow
  — but exercised mostly at north-up; rotated-view sign conventions for MAP marks
  are best-effort.
- Text sub-group flags (`text_names` vs. `show_light_descriptions` vs.
  `text_other`) are gated together as one live "text" toggle; exact per-group live
  control would need per-group tags in the stream.

## Scale

- A view that covers a very large area at a low zoom (e.g. fitting a whole
  multi-thousand-cell library) tessellates a lot of geometry — bounded per view,
  but heavy. Open at a working location and zoom/pan; the overscan + coverage
  model keeps interaction smooth from there.

## Platform

- Rendering needs a Vulkan / Metal / D3D12 driver (via SDL_GPU). Verified on Linux
  with Vulkan (including Mesa lavapipe for headless offscreen). On macOS a SPIR-V
  GPU device requires Vulkan/MoltenVK; a Metal-only device would need an MSL
  shader path (not yet built).
