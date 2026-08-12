// metal_shim.m — Metal transport for the lookout renderer (see metal_shim.h).
//
// Replaces the whole SDL_GPU → Vulkan → MoltenVK stack on Apple platforms:
// the host hands us its CAMetalLayer and we render straight into it. Shaders
// compile from source at startup (no offline toolchain); pipelines target the
// layer's BGRA8 format; MSAA (4x) resolves into the drawable each pass.
//
// Compiled WITHOUT ARC (-fno-objc-arc): objects live in plain C structs, so
// ownership is explicit retain/release, and every entry point that touches
// autoreleased objects runs its own pool — the callers are Zig/C with no pool
// of their own.
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Foundation/Foundation.h>
#include <string.h>
#include <stdatomic.h>
#include <time.h>
#include "metal_shim.h"

#if __has_feature(objc_arc)
#error "metal_shim.m must be compiled with -fno-objc-arc"
#endif

// The overlay pipeline's shader (LKM_PIPE_OVERLAY). The chart's shaders come
// from the engine (tile57 shaders/lookout.metal, handed in as msl_source); the
// overlay is the host's own content, so its source lives here and compiles into
// its own library at create. Self-contained on purpose: nothing here may break
// if the engine renames a struct.
//
// The uniform block is a byte-for-byte copy of tile57_gpu_uniforms (128 B) so
// the overlay pass can reuse the frame uniform the chart already sends — only
// mvp and wrap_x are read, the rest holds the offsets. The static_assert makes
// a layout skew a loud failure at lkm_create instead of a wrong picture.
static const char *const LKM_OVERLAY_MSL =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct U {\n"
    "    float4x4 mvp;\n"
    "    float2 px_to_clip;\n"
    "    float size_scale;\n"
    "    float current_scale;\n"
    "    uint cat_mask;\n"
    "    float wrap_x;\n"
    "    float rot_sin;\n"
    "    float rot_cos;\n"
    "    float4 color;\n"
    "    float2 anchor_px;\n"
    "    float2 cell_px;\n"
    "};\n"
    "static_assert(sizeof(U) == 128, \"overlay uniform must match tile57_gpu_uniforms\");\n"
    // == overlay.Vertex (24 B). packed_float2/4 hold the stride at 24; natural
    // alignment would pad to 32 and shear the stream (see ChartVertex).
    "struct OverlayVertex {\n"
    "    packed_float2 world;\n"
    "    packed_float4 color;\n"
    "};\n"
    "static_assert(sizeof(OverlayVertex) == 24, \"overlay vertex must match overlay.Vertex\");\n"
    "struct OverlayOut {\n"
    "    float4 pos [[position]];\n"
    "    float4 color;\n"
    "};\n"
    "vertex OverlayOut overlay_vert(uint vid [[vertex_id]],\n"
    "                               const device OverlayVertex *verts [[buffer(0)]],\n"
    "                               constant U &u [[buffer(1)]]) {\n"
    "    OverlayVertex v = verts[vid];\n"
    // Same antimeridian wrap the chart shader applies: draw at the world
    // instance nearest the camera, so an overlay across the seam is seamless.
    "    float2 world = float2(v.world.x + rint(u.wrap_x - v.world.x), v.world.y);\n"
    "    float4 clip = u.mvp * float4(world, 0.0, 1.0);\n"
    // z = 0 is the near plane. The chart's paint-order depths are all in (0,1),
    // so a depth-test-only overlay pass is never hidden by the chart it
    // annotates — and writes nothing, so it cannot hide the chart either.
    "    clip.z = 0.0;\n"
    "    OverlayOut out;\n"
    "    out.pos = clip;\n"
    "    out.color = v.color;\n"
    "    return out;\n"
    "}\n"
    "fragment float4 overlay_frag(OverlayOut in [[stage_in]]) {\n"
    "    return in.color;\n"
    "}\n";

struct lkm_ctx {
    id<MTLDevice> device;          // retained
    id<MTLCommandQueue> queue;     // retained
    id<MTLRenderPipelineState> pipes[LKM_PIPE_COUNT]; // retained
    id<MTLSamplerState> sampler;   // retained
    CAMetalLayer *layer;           // NOT retained — the host view owns it
    id<MTLTexture> msaa;           // retained; lazily (re)sized 4x color target
    uint32_t msaa_w, msaa_h;
    int msaa_on;
    id<MTLTexture> depth;          // retained; lazily (re)sized depth target
    uint32_t depth_w, depth_h;
    id<MTLDepthStencilState> ds_opaque; // LESS + write (front-to-back opaque pass)
    id<MTLDepthStencilState> ds_blend;  // LESS, no write (paint-order blended pass)
    double last_gpu_ms;            // GPU time of the last COMPLETED frame (async;
                                   // written on the completion queue, read racily
                                   // for diagnostics only)
    // In-flight window-frame gate. nextDrawable BLOCKS the calling thread for
    // tens of ms when presents outpace the compositor; instead of stalling the
    // render (main) thread there, lkm_begin_frame returns NULL when the pool
    // is saturated and the host simply skips the frame — the display link
    // retries next tick with input processing never starved.
    // A COUNTER, not a semaphore: permits return via drawable handlers, and a
    // handler can silently never fire (drawables dropped in a swapchain resize,
    // occlusion, backgrounding). A semaphore starved forever exactly that way —
    // frozen chart, live HUD. The counter self-heals: no permit back within
    // 500ms of saturation means the outstanding presents are gone, not slow.
    _Atomic int inflight_n;
    _Atomic long inflight_ret_ms; // monotonic ms of the last permit return
};

static long lkm_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void lkm_inflight_return(lkm_ctx *c) {
    atomic_fetch_sub_explicit(&c->inflight_n, 1, memory_order_relaxed);
    atomic_store_explicit(&c->inflight_ret_ms, lkm_now_ms(), memory_order_relaxed);
}

struct lkm_frame {
    lkm_ctx *ctx;
    id<MTLCommandBuffer> cmd;      // retained for the frame
    id<MTLRenderCommandEncoder> enc; // retained for the frame
    id<CAMetalDrawable> drawable;  // retained for the frame (window path)
    id<MTLTexture> readback;       // retained for the frame (offscreen path)
    uint32_t w, h;
    // Redundant-state elision: a chart frame walks thousands of paint-ordered
    // ranges that mostly share pipeline/buffer/texture; skipping the repeat
    // encoder calls is a large CPU-side win at phone range counts.
    int cur_pipe;                  // -1 = none bound yet
    lkm_buf *cur_vbuf;
    lkm_tex *cur_tex;
};

struct lkm_buf {
    id<MTLBuffer> buf; // retained
};
struct lkm_tex {
    id<MTLTexture> tex; // retained
};

static void set_err(char err[LKM_ERR_LEN], NSString *msg) {
    if (err) strlcpy(err, msg.UTF8String ?: "unknown", LKM_ERR_LEN);
}

static id<MTLRenderPipelineState> make_pipe(id<MTLDevice> dev, id<MTLLibrary> lib,
                                            NSString *vfn, NSString *ffn,
                                            int samples, char err[LKM_ERR_LEN]) {
    MTLRenderPipelineDescriptor *d = [[MTLRenderPipelineDescriptor alloc] init];
    id<MTLFunction> vf = [lib newFunctionWithName:vfn];
    id<MTLFunction> ff = [lib newFunctionWithName:ffn];
    d.vertexFunction = vf;
    d.fragmentFunction = ff;
    id<MTLRenderPipelineState> p = nil;
    if (vf && ff) {
        d.rasterSampleCount = samples;
        d.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        MTLRenderPipelineColorAttachmentDescriptor *ca = d.colorAttachments[0];
        ca.pixelFormat = MTLPixelFormatBGRA8Unorm;
        // Straight-alpha over, alpha accumulates (matches the old blend state).
        ca.blendingEnabled = YES;
        ca.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        ca.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        ca.rgbBlendOperation = MTLBlendOperationAdd;
        ca.sourceAlphaBlendFactor = MTLBlendFactorOne;
        ca.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        ca.alphaBlendOperation = MTLBlendOperationAdd;
        NSError *e = nil;
        p = [dev newRenderPipelineStateWithDescriptor:d error:&e]; // +1
        if (!p) set_err(err, e.localizedDescription);
    } else {
        set_err(err, [NSString stringWithFormat:@"missing shader %@/%@", vfn, ffn]);
    }
    [vf release];
    [ff release];
    [d release];
    return p;
}

lkm_ctx *lkm_create(void *metal_layer, const char *msl_source, int want_msaa,
                    int *msaa_out, char err[LKM_ERR_LEN]) {
    lkm_ctx *c = calloc(1, sizeof(*c));
    if (!c) return NULL;
    // msl_source == NULL is the LIGHT contract: another renderer (the MapLibre
    // backend) draws the chart, and this context exists only so
    // lkm_layer_sync can measure the layer's pixel density. NOTHING Metal is
    // created — no device (the MTLCompiler run crashed a launch), no queue,
    // and the layer is NOT claimed: configuring device/pixelFormat under the
    // real renderer means two drivers on one CAMetalLayer.
    if (!msl_source) {
        c->layer = (CAMetalLayer *)metal_layer; // host-owned; not retained
        if (msaa_out) *msaa_out = 0;
        return c;
    }
    int ok = 0;
    @autoreleasepool {
        do {
            c->device = MTLCreateSystemDefaultDevice(); // +1 (Create rule)
            if (!c->device) {
                set_err(err, @"no Metal device");
                break;
            }
            c->queue = [c->device newCommandQueue]; // +1

            NSError *e = nil;
            id<MTLLibrary> lib = [c->device newLibraryWithSource:[NSString stringWithUTF8String:msl_source]
                                                         options:nil
                                                           error:&e]; // +1
            if (!lib) {
                set_err(err, e.localizedDescription);
                break;
            }

            c->msaa_on = want_msaa && [c->device supportsTextureSampleCount:4];
            atomic_store_explicit(&c->inflight_n, 0, memory_order_relaxed);
            atomic_store_explicit(&c->inflight_ret_ms, lkm_now_ms(), memory_order_relaxed);
            MTLDepthStencilDescriptor *dd = [[MTLDepthStencilDescriptor alloc] init];
            dd.depthCompareFunction = MTLCompareFunctionLess;
            dd.depthWriteEnabled = YES;
            c->ds_opaque = [c->device newDepthStencilStateWithDescriptor:dd]; // +1
            dd.depthWriteEnabled = NO;
            c->ds_blend = [c->device newDepthStencilStateWithDescriptor:dd]; // +1
            [dd release];
            int samples = c->msaa_on ? 4 : 1;
            if (msaa_out) *msaa_out = c->msaa_on;

            struct { NSString *v, *f; } fns[4] = {
                [LKM_PIPE_CHART] = { @"chart_vert", @"chart_frag" },
                [LKM_PIPE_SPRITE] = { @"sprite_vert", @"sprite_frag" },
                [LKM_PIPE_SDF] = { @"sprite_vert", @"sdf_frag" },
                [LKM_PIPE_PATTERN] = { @"pattern_vert", @"pattern_frag" },
            };
            int built = 1;
            for (int i = 0; i < 4; i++) {
                c->pipes[i] = make_pipe(c->device, lib, fns[i].v, fns[i].f, samples, err); // +1
                if (!c->pipes[i]) {
                    built = 0;
                    break;
                }
            }
            [lib release];
            if (!built) break;

            // The overlay's own library — see LKM_OVERLAY_MSL.
            id<MTLLibrary> olib = [c->device newLibraryWithSource:[NSString stringWithUTF8String:LKM_OVERLAY_MSL]
                                                          options:nil
                                                            error:&e]; // +1
            if (!olib) {
                set_err(err, e.localizedDescription);
                break;
            }
            c->pipes[LKM_PIPE_OVERLAY] = make_pipe(c->device, olib, @"overlay_vert", @"overlay_frag", samples, err); // +1
            [olib release];
            if (!c->pipes[LKM_PIPE_OVERLAY]) break;

            MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
            sd.minFilter = MTLSamplerMinMagFilterLinear;
            sd.magFilter = MTLSamplerMinMagFilterLinear;
            sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
            sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
            c->sampler = [c->device newSamplerStateWithDescriptor:sd]; // +1
            [sd release];

            if (metal_layer) {
                c->layer = (CAMetalLayer *)metal_layer; // host-owned; not retained
                c->layer.device = c->device;
                c->layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
                c->layer.framebufferOnly = YES;
                c->layer.opaque = YES;
            }
            ok = 1;
        } while (0);
    }
    if (!ok) {
        lkm_destroy(c);
        return NULL;
    }
    return c;
}

void lkm_destroy(lkm_ctx *c) {
    if (!c) return;
    @autoreleasepool {
        if (c->layer && c->layer.device == c->device) c->layer.device = nil;
        [c->device release];
        [c->queue release];
        for (int i = 0; i < LKM_PIPE_COUNT; i++) [c->pipes[i] release];
        [c->sampler release];
        [c->msaa release];
        [c->depth release];
        [c->ds_opaque release];
        [c->ds_blend release];
    }
    free(c);
}

void lkm_layer_sync(lkm_ctx *c, uint32_t *w_px, uint32_t *h_px) {
    if (!c || !c->layer) {
        if (w_px) *w_px = 0;
        if (h_px) *h_px = 0;
        return;
    }
    @autoreleasepool {
        CGFloat scale = c->layer.contentsScale > 0 ? c->layer.contentsScale : 1.0;
        CGSize pt = c->layer.bounds.size;
        CGSize px = CGSizeMake(MAX(1.0, round(pt.width * scale)), MAX(1.0, round(pt.height * scale)));
        if (!CGSizeEqualToSize(c->layer.drawableSize, px)) c->layer.drawableSize = px;
        if (w_px) *w_px = (uint32_t)px.width;
        if (h_px) *h_px = (uint32_t)px.height;
    }
}

lkm_buf *lkm_new_buffer(lkm_ctx *c, const void *bytes, size_t len) {
    if (!c || !bytes || len == 0) return NULL;
    @autoreleasepool {
        id<MTLBuffer> b = [c->device newBufferWithBytes:bytes length:len options:MTLResourceStorageModeShared]; // +1
        if (!b) return NULL;
        lkm_buf *out = calloc(1, sizeof(*out));
        out->buf = b;
        return out;
    }
}

void lkm_free_buffer(lkm_buf *b) {
    if (!b) return;
    [b->buf release];
    free(b);
}

lkm_tex *lkm_new_texture_rgba(lkm_ctx *c, const void *rgba, uint32_t w, uint32_t h) {
    if (!c || !rgba || w == 0 || h == 0) return NULL;
    @autoreleasepool {
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                     width:w
                                                                                    height:h
                                                                                 mipmapped:NO];
        d.usage = MTLTextureUsageShaderRead;
        d.storageMode = MTLStorageModeShared;
        id<MTLTexture> t = [c->device newTextureWithDescriptor:d]; // +1
        if (!t) return NULL;
        [t replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:rgba bytesPerRow:(NSUInteger)w * 4];
        lkm_tex *out = calloc(1, sizeof(*out));
        out->tex = t;
        return out;
    }
}

