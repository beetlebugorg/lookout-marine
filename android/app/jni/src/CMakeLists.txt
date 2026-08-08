cmake_minimum_required(VERSION 3.6)

project(lookout_jni)

# The Zig core, prebuilt per ABI (see build-libs.sh / gradle's buildZigCore).
# The two archives stay separate on android (liblookout_marine.a doesn't embed
# tile57 — a nested .a member breaks ld.lld).
set(PREBUILT ${CMAKE_CURRENT_SOURCE_DIR}/../prebuilt/${ANDROID_ABI})

# Lookout.java loads "lookout_jni". The JNI natives (Java_org_beetlebug_*)
# live inside liblookout_marine.a and are referenced only at runtime by the
# JVM's lookup, so the linker must keep the whole archive; libtile57 resolves
# normally against lookout's undefined engine symbols after it.
add_library(lookout_jni SHARED stub.c)
target_link_libraries(lookout_jni PRIVATE
    -Wl,--whole-archive
    ${PREBUILT}/liblookout_marine.a
    -Wl,--no-whole-archive
    ${PREBUILT}/libtile57.a
    vulkan     # gpu_vk.zig: instance/device/swapchain via the platform loader
    log        # __android_log_*
    android    # ANativeWindow_*
    m)

# The wasm plugin host (src/plugin/), when build-libs.sh built the core with
# -Dplugins=true: the static core embeds no archive off Apple, so the WAMR
# runtime is linked here. Present only for an ABI that has a
# vendor/wamr-dist-android-* archive, so this is conditional rather than a hard
# dependency — a core built without the host has no undefined wasm_* symbols.
# Interpreter only (no JIT): no executable pages, and WAMR's hardware bound
# check is off, so the JVM keeps SIGSEGV.
if(EXISTS ${PREBUILT}/libvmlib.a)
    target_link_libraries(lookout_jni PRIVATE ${PREBUILT}/libvmlib.a)
    message(STATUS "lookout: linking the wasm plugin host (${ANDROID_ABI}/libvmlib.a)")
else()
    message(STATUS "lookout: no libvmlib.a for ${ANDROID_ABI} — building without the plugin host")
endif()
