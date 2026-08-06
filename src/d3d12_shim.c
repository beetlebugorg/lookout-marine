/* d3d12_shim.c — the Direct3D 12 transport behind d3d12_shim.h.
 *
 * One context owns the device (hardware, or WARP when there is none), the
 * direct queue, the runtime-compiled shaders (D3DCompile of
 * shaders/lookout.hlsl), the pipelines, and a composition swapchain for the
 * host's SwapChainPanel. Two frames in flight; per-frame command allocator and
 * uniform ring. Buffer/texture creation is thread-safe (the scene build
 * worker); texture uploads run on a private queue behind a lock, and frees are
 * deferred until the frame fence passes the resource.
 */
#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#include <windows.h>
#include <d3d12.h>
#include <d3d12sdklayers.h>
#include <dxgi1_4.h>
#include <d3dcompiler.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "d3d12_shim.h"

#define LKD_FMT DXGI_FORMAT_B8G8R8A8_UNORM
#define LKD_DEPTH_FMT DXGI_FORMAT_D32_FLOAT
#define LKD_FRAMES 2
#define LKD_SRV_SLOTS 1024
#define LKD_URING_BYTES (256 * 2048)

/* The first five match LKD_PIPE_* by value (apply_draw_state indexes with the
 * pipe); PSO_CHART_OPAQUE is reached only through the depth-mode override. */
enum { PSO_CHART = 0, PSO_SPRITE, PSO_SDF, PSO_PATTERN, PSO_RASTER, PSO_CHART_OPAQUE, PSO_COUNT };

typedef struct retire_item {
    ID3D12Resource *res;
    int srv_slot; /* -1 = none */
    UINT64 fence_value;
    struct retire_item *next;
} retire_item;

struct lkd_buf {
    lkd_ctx *ctx;
    ID3D12Resource *res;
    size_t len;
};

struct lkd_tex {
    lkd_ctx *ctx;
    ID3D12Resource *res;
    int slot;
};

struct lkd_frame {
    lkd_ctx *ctx;
    int offscreen;
    UINT idx; /* back-buffer / frame-slot index (0 for offscreen) */
    UINT w, h;
    int pipe;
    int depth_mode;
    ID3D12PipelineState *cur_pso;
    lkd_buf *vbuf;
    lkd_buf *bound_vbuf;
    UINT bound_stride;
    lkd_buf *bound_ibuf;
    size_t uofs;
    int uring_full_logged;
    /* offscreen-only resources (released by end_offscreen_read) */
    ID3D12Resource *os_color;
    ID3D12Resource *os_resolve;
    ID3D12Resource *os_depth;
    ID3D12Resource *os_readback;
};

struct lkd_ctx {
    ID3D12Device *dev;
    ID3D12CommandQueue *queue;
    IDXGIFactory4 *factory;
    IDXGISwapChain3 *swapchain;
    UINT width, height;
    int msaa; /* sample count: 1 or 4 */

    ID3D12RootSignature *root_sig;
    ID3D12PipelineState *psos[PSO_COUNT];

    ID3D12DescriptorHeap *rtv_heap; /* 0,1 backbuffers; 2 msaa; 3 offscreen */
    ID3D12DescriptorHeap *dsv_heap; /* 0 window; 1 offscreen */
    ID3D12DescriptorHeap *srv_heap; /* shader-visible texture table */
    UINT rtv_inc, dsv_inc, srv_inc;

    ID3D12Resource *backbuffers[LKD_FRAMES];
    ID3D12Resource *msaa_color;
    ID3D12Resource *depth;

    ID3D12CommandAllocator *alloc[LKD_FRAMES];
    ID3D12GraphicsCommandList *list;
    ID3D12Fence *fence;
    UINT64 fence_value;
    UINT64 frame_fence[LKD_FRAMES];
    HANDLE fence_event;

    /* per-frame uniform rings, persistently mapped */
    ID3D12Resource *uring[LKD_FRAMES];
    uint8_t *uring_ptr[LKD_FRAMES];
    D3D12_GPU_VIRTUAL_ADDRESS uring_va[LKD_FRAMES];

    /* GPU frame timing */
    ID3D12QueryHeap *ts_heap;
    ID3D12Resource *ts_readback;
    UINT64 *ts_ptr;
    UINT64 ts_freq;
    int ts_pending[LKD_FRAMES];
    double last_gpu_ms;

    /* texture uploads: private queue behind a lock (any-thread creation) */
    SRWLOCK upload_lock;
    ID3D12CommandQueue *up_queue;
    ID3D12CommandAllocator *up_alloc;
    ID3D12GraphicsCommandList *up_list;
    ID3D12Fence *up_fence;
    UINT64 up_value;
    HANDLE up_event;

    /* SRV slot free list + deferred frees */
    SRWLOCK res_lock;
    int srv_free[LKD_SRV_SLOTS];
    int srv_free_count;
    retire_item *retire;

    lkd_frame frame;
};

/* ---- small helpers -------------------------------------------------------- */

static void set_err(char err[LKD_ERR_LEN], const char *what, HRESULT hr)
{
    if (err)
        _snprintf_s(err, LKD_ERR_LEN, _TRUNCATE, "%s (hr=0x%08lX)", what, (unsigned long)hr);
}

static D3D12_CPU_DESCRIPTOR_HANDLE rtv_at(lkd_ctx *c, UINT slot)
{
    D3D12_CPU_DESCRIPTOR_HANDLE h;
    ID3D12DescriptorHeap_GetCPUDescriptorHandleForHeapStart(c->rtv_heap, &h);
    h.ptr += (SIZE_T)slot * c->rtv_inc;
    return h;
}

static D3D12_CPU_DESCRIPTOR_HANDLE dsv_at(lkd_ctx *c, UINT slot)
{
    D3D12_CPU_DESCRIPTOR_HANDLE h;
    ID3D12DescriptorHeap_GetCPUDescriptorHandleForHeapStart(c->dsv_heap, &h);
    h.ptr += (SIZE_T)slot * c->dsv_inc;
    return h;
}

static D3D12_CPU_DESCRIPTOR_HANDLE srv_cpu_at(lkd_ctx *c, UINT slot)
{
    D3D12_CPU_DESCRIPTOR_HANDLE h;
    ID3D12DescriptorHeap_GetCPUDescriptorHandleForHeapStart(c->srv_heap, &h);
    h.ptr += (SIZE_T)slot * c->srv_inc;
    return h;
}

static D3D12_GPU_DESCRIPTOR_HANDLE srv_gpu_at(lkd_ctx *c, UINT slot)
{
    D3D12_GPU_DESCRIPTOR_HANDLE h;
    ID3D12DescriptorHeap_GetGPUDescriptorHandleForHeapStart(c->srv_heap, &h);
    h.ptr += (UINT64)slot * c->srv_inc;
    return h;
}

static void fence_wait(ID3D12Fence *fence, UINT64 value, HANDLE ev)
{
    if (ID3D12Fence_GetCompletedValue(fence) >= value)
        return;
    ID3D12Fence_SetEventOnCompletion(fence, value, ev);
    WaitForSingleObject(ev, INFINITE);
}

/* Wait for everything submitted on the main queue. */
static void gpu_flush(lkd_ctx *c)
{
    UINT64 v = ++c->fence_value;
    ID3D12CommandQueue_Signal(c->queue, c->fence, v);
    fence_wait(c->fence, v, c->fence_event);
}

