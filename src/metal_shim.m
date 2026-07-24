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
#include "metal_shim.h"

#if __has_feature(objc_arc)
#error "metal_shim.m must be compiled with -fno-objc-arc"
#endif

struct lkm_ctx {
    id<MTLDevice> device;          // retained
    id<MTLCommandQueue> queue;     // retained
    id<MTLRenderPipelineState> pipes[4]; // retained
    id<MTLSamplerState> sampler;   // retained
    CAMetalLayer *layer;           // NOT retained — the host view owns it
    id<MTLTexture> msaa;           // retained; lazily (re)sized 4x color target
    uint32_t msaa_w, msaa_h;
    int msaa_on;
    double last_gpu_ms;            // GPU time of the last COMPLETED frame (async;
                                   // written on the completion queue, read racily
                                   // for diagnostics only)
    // In-flight window-frame gate. nextDrawable BLOCKS the calling thread for
    // tens of ms when presents outpace the compositor; instead of stalling the
    // render (main) thread there, lkm_begin_frame returns NULL when the pool
    // is saturated and the host simply skips the frame — the display link
    // retries next tick with input processing never starved.
    dispatch_semaphore_t inflight;
};

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
            c->inflight = dispatch_semaphore_create(3); // matches CAMetalLayer's default pool
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
        for (int i = 0; i < 4; i++) [c->pipes[i] release];
        [c->sampler release];
        [c->msaa release];
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
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
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
        if (dispatch_semaphore_wait(c->inflight, DISPATCH_TIME_NOW) != 0)
            return NULL; // all drawables still queued for glass: skip, don't stall
        id<CAMetalDrawable> drawable = [c->layer nextDrawable];
        if (!drawable) {
            dispatch_semaphore_signal(c->inflight);
            return NULL;
        }
        lkm_frame *f = begin_pass(c, drawable.texture, drawable, nil, w, h, clear);
        if (!f) dispatch_semaphore_signal(c->inflight);
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

void lkm_set_pipeline(lkm_frame *f, int which) {
    if (!f || which < 0 || which > 3 || f->cur_pipe == which) return;
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
                    dispatch_semaphore_signal(c->inflight);
                }];
            }
            [f->cmd presentDrawable:f->drawable];
        }
        int gated_on_complete = (f->drawable != nil) && !presented_gate;
        [f->cmd addCompletedHandler:^(id<MTLCommandBuffer> cb) {
            // Diagnostics only (racy read is fine): how long the GPU actually
            // spent on the frame — the CPU-vs-GPU-bound discriminator.
            c->last_gpu_ms = (cb.GPUEndTime - cb.GPUStartTime) * 1000.0;
            if (gated_on_complete) dispatch_semaphore_signal(c->inflight);
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
