//! All C interop in one place: the Metal shim (window + GPU transport, ObjC
//! behind a C face), tile57 (the chart engine + its draw-ready GPU-scene ABI),
//! and stb_image (atlas PNG decode).
pub const c = @cImport({
    @cInclude("metal_shim.h");
    @cInclude("tile57.h");
    @cDefine("STBI_NO_STDIO", "1");
    @cInclude("stb_image.h");
});