static void barrier_transition(ID3D12GraphicsCommandList *list, ID3D12Resource *res,
                               D3D12_RESOURCE_STATES before, D3D12_RESOURCE_STATES after)
{
    D3D12_RESOURCE_BARRIER b;
    memset(&b, 0, sizeof b);
    b.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    b.Transition.pResource = res;
    b.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    b.Transition.StateBefore = before;
    b.Transition.StateAfter = after;
    ID3D12GraphicsCommandList_ResourceBarrier(list, 1, &b);
}

/* Free anything the fence has passed. Call with res_lock NOT held. */
static void drain_retired(lkd_ctx *c, int all)
{
    UINT64 done = ID3D12Fence_GetCompletedValue(c->fence);
    AcquireSRWLockExclusive(&c->res_lock);
    retire_item **p = &c->retire;
    while (*p) {
        retire_item *it = *p;
        if (all || it->fence_value <= done) {
            *p = it->next;
            ID3D12Resource_Release(it->res);
            if (it->srv_slot >= 0 && c->srv_free_count < LKD_SRV_SLOTS)
                c->srv_free[c->srv_free_count++] = it->srv_slot;
            free(it);
        } else {
            p = &it->next;
        }
    }
    ReleaseSRWLockExclusive(&c->res_lock);
}

static void retire_resource(lkd_ctx *c, ID3D12Resource *res, int srv_slot)
{
    retire_item *it = (retire_item *)malloc(sizeof *it);
    if (it == NULL) { /* leak rather than free a live resource */
        return;
    }
    it->res = res;
    it->srv_slot = srv_slot;
    AcquireSRWLockExclusive(&c->res_lock);
    /* +LKD_FRAMES: the value the in-flight frames could still signal past */
    it->fence_value = c->fence_value + LKD_FRAMES;
    it->next = c->retire;
    c->retire = it;
    ReleaseSRWLockExclusive(&c->res_lock);
}

/* ---- resource creation ---------------------------------------------------- */

static ID3D12Resource *make_buffer(lkd_ctx *c, D3D12_HEAP_TYPE heap, UINT64 len,
                                   D3D12_RESOURCE_STATES state)
{
    D3D12_HEAP_PROPERTIES hp;
    memset(&hp, 0, sizeof hp);
    hp.Type = heap;
    D3D12_RESOURCE_DESC rd;
    memset(&rd, 0, sizeof rd);
    rd.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    rd.Width = len;
    rd.Height = 1;
    rd.DepthOrArraySize = 1;
    rd.MipLevels = 1;
    rd.Format = DXGI_FORMAT_UNKNOWN;
    rd.SampleDesc.Count = 1;
    rd.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    ID3D12Resource *res = NULL;
    if (FAILED(ID3D12Device_CreateCommittedResource(c->dev, &hp, D3D12_HEAP_FLAG_NONE, &rd,
                                                    state, NULL, &IID_ID3D12Resource, (void **)&res)))
        return NULL;
    return res;
}

static ID3D12Resource *make_target(lkd_ctx *c, UINT w, UINT h, DXGI_FORMAT fmt, int samples,
                                   D3D12_RESOURCE_FLAGS flags, D3D12_RESOURCE_STATES state,
                                   const D3D12_CLEAR_VALUE *clear)
{
    D3D12_HEAP_PROPERTIES hp;
    memset(&hp, 0, sizeof hp);
    hp.Type = D3D12_HEAP_TYPE_DEFAULT;
    D3D12_RESOURCE_DESC rd;
    memset(&rd, 0, sizeof rd);
    rd.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    rd.Width = w;
    rd.Height = h;
    rd.DepthOrArraySize = 1;
    rd.MipLevels = 1;
    rd.Format = fmt;
    rd.SampleDesc.Count = (UINT)samples;
    rd.Layout = D3D12_TEXTURE_LAYOUT_UNKNOWN;
    rd.Flags = flags;
    ID3D12Resource *res = NULL;
    if (FAILED(ID3D12Device_CreateCommittedResource(c->dev, &hp, D3D12_HEAP_FLAG_NONE, &rd,
                                                    state, clear, &IID_ID3D12Resource, (void **)&res)))
        return NULL;
    return res;
}

/* The window-sized targets: the MSAA colour (when on) and the depth buffer. */
static int make_frame_targets(lkd_ctx *c, UINT w, UINT h)
{
    if (c->msaa > 1) {
        D3D12_CLEAR_VALUE cv;
        memset(&cv, 0, sizeof cv);
        cv.Format = LKD_FMT;
        c->msaa_color = make_target(c, w, h, LKD_FMT, c->msaa,
                                    D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET,
                                    D3D12_RESOURCE_STATE_RENDER_TARGET, &cv);
        if (c->msaa_color == NULL)
            return 0;
        ID3D12Device_CreateRenderTargetView(c->dev, c->msaa_color, NULL, rtv_at(c, 2));
    }
    D3D12_CLEAR_VALUE dv;
    memset(&dv, 0, sizeof dv);
    dv.Format = LKD_DEPTH_FMT;
    dv.DepthStencil.Depth = 1.0f;
    c->depth = make_target(c, w, h, LKD_DEPTH_FMT, c->msaa,
                           D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL,
                           D3D12_RESOURCE_STATE_DEPTH_WRITE, &dv);
    if (c->depth == NULL)
        return 0;
    ID3D12Device_CreateDepthStencilView(c->dev, c->depth, NULL, dsv_at(c, 0));
    return 1;
}

static int make_backbuffer_rtvs(lkd_ctx *c)
{
    for (UINT i = 0; i < LKD_FRAMES; i++) {
        if (FAILED(IDXGISwapChain3_GetBuffer(c->swapchain, i, &IID_ID3D12Resource,
                                             (void **)&c->backbuffers[i])))
            return 0;
        ID3D12Device_CreateRenderTargetView(c->dev, c->backbuffers[i], NULL, rtv_at(c, i));
    }
    return 1;
}

/* ---- pipeline construction ------------------------------------------------ */

static ID3DBlob *compile_shader(const char *src, const char *entry, const char *target,
                                char err[LKD_ERR_LEN])
{
    ID3DBlob *code = NULL;
    ID3DBlob *msgs = NULL;
    HRESULT hr = D3DCompile(src, strlen(src), "lookout.hlsl", NULL, NULL, entry, target,
                            D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &code, &msgs);
    if (FAILED(hr)) {
        if (err) {
            const char *m = msgs ? (const char *)ID3D10Blob_GetBufferPointer(msgs) : "no log";
            _snprintf_s(err, LKD_ERR_LEN, _TRUNCATE, "D3DCompile %s: %.180s", entry, m);
        }
        if (msgs)
            ID3D10Blob_Release(msgs);
        return NULL;
    }
    if (msgs)
        ID3D10Blob_Release(msgs);
    return code;
}

