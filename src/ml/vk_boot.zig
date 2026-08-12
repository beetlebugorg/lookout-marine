//! The Vulkan context MapLibre's Android session borrows.
//!
//! MapLibre's Vulkan attach (attachVulkanSurface) wants a ready context —
//! instance, physical device, logical device, graphics queue — plus the
//! VkSurfaceKHR to present to; it builds its own swapchain over them. On
//! Apple the Metal attach conjures all of that from a CAMetalLayer, so this
//! file exists only for Android: the smallest honest bootstrap, distilled
//! from the native Vulkan renderer this branch removed. No swapchain, no
//! pipelines, no shaders — those are MapLibre's.
//!
//! Headers come from the NDK sysroot (the Android zig build always has it);
//! libvulkan.so is the loader Android ships, and its Android surface entry
//! point is exported directly, so everything here is a plain extern call.

const std = @import("std");

pub const vk = @cImport({
    @cDefine("VK_USE_PLATFORM_ANDROID_KHR", "1");
    @cInclude("vulkan/vulkan.h");
});

pub const Error = error{VulkanFailure};

fn check(r: vk.VkResult, what: []const u8) Error!void {
    if (r != vk.VK_SUCCESS) {
        std.log.err("vk_boot: {s} failed ({d})", .{ what, r });
        return Error.VulkanFailure;
    }
}

pub const Boot = struct {
    instance: vk.VkInstance,
    phys: vk.VkPhysicalDevice,
    device: vk.VkDevice,
    queue: vk.VkQueue,
    family: u32,
    surface: vk.VkSurfaceKHR,

    /// Tear down in reverse. Only after MapLibre's session is detached — it
    /// borrows every one of these handles.
    pub fn deinit(self: *Boot) void {
        if (self.surface != null) vk.vkDestroySurfaceKHR(self.instance, self.surface, null);
        if (self.device != null) vk.vkDestroyDevice(self.device, null);
        if (self.instance != null) vk.vkDestroyInstance(self.instance, null);
        self.* = undefined;
    }
};

/// Stand a presentable Vulkan context up over `native_window` (the
/// ANativeWindow the shell's Surface yields).
pub fn init(native_window: *anyopaque) Error!Boot {
    var app = std.mem.zeroes(vk.VkApplicationInfo);
    app.sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app.pApplicationName = "lookout marine";
    app.apiVersion = vk.VK_API_VERSION_1_0;

    const inst_exts = [_][*:0]const u8{ "VK_KHR_surface", "VK_KHR_android_surface" };
    var ici = std.mem.zeroes(vk.VkInstanceCreateInfo);
    ici.sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    ici.pApplicationInfo = &app;
    ici.enabledExtensionCount = inst_exts.len;
    ici.ppEnabledExtensionNames = &inst_exts;
    var instance: vk.VkInstance = null;
    try check(vk.vkCreateInstance(&ici, null, &instance), "vkCreateInstance");
    errdefer vk.vkDestroyInstance(instance, null);

    var ndev: u32 = 0;
    _ = vk.vkEnumeratePhysicalDevices(instance, &ndev, null);
    if (ndev == 0) return Error.VulkanFailure;
    var devs: [8]vk.VkPhysicalDevice = @splat(null);
    if (ndev > devs.len) ndev = devs.len;
    _ = vk.vkEnumeratePhysicalDevices(instance, &ndev, &devs);
    const phys = devs[0];

    var nq: u32 = 0;
    vk.vkGetPhysicalDeviceQueueFamilyProperties(phys, &nq, null);
    var qprops: [16]vk.VkQueueFamilyProperties = undefined;
    if (nq > qprops.len) nq = qprops.len;
    vk.vkGetPhysicalDeviceQueueFamilyProperties(phys, &nq, &qprops);
    var family: u32 = 0;
    var found = false;
    for (qprops[0..nq], 0..) |qp, i| {
        if (qp.queueFlags & vk.VK_QUEUE_GRAPHICS_BIT != 0) {
            family = @intCast(i);
            found = true;
            break;
        }
    }
    if (!found) return Error.VulkanFailure;

    const prio: f32 = 1.0;
    var qci = std.mem.zeroes(vk.VkDeviceQueueCreateInfo);
    qci.sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    qci.queueFamilyIndex = family;
    qci.queueCount = 1;
    qci.pQueuePriorities = &prio;
    const dev_exts = [_][*:0]const u8{"VK_KHR_swapchain"};
    var dci = std.mem.zeroes(vk.VkDeviceCreateInfo);
    dci.sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    dci.queueCreateInfoCount = 1;
    dci.pQueueCreateInfos = &qci;
    dci.enabledExtensionCount = dev_exts.len;
    dci.ppEnabledExtensionNames = &dev_exts;
    var device: vk.VkDevice = null;
    try check(vk.vkCreateDevice(phys, &dci, null, &device), "vkCreateDevice");
    errdefer vk.vkDestroyDevice(device, null);

    var queue: vk.VkQueue = null;
    vk.vkGetDeviceQueue(device, family, 0, &queue);

    var sci = std.mem.zeroes(vk.VkAndroidSurfaceCreateInfoKHR);
    sci.sType = vk.VK_STRUCTURE_TYPE_ANDROID_SURFACE_CREATE_INFO_KHR;
    sci.window = @ptrCast(native_window);
    var surface: vk.VkSurfaceKHR = null;
    try check(vk.vkCreateAndroidSurfaceKHR(instance, &sci, null, &surface), "vkCreateAndroidSurfaceKHR");

    return .{
        .instance = instance,
        .phys = phys,
        .device = device,
        .queue = queue,
        .family = family,
        .surface = surface,
    };
}
