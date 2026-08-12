//! What remains of the renderer-backend selector on the MapLibre branch.
//! MapLibre Native draws the chart here; the native Metal/Vulkan/D3D12/SDL
//! pipelines live on main. gpu_metal survives as the surface HOLDER — the
//! light contract that keeps the CAMetalLayer for the ml host to attach
//! MapLibre's render session to (it creates no device and no pipelines).
const impl = @import("gpu_metal.zig");

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
