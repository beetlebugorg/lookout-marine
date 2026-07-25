//! Renderer backend selector. Two backends implement the same `Gpu` API behind
//! this file, so root/capi/main import `gpu` and never name a backend:
//!   * Apple (macOS / iOS / iPadOS) -> gpu_metal.zig (direct Metal)
//!   * everything else (Android, Windows, Linux) -> gpu_sdl.zig (SDL3 + SDL_GPU,
//!     which is Vulkan on Android/Linux, D3D12/Vulkan on Windows, Metal on macOS)
//! The build picks one via `-Dbackend` (see build.zig -> build_options.gpu_sdl);
//! the default is Metal on Apple, SDL_GPU elsewhere. Both expose: Gpu (+ its
//! Scene), Uniforms, Options, NativeKind, Color, ticksMs, ticksUs.
const impl = if (@import("build_options").gpu_sdl)
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
