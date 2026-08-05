//! Renderer backend selector. Four backends implement the same `Gpu` API behind
//! this file, so root/capi/main import `gpu` and never name a backend:
//!   * Apple (macOS / iOS / iPadOS) -> gpu_metal.zig (direct Metal)
//!   * Android / Linux -> gpu_vk.zig (direct Vulkan onto the shell's surface)
//!   * Windows -> gpu_d3d12.zig (direct D3D12 into a composition swapchain)
//!   * gpu_sdl.zig (SDL3 + SDL_GPU) remains as the portable fallback
//! The build picks one via `-Dbackend` (see build.zig -> build_options). All
//! expose: Gpu (+ its Scene), Uniforms, Options, NativeKind, Color, ticksMs,
//! ticksUs.
const bo = @import("build_options");
const impl = if (bo.gpu_vk)
    @import("gpu_vk.zig")
else if (bo.gpu_d3d12)
    @import("gpu_d3d12.zig")
else if (bo.gpu_sdl)
    @import("gpu_sdl.zig")
else
    @import("gpu_metal.zig");

pub const Gpu = impl.Gpu;
pub const Uniforms = impl.Uniforms;
pub const Options = impl.Options;
pub const NativeKind = impl.NativeKind;
pub const Color = impl.Color;
pub const ticksMs = impl.ticksMs;
pub const ticksUs = impl.ticksUs;
/// The raster underlay (src/raster.zig): one tile's texture, and one tile's
/// draw. Opaque to the layer, which only holds them.
pub const RasterTex = impl.RasterTex;
pub const RasterDraw = impl.RasterDraw;