void lkm_free_texture(lkm_tex *t) {
    if (!t) return;
    [t->tex release];
    free(t);
}

static void ensure_depth(lkm_ctx *c, uint32_t w, uint32_t h) {
    if (c->depth && c->depth_w == w && c->depth_h == h) return;
    [c->depth release];
    c->depth = nil;
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                                                 width:w
                                                                                height:h
                                                                             mipmapped:NO];
    if (c->msaa_on) {
        d.textureType = MTLTextureType2DMultisample;
        d.sampleCount = 4;
    }
    d.usage = MTLTextureUsageRenderTarget;
    // Same story as the MSAA target: cleared on load, never stored — on TBDR
    // GPUs the depth samples live only in tile memory.
    if ([c->device supportsFamily:MTLGPUFamilyApple2])
        d.storageMode = MTLStorageModeMemoryless;
    else
        d.storageMode = MTLStorageModePrivate;
    c->depth = [c->device newTextureWithDescriptor:d]; // +1
    c->depth_w = w;
    c->depth_h = h;
}

static void ensure_msaa(lkm_ctx *c, uint32_t w, uint32_t h) {
    if (!c->msaa_on) return;
    if (c->msaa && c->msaa_w == w && c->msaa_h == h) return;
    [c->msaa release];
    c->msaa = nil;
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                 width:w
                                                                                height:h
                                                                             mipmapped:NO];
    d.textureType = MTLTextureType2DMultisample;
    d.sampleCount = 4;
    d.usage = MTLTextureUsageRenderTarget;
    // TBDR GPUs never need this texture backed: it is cleared on load and
    // resolved on store, so the samples live only in tile memory. Memoryless
    // saves w*h*4*4 bytes (~48MB at phone density); Intel Macs need Private.
    if ([c->device supportsFamily:MTLGPUFamilyApple2])
        d.storageMode = MTLStorageModeMemoryless;
    else
        d.storageMode = MTLStorageModePrivate;
    c->msaa = [c->device newTextureWithDescriptor:d]; // +1
    c->msaa_w = w;
    c->msaa_h = h;
}

