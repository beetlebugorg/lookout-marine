//! Vulkan + Android NDK imports for the raw-Vulkan backend (gpu_vk.zig).
//! Android-only: the NDK sysroot provides vulkan/vulkan.h (the platform define
//! pulls in vulkan_android.h for VK_KHR_android_surface) and the loader
//! (libvulkan.so, linked by the app's CMake) exports every core 1.0 + WSI entry
//! point directly, so no vkGetInstanceProcAddr loading dance is needed.
pub const c = @cImport({
    @cDefine("VK_USE_PLATFORM_ANDROID_KHR", "1");
    @cInclude("vulkan/vulkan.h");
    @cInclude("android/native_window.h");
    @cInclude("android/log.h");
});
