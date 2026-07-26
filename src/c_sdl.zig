//! SDL-backend C interop: SDL3 (window + SDL_GPU transport). Used only by
//! gpu_sdl.zig; tile57 / stb types come from the shared c.zig so they match
//! across the renderer seam. SDL_MAIN_HANDLED: lookout is a library, the host
//! app owns the entry point (SDL must not redefine main()).
pub const c = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "1");
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_main.h"); // SDL_SetMainReady (HANDLED stops it redefining main)
});
