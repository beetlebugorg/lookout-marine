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