static int make_root_signature(lkd_ctx *c, char err[LKD_ERR_LEN])
{
    D3D12_DESCRIPTOR_RANGE range;
    memset(&range, 0, sizeof range);
    range.RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_SRV;
    range.NumDescriptors = 1;

    D3D12_ROOT_PARAMETER params[2];
    memset(params, 0, sizeof params);
    params[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_CBV;
    params[0].ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
    params[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
    params[1].DescriptorTable.NumDescriptorRanges = 1;
    params[1].DescriptorTable.pDescriptorRanges = &range;
    params[1].ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;

    D3D12_STATIC_SAMPLER_DESC smp;
    memset(&smp, 0, sizeof smp);
    smp.Filter = D3D12_FILTER_MIN_MAG_MIP_LINEAR;
    smp.AddressU = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
    smp.AddressV = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
    smp.AddressW = D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
    smp.ComparisonFunc = D3D12_COMPARISON_FUNC_NEVER;
    smp.MaxLOD = D3D12_FLOAT32_MAX;
    smp.ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;

    D3D12_ROOT_SIGNATURE_DESC rs;
    memset(&rs, 0, sizeof rs);
    rs.NumParameters = 2;
    rs.pParameters = params;
    rs.NumStaticSamplers = 1;
    rs.pStaticSamplers = &smp;
    rs.Flags = D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT;

    ID3DBlob *blob = NULL;
    ID3DBlob *msgs = NULL;
    HRESULT hr = D3D12SerializeRootSignature(&rs, D3D_ROOT_SIGNATURE_VERSION_1, &blob, &msgs);
    if (FAILED(hr)) {
        set_err(err, "serialize root signature", hr);
        if (msgs)
            ID3D10Blob_Release(msgs);
        return 0;
    }
    if (msgs)
        ID3D10Blob_Release(msgs);
    hr = ID3D12Device_CreateRootSignature(c->dev, 0, ID3D10Blob_GetBufferPointer(blob),
                                          ID3D10Blob_GetBufferSize(blob),
                                          &IID_ID3D12RootSignature, (void **)&c->root_sig);
    ID3D10Blob_Release(blob);
    if (FAILED(hr)) {
        set_err(err, "create root signature", hr);
        return 0;
    }
    return 1;
}

/* tile57_gpu_vertex, 32 B */
static const D3D12_INPUT_ELEMENT_DESC chart_layout[] = {
    { "WORLD", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 0, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0 },
    { "LOCALPX", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 8, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0 },
    { "SCAMIN", 0, DXGI_FORMAT_R32_FLOAT, 0, 16, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0 },
    { "PACKED", 0, DXGI_FORMAT_R32_UINT, 0, 20, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0 },
    { "COLOR", 0, DXGI_FORMAT_R8G8B8A8_UNORM, 0, 24, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0 },
    { "DEPTH", 0, DXGI_FORMAT_R32_FLOAT, 0, 28, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0 },
};

/* tile57_gpu_quad, 44 B */
static const D3D12_INPUT_ELEMENT_DESC quad_layout[] = {
    { "WORLD", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 0, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0 },
    { "LOCALPX", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 8, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0 },
    { "TEXCOORD", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 16, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0 },
    { "COLOR", 0, DXGI_FORMAT_R8G8B8A8_UNORM, 0, 24, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0 },
    { "WEIGHT", 0, DXGI_FORMAT_R32_FLOAT, 0, 28, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0 },
    { "SCAMIN", 0, DXGI_FORMAT_R32_FLOAT, 0, 32, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0 },
    { "PACKED", 0, DXGI_FORMAT_R32_UINT, 0, 36, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0 },
    { "DEPTH", 0, DXGI_FORMAT_R32_FLOAT, 0, 40, D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0 },
};

static ID3D12PipelineState *make_pso(lkd_ctx *c, ID3DBlob *vs, ID3DBlob *ps,
                                     const D3D12_INPUT_ELEMENT_DESC *layout, UINT layout_n,
                                     int depth_write)
{
    D3D12_GRAPHICS_PIPELINE_STATE_DESC d;
    memset(&d, 0, sizeof d);
    d.pRootSignature = c->root_sig;
    d.VS.pShaderBytecode = ID3D10Blob_GetBufferPointer(vs);
    d.VS.BytecodeLength = ID3D10Blob_GetBufferSize(vs);
    d.PS.pShaderBytecode = ID3D10Blob_GetBufferPointer(ps);
    d.PS.BytecodeLength = ID3D10Blob_GetBufferSize(ps);

    D3D12_RENDER_TARGET_BLEND_DESC *bl = &d.BlendState.RenderTarget[0];
    bl->BlendEnable = TRUE;
    bl->SrcBlend = D3D12_BLEND_SRC_ALPHA;
    bl->DestBlend = D3D12_BLEND_INV_SRC_ALPHA;
    bl->BlendOp = D3D12_BLEND_OP_ADD;
    bl->SrcBlendAlpha = D3D12_BLEND_ONE;
    bl->DestBlendAlpha = D3D12_BLEND_INV_SRC_ALPHA;
    bl->BlendOpAlpha = D3D12_BLEND_OP_ADD;
    bl->RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;

    d.SampleMask = 0xFFFFFFFFu;
    d.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
    d.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
    d.RasterizerState.DepthClipEnable = TRUE;

    d.DepthStencilState.DepthEnable = TRUE;
    d.DepthStencilState.DepthFunc = D3D12_COMPARISON_FUNC_LESS;
    d.DepthStencilState.DepthWriteMask =
        depth_write ? D3D12_DEPTH_WRITE_MASK_ALL : D3D12_DEPTH_WRITE_MASK_ZERO;

    d.InputLayout.pInputElementDescs = layout;
    d.InputLayout.NumElements = layout_n;
    d.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    d.NumRenderTargets = 1;
    d.RTVFormats[0] = LKD_FMT;
    d.DSVFormat = LKD_DEPTH_FMT;
    d.SampleDesc.Count = (UINT)c->msaa;

    ID3D12PipelineState *pso = NULL;
    if (FAILED(ID3D12Device_CreateGraphicsPipelineState(c->dev, &d, &IID_ID3D12PipelineState,
                                                        (void **)&pso)))
        return NULL;
    return pso;
}

static int make_pipelines(lkd_ctx *c, const char *hlsl, char err[LKD_ERR_LEN])
{
    ID3DBlob *chart_vs = compile_shader(hlsl, "chart_vs", "vs_5_0", err);
    ID3DBlob *chart_ps = compile_shader(hlsl, "chart_ps", "ps_5_0", err);
    ID3DBlob *pattern_vs = compile_shader(hlsl, "pattern_vs", "vs_5_0", err);
    ID3DBlob *pattern_ps = compile_shader(hlsl, "pattern_ps", "ps_5_0", err);
    ID3DBlob *sprite_vs = compile_shader(hlsl, "sprite_vs", "vs_5_0", err);
    ID3DBlob *sprite_ps = compile_shader(hlsl, "sprite_ps", "ps_5_0", err);
    ID3DBlob *sdf_ps = compile_shader(hlsl, "sdf_ps", "ps_5_0", err);
    int ok = chart_vs && chart_ps && pattern_vs && pattern_ps && sprite_vs && sprite_ps && sdf_ps;
    if (ok) {
        c->psos[PSO_CHART] = make_pso(c, chart_vs, chart_ps, chart_layout,
                                      _countof(chart_layout), 0);
        c->psos[PSO_CHART_OPAQUE] = make_pso(c, chart_vs, chart_ps, chart_layout,
                                             _countof(chart_layout), 1);
        c->psos[PSO_PATTERN] = make_pso(c, pattern_vs, pattern_ps, chart_layout,
                                        _countof(chart_layout), 0);
        c->psos[PSO_SPRITE] = make_pso(c, sprite_vs, sprite_ps, quad_layout,
                                       _countof(quad_layout), 0);
        c->psos[PSO_SDF] = make_pso(c, sprite_vs, sdf_ps, quad_layout,
                                    _countof(quad_layout), 0);
        /* The raster underlay: sprite shading, but depth WRITE (see
         * LKD_PIPE_RASTER in the header). */
        c->psos[PSO_RASTER] = make_pso(c, sprite_vs, sprite_ps, quad_layout,
                                       _countof(quad_layout), 1);
        ok = c->psos[PSO_CHART] && c->psos[PSO_CHART_OPAQUE] && c->psos[PSO_PATTERN] &&
             c->psos[PSO_SPRITE] && c->psos[PSO_SDF] && c->psos[PSO_RASTER];
        if (!ok)
            set_err(err, "create pipeline state", E_FAIL);
    }
    if (chart_vs) ID3D10Blob_Release(chart_vs);
    if (chart_ps) ID3D10Blob_Release(chart_ps);
    if (pattern_vs) ID3D10Blob_Release(pattern_vs);
    if (pattern_ps) ID3D10Blob_Release(pattern_ps);
    if (sprite_vs) ID3D10Blob_Release(sprite_vs);
    if (sprite_ps) ID3D10Blob_Release(sprite_ps);
    if (sdf_ps) ID3D10Blob_Release(sdf_ps);
    return ok;
}

/* ---- create / destroy ----------------------------------------------------- */

lkd_ctx *lkd_create(uint32_t w_px, uint32_t h_px, int want_swapchain,
                    const char *hlsl_source, int want_msaa, int *msaa_out,
                    char err[LKD_ERR_LEN])
{
    if (err)
        err[0] = 0;
    lkd_ctx *c = (lkd_ctx *)calloc(1, sizeof *c);
    if (c == NULL)
        return NULL;
    InitializeSRWLock(&c->upload_lock);
    InitializeSRWLock(&c->res_lock);
    HRESULT hr;

    if (getenv("LOOKOUT_D3D12_DEBUG") != NULL) {
        ID3D12Debug *dbg = NULL;
        if (SUCCEEDED(D3D12GetDebugInterface(&IID_ID3D12Debug, (void **)&dbg))) {
            ID3D12Debug_EnableDebugLayer(dbg);
            ID3D12Debug_Release(dbg);
        }
    }

    hr = CreateDXGIFactory2(0, &IID_IDXGIFactory4, (void **)&c->factory);
    if (FAILED(hr)) {
        set_err(err, "CreateDXGIFactory2", hr);
        goto fail;
    }

    /* Hardware first; WARP (the in-box software rasterizer) when there is
     * none, so the app runs on every Windows machine. */
    if (getenv("LOOKOUT_WARP") == NULL)
        hr = D3D12CreateDevice(NULL, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&c->dev);
    else
        hr = E_FAIL;
    if (FAILED(hr)) {
        IDXGIAdapter *warp = NULL;
        hr = IDXGIFactory4_EnumWarpAdapter(c->factory, &IID_IDXGIAdapter, (void **)&warp);
        if (SUCCEEDED(hr)) {
            hr = D3D12CreateDevice((IUnknown *)warp, D3D_FEATURE_LEVEL_11_0,
                                   &IID_ID3D12Device, (void **)&c->dev);
            IDXGIAdapter_Release(warp);
        }
        if (FAILED(hr)) {
            set_err(err, "D3D12CreateDevice", hr);
            goto fail;
        }
        fprintf(stderr, "d3d12: WARP (software) device\n");
    }

    D3D12_COMMAND_QUEUE_DESC qd;
    memset(&qd, 0, sizeof qd);
    hr = ID3D12Device_CreateCommandQueue(c->dev, &qd, &IID_ID3D12CommandQueue, (void **)&c->queue);
    if (FAILED(hr)) {
        set_err(err, "CreateCommandQueue", hr);
        goto fail;
    }

    c->msaa = 1;
    if (want_msaa) {
        D3D12_FEATURE_DATA_MULTISAMPLE_QUALITY_LEVELS q;
        memset(&q, 0, sizeof q);
        q.Format = LKD_FMT;
        q.SampleCount = 4;
        if (SUCCEEDED(ID3D12Device_CheckFeatureSupport(c->dev, D3D12_FEATURE_MULTISAMPLE_QUALITY_LEVELS,
                                                       &q, sizeof q)) &&
            q.NumQualityLevels > 0)
            c->msaa = 4;
    }
    if (msaa_out)
        *msaa_out = c->msaa > 1;

    /* descriptor heaps */
    c->rtv_inc = ID3D12Device_GetDescriptorHandleIncrementSize(c->dev, D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
    c->dsv_inc = ID3D12Device_GetDescriptorHandleIncrementSize(c->dev, D3D12_DESCRIPTOR_HEAP_TYPE_DSV);
    c->srv_inc = ID3D12Device_GetDescriptorHandleIncrementSize(c->dev, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    {
        D3D12_DESCRIPTOR_HEAP_DESC hd;
        memset(&hd, 0, sizeof hd);
        hd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
        hd.NumDescriptors = 8;
        hr = ID3D12Device_CreateDescriptorHeap(c->dev, &hd, &IID_ID3D12DescriptorHeap, (void **)&c->rtv_heap);
        if (FAILED(hr)) { set_err(err, "rtv heap", hr); goto fail; }
        hd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_DSV;
        hd.NumDescriptors = 4;
        hr = ID3D12Device_CreateDescriptorHeap(c->dev, &hd, &IID_ID3D12DescriptorHeap, (void **)&c->dsv_heap);
        if (FAILED(hr)) { set_err(err, "dsv heap", hr); goto fail; }
        hd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
        hd.NumDescriptors = LKD_SRV_SLOTS;
        hd.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
        hr = ID3D12Device_CreateDescriptorHeap(c->dev, &hd, &IID_ID3D12DescriptorHeap, (void **)&c->srv_heap);
        if (FAILED(hr)) { set_err(err, "srv heap", hr); goto fail; }
    }
    for (int i = 0; i < LKD_SRV_SLOTS; i++)
        c->srv_free[i] = LKD_SRV_SLOTS - 1 - i; /* pop from the end -> slot 0 first */
    c->srv_free_count = LKD_SRV_SLOTS;

    if (!make_root_signature(c, err) || !make_pipelines(c, hlsl_source, err))
        goto fail;

    /* frame machinery */
    for (int i = 0; i < LKD_FRAMES; i++) {
        hr = ID3D12Device_CreateCommandAllocator(c->dev, D3D12_COMMAND_LIST_TYPE_DIRECT,
                                                 &IID_ID3D12CommandAllocator, (void **)&c->alloc[i]);
        if (FAILED(hr)) { set_err(err, "command allocator", hr); goto fail; }
        c->uring[i] = make_buffer(c, D3D12_HEAP_TYPE_UPLOAD, LKD_URING_BYTES,
                                  D3D12_RESOURCE_STATE_GENERIC_READ);
        if (c->uring[i] == NULL) { set_err(err, "uniform ring", E_FAIL); goto fail; }
        D3D12_RANGE none = { 0, 0 };
        void *p = NULL;
        if (FAILED(ID3D12Resource_Map(c->uring[i], 0, &none, &p))) {
            set_err(err, "map uniform ring", E_FAIL);
            goto fail;
        }
        c->uring_ptr[i] = (uint8_t *)p;
        c->uring_va[i] = ID3D12Resource_GetGPUVirtualAddress(c->uring[i]);
    }
    hr = ID3D12Device_CreateCommandList(c->dev, 0, D3D12_COMMAND_LIST_TYPE_DIRECT, c->alloc[0],
                                        NULL, &IID_ID3D12GraphicsCommandList, (void **)&c->list);
    if (FAILED(hr)) { set_err(err, "command list", hr); goto fail; }
    ID3D12GraphicsCommandList_Close(c->list);
    hr = ID3D12Device_CreateFence(c->dev, 0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, (void **)&c->fence);
    if (FAILED(hr)) { set_err(err, "fence", hr); goto fail; }
    c->fence_event = CreateEventW(NULL, FALSE, FALSE, NULL);

    /* GPU timing: two timestamps per frame slot */
    {
        D3D12_QUERY_HEAP_DESC qh;
        memset(&qh, 0, sizeof qh);
        qh.Type = D3D12_QUERY_HEAP_TYPE_TIMESTAMP;
        qh.Count = LKD_FRAMES * 2;
        if (SUCCEEDED(ID3D12Device_CreateQueryHeap(c->dev, &qh, &IID_ID3D12QueryHeap,
                                                   (void **)&c->ts_heap))) {
            c->ts_readback = make_buffer(c, D3D12_HEAP_TYPE_READBACK, LKD_FRAMES * 2 * sizeof(UINT64),
                                         D3D12_RESOURCE_STATE_COPY_DEST);
            D3D12_RANGE all = { 0, LKD_FRAMES * 2 * sizeof(UINT64) };
            void *p = NULL;
            if (c->ts_readback != NULL && SUCCEEDED(ID3D12Resource_Map(c->ts_readback, 0, &all, &p)))
                c->ts_ptr = (UINT64 *)p;
            ID3D12CommandQueue_GetTimestampFrequency(c->queue, &c->ts_freq);
        }
    }

    /* texture uploads: private queue so any thread can create a texture */
    hr = ID3D12Device_CreateCommandQueue(c->dev, &qd, &IID_ID3D12CommandQueue, (void **)&c->up_queue);
    if (FAILED(hr)) { set_err(err, "upload queue", hr); goto fail; }
    hr = ID3D12Device_CreateCommandAllocator(c->dev, D3D12_COMMAND_LIST_TYPE_DIRECT,
                                             &IID_ID3D12CommandAllocator, (void **)&c->up_alloc);
    if (FAILED(hr)) { set_err(err, "upload allocator", hr); goto fail; }
    hr = ID3D12Device_CreateCommandList(c->dev, 0, D3D12_COMMAND_LIST_TYPE_DIRECT, c->up_alloc,
                                        NULL, &IID_ID3D12GraphicsCommandList, (void **)&c->up_list);
    if (FAILED(hr)) { set_err(err, "upload list", hr); goto fail; }
    ID3D12GraphicsCommandList_Close(c->up_list);
    hr = ID3D12Device_CreateFence(c->dev, 0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, (void **)&c->up_fence);
    if (FAILED(hr)) { set_err(err, "upload fence", hr); goto fail; }
    c->up_event = CreateEventW(NULL, FALSE, FALSE, NULL);

    c->width = w_px > 0 ? w_px : 8;
    c->height = h_px > 0 ? h_px : 8;
    if (want_swapchain) {
        DXGI_SWAP_CHAIN_DESC1 sd;
        memset(&sd, 0, sizeof sd);
        sd.Width = c->width;
        sd.Height = c->height;
        sd.Format = LKD_FMT;
        sd.SampleDesc.Count = 1;
        sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        sd.BufferCount = LKD_FRAMES;
        sd.Scaling = DXGI_SCALING_STRETCH;
        sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
        sd.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
        IDXGISwapChain1 *sc1 = NULL;
        hr = IDXGIFactory4_CreateSwapChainForComposition(c->factory, (IUnknown *)c->queue,
                                                         &sd, NULL, &sc1);
        if (FAILED(hr)) {
            set_err(err, "CreateSwapChainForComposition", hr);
            goto fail;
        }
        hr = IDXGISwapChain1_QueryInterface(sc1, &IID_IDXGISwapChain3, (void **)&c->swapchain);
        IDXGISwapChain1_Release(sc1);
        if (FAILED(hr)) {
            set_err(err, "IDXGISwapChain3", hr);
            goto fail;
        }
        if (!make_backbuffer_rtvs(c)) {
            set_err(err, "swapchain buffers", E_FAIL);
            goto fail;
        }
        if (!make_frame_targets(c, c->width, c->height)) {
            set_err(err, "frame targets", E_FAIL);
            goto fail;
        }
    }
    return c;

fail:
    lkd_destroy(c);
    return NULL;
}

void lkd_destroy(lkd_ctx *c)
{
    if (c == NULL)
        return;
    if (c->queue && c->fence && c->fence_event)
        gpu_flush(c);
    if (c->up_queue && c->up_fence && c->up_event) {
        UINT64 v = ++c->up_value;
        ID3D12CommandQueue_Signal(c->up_queue, c->up_fence, v);
        fence_wait(c->up_fence, v, c->up_event);
    }
    drain_retired(c, 1);
    for (int i = 0; i < LKD_FRAMES; i++) {
        if (c->uring[i]) {
            ID3D12Resource_Unmap(c->uring[i], 0, NULL);
            ID3D12Resource_Release(c->uring[i]);
        }
        if (c->alloc[i])
            ID3D12CommandAllocator_Release(c->alloc[i]);
        if (c->backbuffers[i])
            ID3D12Resource_Release(c->backbuffers[i]);
    }
    if (c->ts_readback) {
        ID3D12Resource_Unmap(c->ts_readback, 0, NULL);
        ID3D12Resource_Release(c->ts_readback);
    }
    if (c->ts_heap)
        ID3D12QueryHeap_Release(c->ts_heap);
    if (c->msaa_color)
        ID3D12Resource_Release(c->msaa_color);
    if (c->depth)
        ID3D12Resource_Release(c->depth);
    if (c->swapchain)
        IDXGISwapChain3_Release(c->swapchain);
    for (int i = 0; i < PSO_COUNT; i++)
        if (c->psos[i])
            ID3D12PipelineState_Release(c->psos[i]);
    if (c->root_sig)
        ID3D12RootSignature_Release(c->root_sig);
    if (c->rtv_heap)
        ID3D12DescriptorHeap_Release(c->rtv_heap);
    if (c->dsv_heap)
        ID3D12DescriptorHeap_Release(c->dsv_heap);
    if (c->srv_heap)
        ID3D12DescriptorHeap_Release(c->srv_heap);
    if (c->list)
        ID3D12GraphicsCommandList_Release(c->list);
    if (c->fence)
        ID3D12Fence_Release(c->fence);
    if (c->fence_event)
        CloseHandle(c->fence_event);
    if (c->up_list)
        ID3D12GraphicsCommandList_Release(c->up_list);
    if (c->up_alloc)
        ID3D12CommandAllocator_Release(c->up_alloc);
    if (c->up_fence)
        ID3D12Fence_Release(c->up_fence);
    if (c->up_event)
        CloseHandle(c->up_event);
    if (c->up_queue)
        ID3D12CommandQueue_Release(c->up_queue);
    if (c->queue)
        ID3D12CommandQueue_Release(c->queue);
    if (c->dev)
        ID3D12Device_Release(c->dev);
    if (c->factory)
        IDXGIFactory4_Release(c->factory);
    free(c);
}

void *lkd_swapchain(lkd_ctx *c)
{
    return c ? (void *)c->swapchain : NULL;
}

int lkd_resize(lkd_ctx *c, uint32_t w_px, uint32_t h_px)
{
    if (c == NULL || c->swapchain == NULL)
        return 0;
    if (w_px < 8)
        w_px = 8;
    if (h_px < 8)
        h_px = 8;
    if (w_px == c->width && h_px == c->height)
        return 1;
    gpu_flush(c);
    for (int i = 0; i < LKD_FRAMES; i++) {
        if (c->backbuffers[i]) {
            ID3D12Resource_Release(c->backbuffers[i]);
            c->backbuffers[i] = NULL;
        }
        c->frame_fence[i] = 0;
    }
    if (c->msaa_color) {
        ID3D12Resource_Release(c->msaa_color);
        c->msaa_color = NULL;
    }
    if (c->depth) {
        ID3D12Resource_Release(c->depth);
        c->depth = NULL;
    }
    if (FAILED(IDXGISwapChain3_ResizeBuffers(c->swapchain, LKD_FRAMES, w_px, h_px, LKD_FMT, 0)))
        return 0;
    if (!make_backbuffer_rtvs(c) || !make_frame_targets(c, w_px, h_px))
        return 0;
    c->width = w_px;
    c->height = h_px;
    return 1;
}

void lkd_get_size(lkd_ctx *c, uint32_t *w_px, uint32_t *h_px)
{
    if (w_px)
        *w_px = c ? c->width : 0;
    if (h_px)
        *h_px = c ? c->height : 0;
}

/* ---- buffers and textures ------------------------------------------------- */

lkd_buf *lkd_new_buffer(lkd_ctx *c, const void *bytes, size_t len)
{
    if (c == NULL || bytes == NULL || len == 0)
        return NULL;
    ID3D12Resource *res = make_buffer(c, D3D12_HEAP_TYPE_UPLOAD, len,
                                      D3D12_RESOURCE_STATE_GENERIC_READ);
    if (res == NULL)
        return NULL;
    D3D12_RANGE none = { 0, 0 };
    void *p = NULL;
    if (FAILED(ID3D12Resource_Map(res, 0, &none, &p))) {
        ID3D12Resource_Release(res);
        return NULL;
    }
    memcpy(p, bytes, len);
    ID3D12Resource_Unmap(res, 0, NULL);
    lkd_buf *b = (lkd_buf *)calloc(1, sizeof *b);
    if (b == NULL) {
        ID3D12Resource_Release(res);
        return NULL;
    }
    b->ctx = c;
    b->res = res;
    b->len = len;
    return b;
}

void lkd_free_buffer(lkd_buf *b)
{
    if (b == NULL)
        return;
    retire_resource(b->ctx, b->res, -1);
    free(b);
}

lkd_tex *lkd_new_texture_rgba(lkd_ctx *c, const void *rgba, uint32_t w, uint32_t h)
{
    if (c == NULL || rgba == NULL || w == 0 || h == 0)
        return NULL;

    AcquireSRWLockExclusive(&c->res_lock);
    int slot = c->srv_free_count > 0 ? c->srv_free[--c->srv_free_count] : -1;
    ReleaseSRWLockExclusive(&c->res_lock);
    if (slot < 0)
        return NULL;

    ID3D12Resource *tex = make_target(c, w, h, DXGI_FORMAT_R8G8B8A8_UNORM, 1,
                                      D3D12_RESOURCE_FLAG_NONE, D3D12_RESOURCE_STATE_COMMON, NULL);
    UINT pitch = (w * 4 + D3D12_TEXTURE_DATA_PITCH_ALIGNMENT - 1) &
                 ~(D3D12_TEXTURE_DATA_PITCH_ALIGNMENT - 1);
    ID3D12Resource *staging =
        tex ? make_buffer(c, D3D12_HEAP_TYPE_UPLOAD, (UINT64)pitch * h,
                          D3D12_RESOURCE_STATE_GENERIC_READ)
            : NULL;
    if (tex == NULL || staging == NULL)
        goto fail;
    {
        D3D12_RANGE none = { 0, 0 };
        void *p = NULL;
        if (FAILED(ID3D12Resource_Map(staging, 0, &none, &p)))
            goto fail;
        for (uint32_t y = 0; y < h; y++)
            memcpy((uint8_t *)p + (size_t)y * pitch, (const uint8_t *)rgba + (size_t)y * w * 4, w * 4);
        ID3D12Resource_Unmap(staging, 0, NULL);
    }

    AcquireSRWLockExclusive(&c->upload_lock);
    {
        ID3D12CommandAllocator_Reset(c->up_alloc);
        ID3D12GraphicsCommandList_Reset(c->up_list, c->up_alloc, NULL);
        D3D12_TEXTURE_COPY_LOCATION dst, src;
        memset(&dst, 0, sizeof dst);
        memset(&src, 0, sizeof src);
        dst.pResource = tex;
        dst.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        src.pResource = staging;
        src.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
        src.PlacedFootprint.Footprint.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        src.PlacedFootprint.Footprint.Width = w;
        src.PlacedFootprint.Footprint.Height = h;
        src.PlacedFootprint.Footprint.Depth = 1;
        src.PlacedFootprint.Footprint.RowPitch = pitch;
        ID3D12GraphicsCommandList_CopyTextureRegion(c->up_list, &dst, 0, 0, 0, &src, NULL);
        /* implicit COMMON->COPY_DEST promotion above; back to COMMON so the
         * render queue promotes to PIXEL_SHADER_RESOURCE on first sample */
        barrier_transition(c->up_list, tex, D3D12_RESOURCE_STATE_COPY_DEST,
                           D3D12_RESOURCE_STATE_COMMON);
        ID3D12GraphicsCommandList_Close(c->up_list);
        ID3D12CommandList *lists[] = { (ID3D12CommandList *)c->up_list };
        ID3D12CommandQueue_ExecuteCommandLists(c->up_queue, 1, lists);
        UINT64 v = ++c->up_value;
        ID3D12CommandQueue_Signal(c->up_queue, c->up_fence, v);
        fence_wait(c->up_fence, v, c->up_event);
    }
    ReleaseSRWLockExclusive(&c->upload_lock);
    ID3D12Resource_Release(staging);
    staging = NULL;

    ID3D12Device_CreateShaderResourceView(c->dev, tex, NULL, srv_cpu_at(c, (UINT)slot));

    {
        lkd_tex *t = (lkd_tex *)calloc(1, sizeof *t);
        if (t == NULL)
            goto fail;
        t->ctx = c;
        t->res = tex;
        t->slot = slot;
        return t;
    }

fail:
    if (staging)
        ID3D12Resource_Release(staging);
    if (tex)
        ID3D12Resource_Release(tex);
    AcquireSRWLockExclusive(&c->res_lock);
    if (c->srv_free_count < LKD_SRV_SLOTS)
        c->srv_free[c->srv_free_count++] = slot;
    ReleaseSRWLockExclusive(&c->res_lock);
    return NULL;
}

void lkd_free_texture(lkd_tex *t)
{
    if (t == NULL)
        return;
    retire_resource(t->ctx, t->res, t->slot);
    free(t);
}

/* ---- frames --------------------------------------------------------------- */

static void frame_setup(lkd_ctx *c, lkd_frame *f, D3D12_CPU_DESCRIPTOR_HANDLE rtv,
                        D3D12_CPU_DESCRIPTOR_HANDLE dsv, const float clear[4], UINT w, UINT h)
{
    ID3D12GraphicsCommandList_OMSetRenderTargets(c->list, 1, &rtv, FALSE, &dsv);
    ID3D12GraphicsCommandList_ClearRenderTargetView(c->list, rtv, clear, 0, NULL);
    ID3D12GraphicsCommandList_ClearDepthStencilView(c->list, dsv, D3D12_CLEAR_FLAG_DEPTH,
                                                    1.0f, 0, 0, NULL);
    D3D12_VIEWPORT vp = { 0.0f, 0.0f, (FLOAT)w, (FLOAT)h, 0.0f, 1.0f };
    D3D12_RECT sc = { 0, 0, (LONG)w, (LONG)h };
    ID3D12GraphicsCommandList_RSSetViewports(c->list, 1, &vp);
    ID3D12GraphicsCommandList_RSSetScissorRects(c->list, 1, &sc);
    ID3D12GraphicsCommandList_IASetPrimitiveTopology(c->list, D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ID3D12GraphicsCommandList_SetGraphicsRootSignature(c->list, c->root_sig);
    ID3D12DescriptorHeap *heaps[] = { c->srv_heap };
    ID3D12GraphicsCommandList_SetDescriptorHeaps(c->list, 1, heaps);

    f->ctx = c;
    f->w = w;
    f->h = h;
    f->pipe = LKD_PIPE_CHART;
    f->depth_mode = 0;
    f->cur_pso = NULL;
    f->vbuf = NULL;
    f->bound_vbuf = NULL;
    f->bound_stride = 0;
    f->bound_ibuf = NULL;
    f->uofs = 0;
    f->uring_full_logged = 0;
}

lkd_frame *lkd_begin_frame(lkd_ctx *c, const float clear[4])
{
    if (c == NULL || c->swapchain == NULL)
        return NULL;
    lkd_frame *f = &c->frame;
    memset(f, 0, sizeof *f);
    UINT idx = IDXGISwapChain3_GetCurrentBackBufferIndex(c->swapchain);
    if (c->frame_fence[idx] != 0)
        fence_wait(c->fence, c->frame_fence[idx], c->fence_event);
    drain_retired(c, 0);

    /* the GPU time of the frame that last used this slot is complete now */
    if (c->ts_ptr != NULL && c->ts_pending[idx] && c->ts_freq != 0) {
        UINT64 t0 = c->ts_ptr[idx * 2], t1 = c->ts_ptr[idx * 2 + 1];
        if (t1 > t0)
            c->last_gpu_ms = (double)(t1 - t0) * 1000.0 / (double)c->ts_freq;
        c->ts_pending[idx] = 0;
    }

    ID3D12CommandAllocator_Reset(c->alloc[idx]);
    ID3D12GraphicsCommandList_Reset(c->list, c->alloc[idx], NULL);
    if (c->ts_heap != NULL)
        ID3D12GraphicsCommandList_EndQuery(c->list, c->ts_heap, D3D12_QUERY_TYPE_TIMESTAMP, idx * 2);

    D3D12_CPU_DESCRIPTOR_HANDLE rtv;
    if (c->msaa > 1) {
        rtv = rtv_at(c, 2); /* backbuffer transitions at resolve time */
    } else {
        barrier_transition(c->list, c->backbuffers[idx], D3D12_RESOURCE_STATE_PRESENT,
                           D3D12_RESOURCE_STATE_RENDER_TARGET);
        rtv = rtv_at(c, idx);
    }
    frame_setup(c, f, rtv, dsv_at(c, 0), clear, c->width, c->height);
    f->idx = idx;
    return f;
}

lkd_frame *lkd_begin_offscreen(lkd_ctx *c, uint32_t w_px, uint32_t h_px, const float clear[4])
{
    if (c == NULL || w_px == 0 || h_px == 0)
        return NULL;
    gpu_flush(c); /* allocator 0 and uniform ring 0 must be idle */
    drain_retired(c, 0);

    lkd_frame *f = &c->frame;
    memset(f, 0, sizeof *f);
    D3D12_CLEAR_VALUE cv;
    memset(&cv, 0, sizeof cv);
    cv.Format = LKD_FMT;
    f->os_color = make_target(c, w_px, h_px, LKD_FMT, c->msaa,
                              D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET,
                              D3D12_RESOURCE_STATE_RENDER_TARGET, &cv);
    if (c->msaa > 1)
        f->os_resolve = make_target(c, w_px, h_px, LKD_FMT, 1, D3D12_RESOURCE_FLAG_NONE,
                                    D3D12_RESOURCE_STATE_RESOLVE_DEST, NULL);
    D3D12_CLEAR_VALUE dv;
    memset(&dv, 0, sizeof dv);
    dv.Format = LKD_DEPTH_FMT;
    dv.DepthStencil.Depth = 1.0f;
    f->os_depth = make_target(c, w_px, h_px, LKD_DEPTH_FMT, c->msaa,
                              D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL,
                              D3D12_RESOURCE_STATE_DEPTH_WRITE, &dv);
    UINT pitch = (w_px * 4 + D3D12_TEXTURE_DATA_PITCH_ALIGNMENT - 1) &
                 ~(D3D12_TEXTURE_DATA_PITCH_ALIGNMENT - 1);
    f->os_readback = make_buffer(c, D3D12_HEAP_TYPE_READBACK, (UINT64)pitch * h_px,
                                 D3D12_RESOURCE_STATE_COPY_DEST);
    if (f->os_color == NULL || f->os_depth == NULL || f->os_readback == NULL ||
        (c->msaa > 1 && f->os_resolve == NULL)) {
        if (f->os_color) ID3D12Resource_Release(f->os_color);
        if (f->os_resolve) ID3D12Resource_Release(f->os_resolve);
        if (f->os_depth) ID3D12Resource_Release(f->os_depth);
        if (f->os_readback) ID3D12Resource_Release(f->os_readback);
        return NULL;
    }
    ID3D12Device_CreateRenderTargetView(c->dev, f->os_color, NULL, rtv_at(c, 3));
    ID3D12Device_CreateDepthStencilView(c->dev, f->os_depth, NULL, dsv_at(c, 1));

    ID3D12CommandAllocator_Reset(c->alloc[0]);
    ID3D12GraphicsCommandList_Reset(c->list, c->alloc[0], NULL);
    frame_setup(c, f, rtv_at(c, 3), dsv_at(c, 1), clear, w_px, h_px);
    f->offscreen = 1;
    return f;
}

/* ---- draw state ----------------------------------------------------------- */

void lkd_set_pipeline(lkd_frame *f, int which)
{
    f->pipe = which;
}

void lkd_set_depth_mode(lkd_frame *f, int opaque)
{
    f->depth_mode = opaque;
}

void lkd_bind_vbuf(lkd_frame *f, lkd_buf *b)
{
    f->vbuf = b;
}

void lkd_bind_texture(lkd_frame *f, lkd_tex *t)
{
    if (t == NULL)
        return;
    D3D12_GPU_DESCRIPTOR_HANDLE h = srv_gpu_at(f->ctx, (UINT)t->slot);
    ID3D12GraphicsCommandList_SetGraphicsRootDescriptorTable(f->ctx->list, 1, h);
}

void lkd_set_uniforms(lkd_frame *f, const void *bytes, size_t len)
{
    lkd_ctx *c = f->ctx;
    size_t ofs = (f->uofs + 255) & ~(size_t)255;
    if (ofs + len > LKD_URING_BYTES) {
        if (!f->uring_full_logged) {
            fprintf(stderr, "d3d12: uniform ring full (%zu draws)\n", ofs / 256);
            f->uring_full_logged = 1;
        }
        ofs = LKD_URING_BYTES - 256; /* reuse the last slot rather than fault */
    }
    UINT slot = f->offscreen ? 0 : f->idx;
    memcpy(c->uring_ptr[slot] + ofs, bytes, len);
    ID3D12GraphicsCommandList_SetGraphicsRootConstantBufferView(c->list, 0,
                                                                c->uring_va[slot] + ofs);
    f->uofs = ofs + len;
}

/* Bind the PSO and vertex stream the pending draw needs. The stride follows
 * the pipeline: chart/pattern read tile57_gpu_vertex, sprite/SDF tile57_gpu_quad. */
static void apply_draw_state(lkd_frame *f)
{
    lkd_ctx *c = f->ctx;
    int which = f->pipe == LKD_PIPE_CHART && f->depth_mode ? PSO_CHART_OPAQUE : f->pipe;
    ID3D12PipelineState *pso = c->psos[which];
    if (pso != f->cur_pso) {
        ID3D12GraphicsCommandList_SetPipelineState(c->list, pso);
        f->cur_pso = pso;
    }
    UINT stride = (f->pipe == LKD_PIPE_CHART || f->pipe == LKD_PIPE_PATTERN) ? 32 : 44;
    if (f->vbuf != NULL && (f->vbuf != f->bound_vbuf || stride != f->bound_stride)) {
        D3D12_VERTEX_BUFFER_VIEW v;
        v.BufferLocation = ID3D12Resource_GetGPUVirtualAddress(f->vbuf->res);
        v.SizeInBytes = (UINT)f->vbuf->len;
        v.StrideInBytes = stride;
        ID3D12GraphicsCommandList_IASetVertexBuffers(c->list, 0, 1, &v);
        f->bound_vbuf = f->vbuf;
        f->bound_stride = stride;
    }
}

void lkd_draw(lkd_frame *f, uint32_t first, uint32_t count)
{
    apply_draw_state(f);
    ID3D12GraphicsCommandList_DrawInstanced(f->ctx->list, count, 1, first, 0);
}

void lkd_draw_indexed(lkd_frame *f, lkd_buf *ib, uint32_t first, uint32_t count)
{
    apply_draw_state(f);
    if (ib != f->bound_ibuf) {
        D3D12_INDEX_BUFFER_VIEW v;
        v.BufferLocation = ID3D12Resource_GetGPUVirtualAddress(ib->res);
        v.SizeInBytes = (UINT)ib->len;
        v.Format = DXGI_FORMAT_R32_UINT;
        ID3D12GraphicsCommandList_IASetIndexBuffer(f->ctx->list, &v);
        f->bound_ibuf = ib;
    }
    ID3D12GraphicsCommandList_DrawIndexedInstanced(f->ctx->list, count, 1, first, 0, 0);
}

void lkd_end_frame(lkd_frame *f)
{
    if (f == NULL || f->offscreen)
        return;
    lkd_ctx *c = f->ctx;
    UINT idx = f->idx;
    if (c->msaa > 1) {
        D3D12_RESOURCE_BARRIER b[2];
        memset(b, 0, sizeof b);
        b[0].Type = b[1].Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
        b[0].Transition.pResource = c->msaa_color;
        b[0].Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
        b[0].Transition.StateBefore = D3D12_RESOURCE_STATE_RENDER_TARGET;
        b[0].Transition.StateAfter = D3D12_RESOURCE_STATE_RESOLVE_SOURCE;
        b[1].Transition.pResource = c->backbuffers[idx];
        b[1].Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
        b[1].Transition.StateBefore = D3D12_RESOURCE_STATE_PRESENT;
        b[1].Transition.StateAfter = D3D12_RESOURCE_STATE_RESOLVE_DEST;
        ID3D12GraphicsCommandList_ResourceBarrier(c->list, 2, b);
        ID3D12GraphicsCommandList_ResolveSubresource(c->list, c->backbuffers[idx], 0,
                                                     c->msaa_color, 0, LKD_FMT);
        b[0].Transition.StateBefore = D3D12_RESOURCE_STATE_RESOLVE_SOURCE;
        b[0].Transition.StateAfter = D3D12_RESOURCE_STATE_RENDER_TARGET;
        b[1].Transition.StateBefore = D3D12_RESOURCE_STATE_RESOLVE_DEST;
        b[1].Transition.StateAfter = D3D12_RESOURCE_STATE_PRESENT;
        ID3D12GraphicsCommandList_ResourceBarrier(c->list, 2, b);
    } else {
        barrier_transition(c->list, c->backbuffers[idx], D3D12_RESOURCE_STATE_RENDER_TARGET,
                           D3D12_RESOURCE_STATE_PRESENT);
    }
    if (c->ts_heap != NULL && c->ts_readback != NULL) {
        ID3D12GraphicsCommandList_EndQuery(c->list, c->ts_heap, D3D12_QUERY_TYPE_TIMESTAMP,
                                           idx * 2 + 1);
        ID3D12GraphicsCommandList_ResolveQueryData(c->list, c->ts_heap, D3D12_QUERY_TYPE_TIMESTAMP,
                                                   idx * 2, 2, c->ts_readback,
                                                   (UINT64)idx * 2 * sizeof(UINT64));
        c->ts_pending[idx] = 1;
    }
    ID3D12GraphicsCommandList_Close(c->list);
    ID3D12CommandList *lists[] = { (ID3D12CommandList *)c->list };
    ID3D12CommandQueue_ExecuteCommandLists(c->queue, 1, lists);
    IDXGISwapChain3_Present(c->swapchain, 1, 0);
    UINT64 v = ++c->fence_value;
    ID3D12CommandQueue_Signal(c->queue, c->fence, v);
    c->frame_fence[idx] = v;
}

double lkd_last_gpu_ms(lkd_ctx *c)
{
    return c ? c->last_gpu_ms : 0.0;
}

int lkd_end_offscreen_read(lkd_frame *f, void *out_bgra)
{
    if (f == NULL || !f->offscreen || out_bgra == NULL)
        return 0;
    lkd_ctx *c = f->ctx;
    UINT w = f->w, h = f->h;
    UINT pitch = (w * 4 + D3D12_TEXTURE_DATA_PITCH_ALIGNMENT - 1) &
                 ~(D3D12_TEXTURE_DATA_PITCH_ALIGNMENT - 1);

    ID3D12Resource *src_tex;
    if (c->msaa > 1) {
        barrier_transition(c->list, f->os_color, D3D12_RESOURCE_STATE_RENDER_TARGET,
                           D3D12_RESOURCE_STATE_RESOLVE_SOURCE);
        ID3D12GraphicsCommandList_ResolveSubresource(c->list, f->os_resolve, 0, f->os_color, 0,
                                                     LKD_FMT);
        barrier_transition(c->list, f->os_resolve, D3D12_RESOURCE_STATE_RESOLVE_DEST,
                           D3D12_RESOURCE_STATE_COPY_SOURCE);
        src_tex = f->os_resolve;
    } else {
        barrier_transition(c->list, f->os_color, D3D12_RESOURCE_STATE_RENDER_TARGET,
                           D3D12_RESOURCE_STATE_COPY_SOURCE);
        src_tex = f->os_color;
    }
    D3D12_TEXTURE_COPY_LOCATION dst, src;
    memset(&dst, 0, sizeof dst);
    memset(&src, 0, sizeof src);
    dst.pResource = f->os_readback;
    dst.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
    dst.PlacedFootprint.Footprint.Format = LKD_FMT;
    dst.PlacedFootprint.Footprint.Width = w;
    dst.PlacedFootprint.Footprint.Height = h;
    dst.PlacedFootprint.Footprint.Depth = 1;
    dst.PlacedFootprint.Footprint.RowPitch = pitch;
    src.pResource = src_tex;
    src.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    ID3D12GraphicsCommandList_CopyTextureRegion(c->list, &dst, 0, 0, 0, &src, NULL);
    ID3D12GraphicsCommandList_Close(c->list);
    ID3D12CommandList *lists[] = { (ID3D12CommandList *)c->list };
    ID3D12CommandQueue_ExecuteCommandLists(c->queue, 1, lists);
    gpu_flush(c);

    int ok = 0;
    D3D12_RANGE all = { 0, (SIZE_T)pitch * h };
    void *p = NULL;
    if (SUCCEEDED(ID3D12Resource_Map(f->os_readback, 0, &all, &p))) {
        for (UINT y = 0; y < h; y++)
            memcpy((uint8_t *)out_bgra + (size_t)y * w * 4, (uint8_t *)p + (size_t)y * pitch, w * 4);
        D3D12_RANGE none = { 0, 0 };
        ID3D12Resource_Unmap(f->os_readback, 0, &none);
        ok = 1;
    }
    ID3D12Resource_Release(f->os_color);
    if (f->os_resolve)
        ID3D12Resource_Release(f->os_resolve);
    ID3D12Resource_Release(f->os_depth);
    ID3D12Resource_Release(f->os_readback);
    f->os_color = f->os_resolve = f->os_depth = f->os_readback = NULL;
    return ok;
}
