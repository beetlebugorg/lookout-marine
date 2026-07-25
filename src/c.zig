//! Shared engine C interop: tile57 (the chart engine + its draw-ready GPU-scene
//! ABI) and stb_image (atlas PNG decode). Used by root/capi/atlas and BOTH
//! renderer backends, so the tile57 types (tile57_gpu_scene, …) come from ONE
//! cImport and match across the seam (Zig treats types from separate @cImport
//! blocks as distinct). Platform transport headers live per-backend: the Metal
//! shim in c_metal.zig, SDL3 in c_sdl.zig.
pub const c = @cImport({
    @cInclude("tile57.h");
    @cDefine("STBI_NO_STDIO", "1");
    @cInclude("stb_image.h");
});
