/* d3d12_shim.h — the C face of the Direct3D 12 transport (d3d12_shim.c).
 *
 * gpu_d3d12.zig drives rendering exclusively through these calls; all D3D12
 * lives behind them. One context owns the device, queue, runtime-compiled
 * shaders (D3DCompile), the pipelines, and a composition swapchain the host
 * attaches to its SwapChainPanel (lkd_swapchain). Frames encode one render
 * pass each — either into the swapchain's back buffer (window path) or into an
 * offscreen texture that can be read back (snapshot path).
 *
 * Threading: frames run on one thread. Buffer and texture creation may run on
 * any thread (the scene build worker); destruction is deferred until the GPU
 * is past the resource. Errors from create land in the caller's err buffer.
 */
#ifndef LOOKOUT_D3D12_SHIM_H
#define LOOKOUT_D3D12_SHIM_H
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct lkd_ctx lkd_ctx;
typedef struct lkd_frame lkd_frame;
typedef struct lkd_buf lkd_buf;
typedef struct lkd_tex lkd_tex;

enum {
    LKD_PIPE_CHART = 0,
    LKD_PIPE_SPRITE = 1,
    LKD_PIPE_SDF = 2,
    LKD_PIPE_PATTERN = 3,
};

#define LKD_ERR_LEN 256

/* Create the device/queue/pipelines. Hardware adapter first, WARP when there
 * is none (LOOKOUT_WARP=1 forces WARP). `hlsl_source` is the shader source
 * (compiled here at runtime). `want_swapchain` adds a composition swapchain of
 * w_px x h_px for a SwapChainPanel; 0 is offscreen-only (headless). `want_msaa`
 * requests 4x (granted when the device supports it; *msaa_out reports the
 * decision). Returns NULL with `err` filled on failure. */
lkd_ctx *lkd_create(uint32_t w_px, uint32_t h_px, int want_swapchain,
                    const char *hlsl_source, int want_msaa, int *msaa_out,
                    char err[LKD_ERR_LEN]);
void lkd_destroy(lkd_ctx *c);

/* The IDXGISwapChain* for ISwapChainPanelNative::SetSwapChain (NULL when
 * created offscreen-only). The context keeps ownership. */
void *lkd_swapchain(lkd_ctx *c);

/* Resize the swapchain (pixels). Waits for the GPU, then resizes the buffers
 * and the depth/MSAA targets. Returns 0 on failure. */
int lkd_resize(lkd_ctx *c, uint32_t w_px, uint32_t h_px);
void lkd_get_size(lkd_ctx *c, uint32_t *w_px, uint32_t *h_px);

/* Immutable GPU resources. Buffers are upload-heap copies of `bytes`;
 * textures are RGBA8 sampler textures. Both may be created on any thread. */
lkd_buf *lkd_new_buffer(lkd_ctx *c, const void *bytes, size_t len);
void lkd_free_buffer(lkd_buf *b);
lkd_tex *lkd_new_texture_rgba(lkd_ctx *c, const void *rgba, uint32_t w, uint32_t h);
void lkd_free_texture(lkd_tex *t);

/* One frame = one render pass, cleared to `clear` (rgba 0..1). The window
 * variant renders into the current back buffer (NULL without a swapchain);
 * the offscreen variant renders into a readback texture of the given pixel
 * size. MSAA resolve is internal to both. */
lkd_frame *lkd_begin_frame(lkd_ctx *c, const float clear[4]);
lkd_frame *lkd_begin_offscreen(lkd_ctx *c, uint32_t w_px, uint32_t h_px, const float clear[4]);

void lkd_set_pipeline(lkd_frame *f, int which);
/* 1 = opaque pass (depth LESS + write, draw front-to-back); 0 = blended pass
 * (LESS, no write, draw in paint order). Default per frame is 0. */
void lkd_set_depth_mode(lkd_frame *f, int opaque);
void lkd_bind_vbuf(lkd_frame *f, lkd_buf *b);
void lkd_bind_texture(lkd_frame *f, lkd_tex *t);
void lkd_set_uniforms(lkd_frame *f, const void *bytes, size_t len);
void lkd_draw(lkd_frame *f, uint32_t first, uint32_t count);
/* Indexed triangles against the bound vertex buffer; `first` in u32-index units. */
void lkd_draw_indexed(lkd_frame *f, lkd_buf *ib, uint32_t first, uint32_t count);

/* End the pass. The window variant presents and returns immediately; the
 * offscreen variant waits for completion and writes w*h*4 bytes of top-down
 * BGRA8 into out_bgra (the caller swizzles). Both close the frame. */
void lkd_end_frame(lkd_frame *f);
/* GPU time (ms) of the most recently COMPLETED window frame; 0 until one lands. */
double lkd_last_gpu_ms(lkd_ctx *c);
int lkd_end_offscreen_read(lkd_frame *f, void *out_bgra);

#ifdef __cplusplus
}
#endif
#endif
