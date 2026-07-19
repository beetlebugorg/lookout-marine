//! All C interop in one place: SDL3 (window + GPU transport), tile57 (the chart
//! engine + Surface interface), and libtess2 (polygon/glyph tessellation).
pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("tile57.h");
    @cInclude("tesselator.h");
    @cDefine("STBI_NO_STDIO", "1");
    @cInclude("stb_image.h");
});
