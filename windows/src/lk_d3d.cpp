#include "lk_d3d.h"

#include <stdio.h>

#define LK_FMT DXGI_FORMAT_B8G8R8A8_UNORM

template <typename T>
static void release(T *&p)
{
    if (p) {
        p->Release();
        p = nullptr;
    }
}

bool LkD3d::init(UINT w, UINT h)
{
    width = w;
    height = h;

    if (FAILED(CreateDXGIFactory2(0, IID_PPV_ARGS(&factory))))
        return false;

    /* First hardware adapter that takes a 12-class device. */
    IDXGIAdapter1 *adapter = nullptr;
    for (UINT i = 0; factory->EnumAdapters1(i, &adapter) != DXGI_ERROR_NOT_FOUND; ++i) {
        DXGI_ADAPTER_DESC1 desc{};
        adapter->GetDesc1(&desc);
        if (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) {
            adapter->Release();
            adapter = nullptr;
            continue;
        }
        if (SUCCEEDED(D3D12CreateDevice(adapter, D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&device)))) {
            adapter_luid = desc.AdapterLuid;
            break;
        }
        adapter->Release();
        adapter = nullptr;
    }
    if (adapter)
        adapter->Release();
    if (!device) {
        fprintf(stderr, "d3d: no hardware D3D12 adapter\n");
        return false;
    }

    D3D12_COMMAND_QUEUE_DESC qd{};
    qd.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
    if (FAILED(device->CreateCommandQueue(&qd, IID_PPV_ARGS(&queue))))
        return false;

    DXGI_SWAP_CHAIN_DESC1 sd{};
    sd.Width = w;
    sd.Height = h;
    sd.Format = LK_FMT;
    sd.SampleDesc = { 1, 0 };
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.BufferCount = 2;
    sd.Scaling = DXGI_SCALING_STRETCH;
    sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
    sd.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
    IDXGISwapChain1 *sc1 = nullptr;
    if (FAILED(factory->CreateSwapChainForComposition(queue, &sd, nullptr, &sc1)))
        return false;
    HRESULT hr = sc1->QueryInterface(IID_PPV_ARGS(&swapchain));
    sc1->Release();
    if (FAILED(hr))
        return false;

    if (FAILED(device->CreateFence(0, D3D12_FENCE_FLAG_SHARED, IID_PPV_ARGS(&fence))))
        return false;
    if (FAILED(device->CreateSharedHandle(fence, nullptr, GENERIC_ALL, nullptr, &fence_handle)))
        return false;

    if (FAILED(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&cmd_alloc))))
        return false;
    if (FAILED(device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, cmd_alloc, nullptr,
                                         IID_PPV_ARGS(&cmd_list))))
        return false;
    cmd_list->Close();

    flush_event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    return create_shared(w, h);
}

bool LkD3d::create_shared(UINT w, UINT h)
{
    D3D12_HEAP_PROPERTIES heap{};
    heap.Type = D3D12_HEAP_TYPE_DEFAULT;
    D3D12_RESOURCE_DESC rd{};
    rd.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    rd.Width = w;
    rd.Height = h;
    rd.DepthOrArraySize = 1;
    rd.MipLevels = 1;
    rd.Format = LK_FMT;
    rd.SampleDesc = { 1, 0 };
    rd.Layout = D3D12_TEXTURE_LAYOUT_UNKNOWN;
    rd.Flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;

    for (int i = 0; i < 2; ++i) {
        if (FAILED(device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_SHARED, &rd,
                                                   D3D12_RESOURCE_STATE_COMMON, nullptr,
                                                   IID_PPV_ARGS(&shared_tex[i]))))
            return false;
        if (FAILED(device->CreateSharedHandle(shared_tex[i], nullptr, GENERIC_ALL, nullptr,
                                              &shared_handle[i])))
            return false;
        copy_done[i] = 0;
    }
    return true;
}

void LkD3d::release_shared()
{
    for (int i = 0; i < 2; ++i) {
        if (shared_handle[i]) {
            CloseHandle(shared_handle[i]);
            shared_handle[i] = nullptr;
        }
        release(shared_tex[i]);
    }
}

bool LkD3d::resize(UINT w, UINT h)
{
    if (w == 0 || h == 0)
        return false;
    flush();
    release_shared();
    if (FAILED(swapchain->ResizeBuffers(2, w, h, LK_FMT, 0)))
        return false;
    width = w;
    height = h;
    return create_shared(w, h);
}

void LkD3d::fill_target(lookout_dxgi_target *out) const
{
    *out = {};
    out->buffers[0] = shared_handle[0];
    out->buffers[1] = shared_handle[1];
    out->buffer_count = 2;
    out->fence = fence_handle;
    out->dxgi_format = (uint32_t)LK_FMT;
    out->width = width;
    out->height = height;
    out->adapter_luid_low = adapter_luid.LowPart;
    out->adapter_luid_high = adapter_luid.HighPart;
}

bool LkD3d::present(UINT index, UINT64 render_value)
{
    queue->Wait(fence, render_value);

    ID3D12Resource *back = nullptr;
    UINT bi = swapchain->GetCurrentBackBufferIndex();
    if (FAILED(swapchain->GetBuffer(bi, IID_PPV_ARGS(&back))))
        return false;

    cmd_alloc->Reset();
    cmd_list->Reset(cmd_alloc, nullptr);
    D3D12_RESOURCE_BARRIER b[2]{};
    b[0].Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    b[0].Transition = { back, D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
                        D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_COPY_DEST };
    b[1].Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    b[1].Transition = { shared_tex[index], D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
                        D3D12_RESOURCE_STATE_COMMON, D3D12_RESOURCE_STATE_COPY_SOURCE };
    cmd_list->ResourceBarrier(2, b);
    cmd_list->CopyResource(back, shared_tex[index]);
    D3D12_RESOURCE_BARRIER r[2] = { b[0], b[1] };
    r[0].Transition.StateBefore = D3D12_RESOURCE_STATE_COPY_DEST;
    r[0].Transition.StateAfter = D3D12_RESOURCE_STATE_PRESENT;
    r[1].Transition.StateBefore = D3D12_RESOURCE_STATE_COPY_SOURCE;
    r[1].Transition.StateAfter = D3D12_RESOURCE_STATE_COMMON;
    cmd_list->ResourceBarrier(2, r);
    cmd_list->Close();
    ID3D12CommandList *lists[] = { cmd_list };
    queue->ExecuteCommandLists(1, lists);
    back->Release();

    copy_done[index] = ++next_value;
    queue->Signal(fence, copy_done[index]);
    return SUCCEEDED(swapchain->Present(1, 0));
}

void LkD3d::flush()
{
    if (!queue || !fence)
        return;
    UINT64 v = ++next_value;
    queue->Signal(fence, v);
    if (fence->GetCompletedValue() < v && flush_event) {
        fence->SetEventOnCompletion(v, flush_event);
        WaitForSingleObject(flush_event, 2000);
    }
}

void LkD3d::destroy()
{
    flush();
    release_shared();
    if (fence_handle) {
        CloseHandle(fence_handle);
        fence_handle = nullptr;
    }
    release(fence);
    release(cmd_list);
    release(cmd_alloc);
    release(swapchain);
    release(queue);
    release(device);
    release(factory);
    if (flush_event) {
        CloseHandle(flush_event);
        flush_event = nullptr;
    }
}
