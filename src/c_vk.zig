//! Vulkan (and, on Android, NDK) imports for the raw-Vulkan backend (gpu_vk.zig).
//! Android takes the NDK sysroot headers + loader; every other target takes the
//! vendored Khronos headers with no VK_USE_PLATFORM_* (those drag in X11/Wayland/
//! Windows SDKs), so gpu_vk.zig hand-declares the WSI structs and loads
//! vkCreate*SurfaceKHR via vkGetInstanceProcAddr.
const builtin = @import("builtin");

/// True when building for Android — its own headers, surface extension and log sink.
pub const android = builtin.target.abi == .android or builtin.target.abi == .androideabi;

pub const c = if (android) @cImport({
    @cDefine("VK_USE_PLATFORM_ANDROID_KHR", "1");
    @cInclude("vulkan/vulkan.h");
    @cInclude("android/native_window.h");
    @cInclude("android/log.h");
}) else @cImport({
    @cInclude("vulkan/vulkan.h");
});
