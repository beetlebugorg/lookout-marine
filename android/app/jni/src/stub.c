/* liblookout_jni.so is assembled from the prebuilt Zig archives (the JNI
 * natives live inside liblookout_marine.a, kept via --whole-archive); CMake
 * just needs one translation unit to own the target. */
#include <jni.h>

JNIEXPORT jint JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void)vm;
    (void)reserved;
    return JNI_VERSION_1_6;
}