// Retains cmd/enc/drawable/readback into the frame (callers run no pool).
static lkm_frame *begin_pass(lkm_ctx *c, id<MTLTexture> target, id<CAMetalDrawable> drawable,
                             id<MTLTexture> readback, uint32_t w, uint32_t h, const float clear[4]) {
    ensure_msaa(c, w, h);
    ensure_depth(c, w, h);
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.depthAttachment.texture = c->depth;
    rp.depthAttachment.clearDepth = 1.0; // farthest; paint-order depths are < 1
    rp.depthAttachment.loadAction = MTLLoadActionClear;
    rp.depthAttachment.storeAction = MTLStoreActionDontCare;
    MTLRenderPassColorAttachmentDescriptor *ca = rp.colorAttachments[0];
    ca.clearColor = MTLClearColorMake(clear[0], clear[1], clear[2], clear[3]);
    ca.loadAction = MTLLoadActionClear;
    if (c->msaa_on) {
        ca.texture = c->msaa;
        ca.resolveTexture = target;
        ca.storeAction = MTLStoreActionMultisampleResolve;
    } else {
        ca.texture = target;
        ca.storeAction = MTLStoreActionStore;
    }
    id<MTLCommandBuffer> cmd = [c->queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rp];
    if (!enc) return NULL;
    [enc setFragmentSamplerState:c->sampler atIndex:0];
    [enc setDepthStencilState:c->ds_blend]; // default: test only — a host that
                                            // never draws an opaque pass gets
                                            // exactly the old painter's order
    lkm_frame *f = calloc(1, sizeof(*f));
    f->ctx = c;
    f->cur_pipe = -1;
    f->cmd = [cmd retain];
    f->enc = [enc retain];
    f->drawable = [drawable retain];
    f->readback = [readback retain];
    f->w = w;
    f->h = h;
    return f;
}

