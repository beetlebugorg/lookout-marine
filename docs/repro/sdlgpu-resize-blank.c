// Minimal SDL_GPU repro: orange triangle, resizable window. Does the triangle
// survive a window resize?
#include <SDL3/SDL.h>
#include <stdio.h>

static void *load(const char *p, size_t *n) {
    SDL_IOStream *io = SDL_IOFromFile(p, "rb");
    return SDL_LoadFile_IO(io, n, true);
}

int main(void) {
    SDL_Init(SDL_INIT_VIDEO);
    SDL_GPUDevice *dev = SDL_CreateGPUDevice(SDL_GPU_SHADERFORMAT_SPIRV, false, NULL);
    if (!dev) { printf("no device: %s\n", SDL_GetError()); return 1; }
    SDL_Window *win = SDL_CreateWindow("sdltri", 800, 600, SDL_WINDOW_RESIZABLE | SDL_WINDOW_HIGH_PIXEL_DENSITY);
    SDL_ClaimWindowForGPUDevice(dev, win);

    size_t vn, fn;
    void *vs = load("tri.vert.spv", &vn), *fs = load("tri.frag.spv", &fn);
    SDL_GPUShaderCreateInfo vi = { .code = vs, .code_size = vn, .entrypoint = "main",
        .format = SDL_GPU_SHADERFORMAT_SPIRV, .stage = SDL_GPU_SHADERSTAGE_VERTEX };
    SDL_GPUShaderCreateInfo fi = { .code = fs, .code_size = fn, .entrypoint = "main",
        .format = SDL_GPU_SHADERFORMAT_SPIRV, .stage = SDL_GPU_SHADERSTAGE_FRAGMENT };
    SDL_GPUShader *vsh = SDL_CreateGPUShader(dev, &vi), *fsh = SDL_CreateGPUShader(dev, &fi);

    SDL_GPUColorTargetDescription ct = { .format = SDL_GetGPUSwapchainTextureFormat(dev, win) };
    SDL_GPUGraphicsPipelineCreateInfo pi = {
        .vertex_shader = vsh, .fragment_shader = fsh,
        .primitive_type = SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
        .target_info = { .color_target_descriptions = &ct, .num_color_targets = 1 },
    };
    SDL_GPUGraphicsPipeline *pipe = SDL_CreateGPUGraphicsPipeline(dev, &pi);
    if (!pipe) { printf("no pipeline: %s\n", SDL_GetError()); return 1; }

    int running = 1, frames = 0;
    while (running) {
        SDL_Event ev;
        while (SDL_PollEvent(&ev)) {
            if (ev.type == SDL_EVENT_QUIT) running = 0;
            if (ev.type == SDL_EVENT_WINDOW_RESIZED) {
                printf("resized to %dx%d\n", (int)ev.window.data1, (int)ev.window.data2);
                const char *fix = SDL_getenv("FIX");
                if (fix && SDL_strcmp(fix, "params") == 0) {
                    int ok = SDL_SetGPUSwapchainParameters(dev, win, SDL_GPU_SWAPCHAINCOMPOSITION_SDR, SDL_GPU_PRESENTMODE_VSYNC);
                    printf("params fix: %d %s\n", ok, SDL_GetError());
                } else if (fix && SDL_strcmp(fix, "reclaim") == 0) {
                    SDL_WaitForGPUIdle(dev);
                    SDL_ReleaseWindowFromGPUDevice(dev, win);
                    int ok = SDL_ClaimWindowForGPUDevice(dev, win);
                    printf("reclaim fix: %d %s\n", ok, SDL_GetError());
                }
            }
        }
        SDL_GPUCommandBuffer *cmd = SDL_AcquireGPUCommandBuffer(dev);
        SDL_GPUTexture *swap = NULL;
        Uint32 w, h;
        SDL_WaitAndAcquireGPUSwapchainTexture(cmd, win, &swap, &w, &h);
        if (swap) {
            SDL_GPUColorTargetInfo cti = { .texture = swap, .clear_color = {0.2f, 0.3f, 0.4f, 1.0f},
                .load_op = SDL_GPU_LOADOP_CLEAR, .store_op = SDL_GPU_STOREOP_STORE };
            SDL_GPURenderPass *pass = SDL_BeginGPURenderPass(cmd, &cti, 1, NULL);
            SDL_BindGPUGraphicsPipeline(pass, pipe);
            SDL_DrawGPUPrimitives(pass, 3, 1, 0, 0);
            SDL_EndGPURenderPass(pass);
        }
        SDL_SubmitGPUCommandBuffer(cmd);
        frames++;
        if (frames == 180) { printf("self-resizing\n"); fflush(stdout); SDL_SetWindowSize(win, 1000, 750); }
        if (frames == 300) {
            const char *fix = SDL_getenv("FIX");
            if (fix && SDL_strcmp(fix, "params") == 0) {
                int ok = SDL_SetGPUSwapchainParameters(dev, win, SDL_GPU_SWAPCHAINCOMPOSITION_SDR, SDL_GPU_PRESENTMODE_VSYNC);
                printf("params fix: %d %s\n", ok, SDL_GetError()); fflush(stdout);
            } else if (fix && SDL_strcmp(fix, "reclaim") == 0) {
                SDL_WaitForGPUIdle(dev);
                SDL_ReleaseWindowFromGPUDevice(dev, win);
                int ok = SDL_ClaimWindowForGPUDevice(dev, win);
                printf("reclaim fix: %d %s\n", ok, SDL_GetError()); fflush(stdout);
            }
        }
        SDL_Delay(16);
    }
    return 0;
}
