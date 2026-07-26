/* liblookout_jni.so is assembled from the prebuilt Zig archives (the JNI
 * natives live inside liblookout_marine.a, kept via --whole-archive); CMake
 * just needs one translation unit to own the target.
 *
 * It also pipes stdout/stderr to logcat: the core reports through
 * std.debug.print, and Android drops stderr on the floor. */
#include <jni.h>
#include <pthread.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <android/log.h>

#define TAG "lookout"

static int log_pipe[2];

/* Whole lines only; a partial write waits for its newline. */
static void *log_pump(void *arg) {
    (void)arg;
    char buf[2048];
    size_t used = 0;
    for (;;) {
        ssize_t n = read(log_pipe[0], buf + used, sizeof(buf) - used - 1);
        if (n <= 0) {
            if (n < 0 && errno == EINTR) continue;
            break; /* writer end closed: nothing more can arrive */
        }
        used += (size_t)n;
        buf[used] = '\0';
        char *line = buf;
        char *nl;
        while ((nl = strchr(line, '\n')) != NULL) {
            *nl = '\0';
            if (*line) __android_log_write(ANDROID_LOG_INFO, TAG, line);
            line = nl + 1;
        }
        used = strlen(line);
        memmove(buf, line, used); /* keep the partial tail */
        if (used == sizeof(buf) - 1) { /* pathological line: flush it */
            buf[used] = '\0';
            __android_log_write(ANDROID_LOG_INFO, TAG, buf);
            used = 0;
        }
    }
    return NULL;
}

/* Unbuffered, or output sits in libc until a flush. */
static void redirect_stdio_to_logcat(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    if (pipe(log_pipe) != 0) return;
    dup2(log_pipe[1], STDOUT_FILENO);
    dup2(log_pipe[1], STDERR_FILENO);
    pthread_t t;
    if (pthread_create(&t, NULL, log_pump, NULL) == 0) {
        pthread_detach(t);
    }
}

JNIEXPORT jint JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void)vm;
    (void)reserved;
    redirect_stdio_to_logcat();
    __android_log_write(ANDROID_LOG_INFO, TAG, "engine stdio -> logcat");
    return JNI_VERSION_1_6;
}
