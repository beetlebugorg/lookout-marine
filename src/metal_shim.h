/* metal_shim.h — the C face of the Metal transport (metal_shim.m).
 *
 * gpu.zig drives rendering exclusively through these calls; all ObjC/Metal
 * lives behind them. One context owns the device, queue, runtime-compiled
 * shader library, the four pipelines and the sampler. Frames encode one render
 * pass each — either into a CAMetalLayer drawable (window path) or into an
 * offscreen texture that can be read back (snapshot path).
 *
 * Threading: everything here must be called from one thread (the engine's
 * existing main-thread contract). Errors land in the caller's err buffer.
 */
#ifndef LOOKOUT_METAL_SHIM_H
#define LOOKOUT_METAL_SHIM_H
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct lkm_ctx lkm_ctx;
typedef struct lkm_frame lkm_frame;
typedef struct lkm_buf lkm_buf;
typedef struct lkm_tex lkm_tex;

enum {
    LKM_PIPE_CHART = 0,
    LKM_PIPE_SPRITE = 1,
    LKM_PIPE_SDF = 2,
    LKM_PIPE_PATTERN = 3,
};

#define LKM_ERR_LEN 256

/* Create the device/queue/pipelines. `metal_layer` is a CAMetalLayer* to
 * present into, or NULL for offscreen-only. `msl_source` is the shader library
 * source (compiled here at runtime). Returns NULL with `err` filled on
 * failure. `want_msaa` requests 4x (granted whenever the device supports it —
 * every Apple GPU does; *msaa_out reports the decision). */
lkm_ctx *lkm_create(void *metal_layer, const char *msl_source, int want_msaa,
                    int *msaa_out, char err[LKM_ERR_LEN]);
void lkm_destroy(lkm_ctx *c);

/* Layer geometry. lkm_layer_sync sizes the layer's drawableSize from its
 * bounds × contentsScale and reports the resulting pixel size; no-ops (and
 * reports 0×0) without a layer. */
void lkm_layer_sync(lkm_ctx *c, uint32_t *w_px, uint32_t *h_px);

/* Immutable GPU resources. Buffers are shared-storage copies of `bytes`;
 * textures are RGBA8 sampler textures. */
lkm_buf *lkm_new_buffer(lkm_ctx *c, const void *bytes, size_t len);
void lkm_free_buffer(lkm_buf *b);
lkm_tex *lkm_new_texture_rgba(lkm_ctx *c, const void *rgba, uint32_t w, uint32_t h);
void lkm_free_texture(lkm_tex *t);

/* One frame = one render pass, cleared to `clear` (rgba 0..1). The window
 * variant acquires the layer's next drawable (NULL when none is available —
 * skip the frame); the offscreen variant renders into a readback texture of
 * the given pixel size. MSAA resolve is internal to both. */
lkm_frame *lkm_begin_frame(lkm_ctx *c, const float clear[4]);
lkm_frame *lkm_begin_offscreen(lkm_ctx *c, uint32_t w_px, uint32_t h_px, const float clear[4]);

void lkm_set_pipeline(lkm_frame *f, int which);
void lkm_bind_vbuf(lkm_frame *f, lkm_buf *b);
void lkm_bind_texture(lkm_frame *f, lkm_tex *t);
void lkm_set_uniforms(lkm_frame *f, const void *bytes, size_t len);
void lkm_draw(lkm_frame *f, uint32_t first, uint32_t count);
/* Indexed triangles against the bound vertex buffer; `first` in u32-index units. */
void lkm_draw_indexed(lkm_frame *f, lkm_buf *ib, uint32_t first, uint32_t count);

/* End the pass. The window variant presents and returns immediately; the
 * offscreen variant waits for completion and writes w*h*4 bytes of top-down
 * BGRA8 into out_bgra (the caller swizzles). Both destroy the frame. */
void lkm_end_frame(lkm_frame *f);
int lkm_end_offscreen_read(lkm_frame *f, void *out_bgra);

#ifdef __cplusplus
}
#endif
#endif