lkm_frame *lkm_begin_frame(lkm_ctx *c, const float clear[4]) {
    if (!c || !c->layer) return NULL;
    @autoreleasepool {
        uint32_t w = 0, h = 0;
        lkm_layer_sync(c, &w, &h);
        if (w == 0 || h == 0) return NULL;
        int n = atomic_load_explicit(&c->inflight_n, memory_order_relaxed);
        if (n < 0) { // late returns after a self-heal reset: clamp
            atomic_store_explicit(&c->inflight_n, 0, memory_order_relaxed);
            n = 0;
        }
        // Cap at 2, one BELOW the drawable pool of 3: a drawable whose
        // presented-handler has fired is still on glass until the next frame
        // supersedes it, so at 3-in-flight the gate opens while the pool is
        // still empty and nextDrawable blocks ~a full vsync anyway — measured
        // as acquire avg ~15ms (one 60Hz period) on device with a fast GPU.
        // At 2-in-flight there is always a free drawable and acquire is ~0.
        if (n >= 2) {
            long since = lkm_now_ms() - atomic_load_explicit(&c->inflight_ret_ms, memory_order_relaxed);
            if (since < 500) return NULL; // healthy backpressure: skip, don't stall
            // No permit back in 500ms: those presents are lost (resize,
            // occlusion), not queued. Reset rather than freeze forever.
            atomic_store_explicit(&c->inflight_n, 0, memory_order_relaxed);
        }
        atomic_fetch_add_explicit(&c->inflight_n, 1, memory_order_relaxed);
        id<CAMetalDrawable> drawable = [c->layer nextDrawable];
        if (!drawable) {
            lkm_inflight_return(c);
            return NULL;
        }
        lkm_frame *f = begin_pass(c, drawable.texture, drawable, nil, w, h, clear);
        if (!f) lkm_inflight_return(c);
        return f;
    }
}

