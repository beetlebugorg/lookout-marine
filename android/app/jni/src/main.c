// lookout marine — Android app shell.
//
// SDLActivity loads libmain.so and calls SDL_main (this main()). We drive the
// lookout C ABI (include/lookout.h): open a chart with want_window=1 so the
// SDL_GPU backend creates the SDL window bound to the Activity's SurfaceView and
// a Vulkan device, fit the view, then loop — touch pans/zooms, and each tick
// renders one frame. The chart ships in the APK assets and is copied to internal
// storage once (tile57 opens it by path / mmap, which can't read an APK asset
// directly).
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <stdio.h>
#include <string.h>
#include "lookout.h"

#define CHART_ASSET "charts/US5MD1MC.pmtiles"
#define CHART_NAME  "US5MD1MC.pmtiles"

// Copy an APK asset to internal storage; returns a malloc'd absolute path (free
// with SDL_free) or NULL. SDL_IOFromFile reads APK assets for a relative path.
static char *extract_asset(const char *asset, const char *out_name) {
    size_t n = 0;
    void *data = SDL_LoadFile(asset, &n); // asset -> memory
    if (!data) {
        SDL_Log("asset load failed: %s (%s)", asset, SDL_GetError());
        return NULL;
    }
    const char *base = SDL_GetAndroidInternalStoragePath();
    if (!base) {
        SDL_free(data);
        return NULL;
    }
    const size_t len = strlen(base) + 1 + strlen(out_name) + 1;
    char *path = (char *)SDL_malloc(len);
    snprintf(path, len, "%s/%s", base, out_name);
    if (!SDL_SaveFile(path, data, n)) { // memory -> internal storage
        SDL_Log("asset save failed: %s (%s)", path, SDL_GetError());
        SDL_free(path);
        SDL_free(data);
        return NULL;
    }
    SDL_free(data);
    SDL_Log("chart extracted -> %s (%zu bytes)", path, n);
    return path;
}

int main(int argc, char *argv[]) {
    (void)argc;
    (void)argv;

    char *chart = extract_asset(CHART_ASSET, CHART_NAME);
    if (!chart) return 1;

    // want_window=1: the SDL_GPU backend owns the SDL window (bound to the
    // Activity surface on Android) + a Vulkan device. Size is a hint; SDL goes
    // fullscreen on Android and lookout adopts the real drawable size.
    lookout *l = lookout_open(chart, 1080, 2160, /*want_window*/ 1, /*want_msaa*/ 1);
    SDL_free(chart);
    if (!l) {
        SDL_Log("lookout_open failed");
        return 1;
    }

    lookout_view v;
    lookout_fit_chart(l, &v); // frame the whole cell
    lookout_set_view(l, &v);

    int win_w = 1080, win_h = 2160; // updated from touch-normalized deltas
    bool running = true;
    Uint64 last = SDL_GetTicks();
    while (running) {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            switch (e.type) {
                case SDL_EVENT_QUIT:
                case SDL_EVENT_TERMINATING:
                    running = false;
                    break;
                case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
                    win_w = e.window.data1;
                    win_h = e.window.data2;
                    break;
                case SDL_EVENT_FINGER_MOTION:
                    // tfinger.dx/dy are normalized [-1,1] of the window; pan the
                    // chart the opposite way (drag the map under the finger).
                    lookout_pan(l, -e.tfinger.dx * (float)win_w, -e.tfinger.dy * (float)win_h);
                    break;
                default:
                    break;
            }
        }
        const Uint64 now = SDL_GetTicks();
        const double dt = (double)(now - last) / 1000.0;
        last = now;
        if (lookout_animating(l)) lookout_tick_anim(l, dt);
        lookout_render(l);
        SDL_Delay(8); // ~120 Hz cap; the display is the real gate
    }

    lookout_close(l);
    return 0;
}
