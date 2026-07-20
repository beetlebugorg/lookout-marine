//! All C interop in one place: SDL3 (window + GPU transport), tile57 (the chart
//! engine + its draw-ready GPU-scene ABI), and stb_image (atlas PNG decode).
pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("tile57.h");
    @cDefine("STBI_NO_STDIO", "1");
    @cInclude("stb_image.h");
});