lkm_frame *lkm_begin_offscreen(lkm_ctx *c, uint32_t w, uint32_t h, const float clear[4]) {
    if (!c || w == 0 || h == 0) return NULL;
    @autoreleasepool {
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                     width:w
                                                                                    height:h
                                                                                 mipmapped:NO];
        d.usage = MTLTextureUsageRenderTarget;
        d.storageMode = MTLStorageModeShared; // Apple Silicon: CPU-readable render target
        id<MTLTexture> t = [c->device newTextureWithDescriptor:d]; // +1
        if (!t) return NULL;
        lkm_frame *f = begin_pass(c, t, nil, t, w, h, clear);
        [t release]; // begin_pass retained it as f->readback
        return f;
    }
}

void lkm_set_depth_mode(lkm_frame *f, int opaque) {
    if (!f) return;
    [f->enc setDepthStencilState:opaque ? f->ctx->ds_opaque : f->ctx->ds_blend];
}

void lkm_set_pipeline(lkm_frame *f, int which) {
    if (!f || which < 0 || which >= LKM_PIPE_COUNT || f->cur_pipe == which) return;
    f->cur_pipe = which;
    [f->enc setRenderPipelineState:f->ctx->pipes[which]];
}

void lkm_bind_vbuf(lkm_frame *f, lkm_buf *b) {
    if (!f || !b || f->cur_vbuf == b) return;
    f->cur_vbuf = b;
    [f->enc setVertexBuffer:b->buf offset:0 atIndex:0];
}

