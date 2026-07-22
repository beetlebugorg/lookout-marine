# SDL_GPU resize repro (macOS, Vulkan/MoltenVK)

`sdlgpu-resize-blank.c` is a minimal SDL_GPU app (one triangle, no buffers or
uniforms) demonstrating the driver-stack bug worked around in `src/gpu.zig`:
after `SDL_SetWindowSize` triggers the implicit swapchain recreation, geometry
draws stop rasterizing — the clear still lands, so the window shows only the
clear color. Setting `FIX=reclaim` applies the workaround
(`SDL_WaitForGPUIdle` → `SDL_ReleaseWindowFromGPUDevice` →
`SDL_ClaimWindowForGPUDevice`) and the triangle returns; `FIX=params`
(`SDL_SetGPUSwapchainParameters`) does not help.

Build:
    glslangValidator -V tri.vert -o tri.vert.spv
    glslangValidator -V tri.frag -o tri.frag.spv
    cc -o sdltri sdlgpu-resize-blank.c -I$SDL3/include -L$SDL3/lib -lSDL3 -Wl,-rpath,$SDL3/lib

Seen with SDL 3.4.12 + MoltenVK 1.4.1 on macOS 26 (Apple Silicon).
