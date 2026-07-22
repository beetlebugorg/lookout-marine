//  VulkanBootstrap.swift — make the SDL_GPU Vulkan (MoltenVK) backend discoverable.
//
//  lookout's shaders are SPIR-V, so on macOS SDL_GPU needs its Vulkan backend,
//  which needs the Vulkan loader + a MoltenVK ICD. In a dev build those live in
//  Homebrew (molten-vk + vulkan-loader). We point the loader at the ICD and
//  preload libvulkan by full path so SDL's `dlopen("libvulkan.1.dylib")` resolves
//  even when /opt/homebrew/lib isn't on the dyld search path.
//
//  Called once at startup, before any chart opens. The bundle's Info.plist also
//  sets LSEnvironment as a belt-and-suspenders for double-click launches. For
//  distribution you'd bundle MoltenVK inside the .app and point here at that copy.

#if os(macOS)
import Foundation

enum VulkanBootstrap {
    static func configure() {
        let fm = FileManager.default

        // 1) Point the Vulkan loader at a MoltenVK ICD (unless already set).
        if getenv("VK_ICD_FILENAMES") == nil && getenv("VK_DRIVER_FILES") == nil {
            let icds = [
                "/opt/homebrew/etc/vulkan/icd.d/MoltenVK_icd.json",
                "/opt/homebrew/share/vulkan/icd.d/MoltenVK_icd.json",
                "/usr/local/etc/vulkan/icd.d/MoltenVK_icd.json",
                "/usr/local/share/vulkan/icd.d/MoltenVK_icd.json",
            ]
            if let icd = icds.first(where: { fm.fileExists(atPath: $0) }) {
                setenv("VK_ICD_FILENAMES", icd, 1)
                setenv("VK_DRIVER_FILES", icd, 1)   // newer loaders read this name
                lkLog("Vulkan ICD → \(icd)")
            } else {
                lkLog("no MoltenVK ICD found — install: brew install molten-vk vulkan-loader")
            }
        }

        // 2) Preload the loader (or MoltenVK) by full path so SDL's leaf-name
        //    dlopen resolves it.
        let loaders = [
            "/opt/homebrew/lib/libvulkan.1.dylib",
            "/usr/local/lib/libvulkan.1.dylib",
            "/opt/homebrew/lib/libMoltenVK.dylib",
        ]
        if let lib = loaders.first(where: { fm.fileExists(atPath: $0) }) {
            if dlopen(lib, RTLD_NOW | RTLD_GLOBAL) != nil { lkLog("preloaded \(lib)") }
        }
    }
}
#endif