void lkm_bind_texture(lkm_frame *f, lkm_tex *t) {
    if (!f || !t || f->cur_tex == t) return;
    f->cur_tex = t;
    [f->enc setFragmentTexture:t->tex atIndex:0];
}

void lkm_set_uniforms(lkm_frame *f, const void *bytes, size_t len) {
    if (!f) return;
    [f->enc setVertexBytes:bytes length:len atIndex:1];
    // The SDF text fragment stage reads the uniform too (palette halo colour).
    [f->enc setFragmentBytes:bytes length:len atIndex:1];
}

void lkm_draw(lkm_frame *f, uint32_t first, uint32_t count) {
    if (!f) return;
    [f->enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:first vertexCount:count];
}

// Indexed draw against the bound vertex buffer. `first` is in INDEX units
// (u32). The shaders fetch via [[vertex_id]], which for an indexed draw is the
// fetched index value — so the same shaders serve both draw paths.
void lkm_draw_indexed(lkm_frame *f, lkm_buf *ib, uint32_t first, uint32_t count) {
    if (!f || !ib) return;
    [f->enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                       indexCount:count
                        indexType:MTLIndexTypeUInt32
                      indexBuffer:ib->buf
                indexBufferOffset:(NSUInteger)first * 4];
}

void lkm_end_frame(lkm_frame *f) {
    if (!f) return;
    @autoreleasepool {
        [f->enc endEncoding];
        lkm_ctx *c = f->ctx;
        // The inflight permit returns when the drawable is ON GLASS — not at
        // GPU completion, which lands tens of ms earlier when the compositor is
        // the bottleneck. Gating on GPU completion recycled permits before the
        // pool had a drawable free, and nextDrawable blocked anyway. Handlers
        // must be registered BEFORE the present is scheduled.
        int presented_gate = 0;
        if (f->drawable) {
            // The SIMULATOR's CAMetalDrawable does not implement
            // addPresentedHandler: (unrecognized selector) — probe first. On
            // hardware the permit returns when the frame is ON GLASS; in the
            // sim it falls back to GPU completion below (imperfect, but sim
            // frame pacing is not a target).
            if ([(id)f->drawable respondsToSelector:@selector(addPresentedHandler:)]) {
                presented_gate = 1;
                [f->drawable addPresentedHandler:^(id<MTLDrawable> d) {
                    lkm_inflight_return(c);
                }];
            }
            [f->cmd presentDrawable:f->drawable];
        }
        int gated_on_complete = (f->drawable != nil) && !presented_gate;
        [f->cmd addCompletedHandler:^(id<MTLCommandBuffer> cb) {
            // Diagnostics only (racy read is fine): how long the GPU actually
            // spent on the frame — the CPU-vs-GPU-bound discriminator.
            c->last_gpu_ms = (cb.GPUEndTime - cb.GPUStartTime) * 1000.0;
            if (gated_on_complete) lkm_inflight_return(c);
        }];
        [f->cmd commit];
        [f->enc release];
        [f->cmd release];
        [f->drawable release];
        [f->readback release];
    }
    free(f);
}

double lkm_last_gpu_ms(lkm_ctx *c) {
    return c ? c->last_gpu_ms : 0;
}

int lkm_end_offscreen_read(lkm_frame *f, void *out_bgra) {
    if (!f) return 0;
    int ok = 0;
    @autoreleasepool {
        [f->enc endEncoding];
        [f->cmd commit];
        [f->cmd waitUntilCompleted];
        if (f->readback && out_bgra) {
            [f->readback getBytes:out_bgra
                      bytesPerRow:(NSUInteger)f->w * 4
                       fromRegion:MTLRegionMake2D(0, 0, f->w, f->h)
                      mipmapLevel:0];
            ok = 1;
        }
        [f->enc release];
        [f->cmd release];
        [f->drawable release];
        [f->readback release];
    }
    free(f);
    return ok;
}
