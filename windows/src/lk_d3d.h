/* lk_d3d — the D3D12 side of the SwapChainPanel present path.
 *
 * Owns the device, queue, composition swapchain, two shared render textures the
 * Vulkan core draws into, and the shared timeline fence. Per frame the core
 * renders texture[i] and signals the fence; present() GPU-waits, copies the
 * texture to the back buffer, signals copy-done, and presents. */
#ifndef LK_D3D_H
#define LK_D3D_H

#include <d3d12.h>
#include <dxgi1_4.h>
#include <lookout.h>

struct LkD3d {
    IDXGIFactory4 *factory = nullptr;
    ID3D12Device *device = nullptr;
    ID3D12CommandQueue *queue = nullptr;
    IDXGISwapChain3 *swapchain = nullptr;
    ID3D12Resource *shared_tex[2] = {};
    HANDLE shared_handle[2] = {};
    ID3D12Fence *fence = nullptr;
    HANDLE fence_handle = nullptr;
    ID3D12CommandAllocator *cmd_alloc = nullptr;
    ID3D12GraphicsCommandList *cmd_list = nullptr;
    HANDLE flush_event = nullptr;

    UINT64 next_value = 0;        /* last issued fence value */
    UINT64 copy_done[2] = {};     /* fence value after the last copy of texture i */
    UINT width = 0, height = 0;
    LUID adapter_luid = {};

    bool init(UINT w, UINT h);
    bool resize(UINT w, UINT h);
    /* Fill the ABI struct the core imports. */
    void fill_target(lookout_dxgi_target *out) const;
    /* Copy texture `index` (rendered + fence-signalled at `render_value`) to the
     * back buffer and present. Returns false on device loss. */
    bool present(UINT index, UINT64 render_value);
    void flush();
    void destroy();

private:
    bool create_shared(UINT w, UINT h);
    void release_shared();
};

#endif /* LK_D3D_H */
