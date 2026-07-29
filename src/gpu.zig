//! Renderer backend selector. Three backends implement the same `Gpu` API behind
//! this file, so root/capi/main import `gpu` and never name a backend:
//!   * Apple (macOS / iOS / iPadOS) -> gpu_metal.zig (direct Metal)
//!   * Android -> gpu_vk.zig (direct Vulkan onto the Java shell's ANativeWindow)
//!   * Windows / Linux -> gpu_sdl.zig (SDL3 + SDL_GPU: D3D12/Vulkan; also
//!     `-Dbackend=sdl` on macOS to exercise that path via SDL_GPU -> Metal)
//! The build picks one via `-Dbackend` (see build.zig -> build_options); the
//! default is native on mobile, SDL on extended platforms. All expose: Gpu (+
//! its Scene), Uniforms, Options, NativeKind, DmabufFrame, Color, ticksMs,
//! ticksUs.
const bo = @import("build_options");
const impl = if (bo.gpu_vk)
    @import("gpu_vk.zig")
else if (bo.gpu_sdl)
    @import("gpu_sdl.zig")
else
    @import("gpu_metal.zig");

pub const Gpu = impl.Gpu;
pub const Uniforms = impl.Uniforms;
pub const Options = impl.Options;
pub const NativeKind = impl.NativeKind;
pub const DmabufFrame = impl.DmabufFrame;
pub const Color = impl.Color;
pub const ticksMs = impl.ticksMs;
pub const ticksUs = impl.ticksUs;
