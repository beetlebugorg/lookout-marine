//! Metal-backend C interop: the ObjC Metal shim (window + GPU transport behind a
//! C face). Apple-only; used solely by gpu_metal.zig. tile57 / stb types come
//! from the shared c.zig so they match across the renderer seam.
pub const c = @cImport({
    @cInclude("metal_shim.h");
});
