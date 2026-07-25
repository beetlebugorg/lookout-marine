// lookout marine — Android app shell.
//
// SDLActivity loads libmain.so and calls SDL_main (this main()). We drive the
// lookout C ABI (include/lookout.h): open a chart with want_window=1 so the
// SDL_GPU backend creates the SDL window bound to the Activity's SurfaceView and
// a Vulkan device, fit the view, then loop — one finger pans, two fingers pinch
// to zoom (mouse wheel zooms too, for the emulator), and each tick renders when
// something changed. The chart ships in the APK assets and is copied to internal
// storage once (tile57 opens it by path / mmap, which can't read an APK asset
// directly).
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include "lookout.h"

#define CHART_ASSET "charts/US5MD1MC.pmtiles"
#define CHART_NAME  "US5MD1MC.pmtiles"

static char *extract_asset(const char *asset, const char *out_name) {
    size_t n = 0;
    void *data = SDL_LoadFile(asset, &n); // APK asset -> memory
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

// Minimal multi-touch tracker for pinch-zoom. Positions are normalized [0,1] of
// the window; we scale to pixels with the current drawable size.
#define MAX_FINGERS 8
static struct {
    SDL_FingerID id;
    float x, y;
} g_fingers[MAX_FINGERS];
static int g_nfingers = 0;
static float g_pinch_dist = 0.0f; // last two-finger distance in px (0 = none yet)
static Uint64 g_last_tap_ms = 0;  // double-tap detection
static float g_last_tap_x = 0, g_last_tap_y = 0;

static void finger_down(SDL_FingerID id, float x, float y) {
    if (g_nfingers < MAX_FINGERS) {
        g_fingers[g_nfingers].id = id;
        g_fingers[g_nfingers].x = x;
        g_fingers[g_nfingers].y = y;
        g_nfingers++;
    }
    g_pinch_dist = 0.0f; // finger count changed — restart pinch tracking
}
static void finger_up(SDL_FingerID id) {
    for (int i = 0; i < g_nfingers; i++) {
        if (g_fingers[i].id == id) {
            g_fingers[i] = g_fingers[--g_nfingers];
            break;
        }
    }
    g_pinch_dist = 0.0f;
}

int main(int argc, char *argv[]) {
    (void)argc;
    (void)argv;

    char *chart = extract_asset(CHART_ASSET, CHART_NAME);
    if (!chart) return 1;

    lookout *l = lookout_open(chart, 1080, 2160, /*want_window*/ 1, /*want_msaa*/ 1);
    SDL_free(chart);
    if (!l) {
        SDL_Log("lookout_open failed");
        return 1;
    }

    lookout_view v;
    lookout_fit_chart(l, &v);
    lookout_set_view(l, &v);

    float win_w = 1080.0f, win_h = 2160.0f; // pixels; updated from window events
    bool running = true;
    Uint64 last = SDL_GetTicks();

    while (running) {
        bool dirty = false; // an interaction this tick -> force a render
        SDL_Event e;
        // Block up to a frame for input, then drain the queue — event-driven so
        // an idle chart isn't burning the CPU/GPU.
        if (SDL_WaitEventTimeout(&e, 16)) {
            do {
                switch (e.type) {
                    case SDL_EVENT_QUIT:
                    case SDL_EVENT_TERMINATING:
                        running = false;
                        break;
                    case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
                        win_w = (float)e.window.data1;
                        win_h = (float)e.window.data2;
                        dirty = true;
                        break;
                    case SDL_EVENT_FINGER_DOWN:
                        finger_down(e.tfinger.fingerID, e.tfinger.x, e.tfinger.y);
                        SDL_Log("finger down: n=%d", g_nfingers);
                        if (g_nfingers == 1) {
                            // double-tap (double-click on the emulator) -> zoom in
                            // at the point. A guaranteed touch-only zoom path.
                            const Uint64 t = SDL_GetTicks();
                            const float px = e.tfinger.x * win_w, py = e.tfinger.y * win_h;
                            if (t - g_last_tap_ms < 300 && fabsf(px - g_last_tap_x) < 60.0f && fabsf(py - g_last_tap_y) < 60.0f) {
                                lookout_zoom_at(l, 1.0, px, py);
                                SDL_Log("double-tap zoom at (%.0f,%.0f)", px, py);
                                dirty = true;
                                g_last_tap_ms = 0;
                            } else {
                                g_last_tap_ms = t;
                                g_last_tap_x = px;
                                g_last_tap_y = py;
                            }
                        }
                        break;
                    case SDL_EVENT_FINGER_UP:
                        finger_up(e.tfinger.fingerID);
                        SDL_Log("finger up: n=%d", g_nfingers);
                        break;
                    case SDL_EVENT_FINGER_MOTION:
                        for (int i = 0; i < g_nfingers; i++) {
                            if (g_fingers[i].id == e.tfinger.fingerID) {
                                g_fingers[i].x = e.tfinger.x;
                                g_fingers[i].y = e.tfinger.y;
                                break;
                            }
                        }
                        if (g_nfingers >= 2) {
                            // pinch: zoom by the change in the first two fingers'
                            // separation, anchored at their midpoint.
                            const float ax = g_fingers[0].x * win_w, ay = g_fingers[0].y * win_h;
                            const float bx = g_fingers[1].x * win_w, by = g_fingers[1].y * win_h;
                            const float dist = hypotf(ax - bx, ay - by);
                            if (g_pinch_dist > 1.0f && dist > 1.0f) {
                                const double dz = log2((double)(dist / g_pinch_dist)); // apart => zoom in
                                lookout_zoom_at(l, dz, (ax + bx) * 0.5f, (ay + by) * 0.5f);
                                SDL_Log("pinch: dz=%.3f dist=%.1f mid=(%.0f,%.0f)", dz, dist, (ax + bx) * 0.5f, (ay + by) * 0.5f);
                                dirty = true;
                            }
                            g_pinch_dist = dist;
                        } else {
                            // one finger: pan (drag the chart with the finger).
                            lookout_pan(l, e.tfinger.dx * win_w, e.tfinger.dy * win_h);
                            dirty = true;
                        }
                        break;
                    case SDL_EVENT_MOUSE_WHEEL:
                        lookout_zoom_at(l, (double)e.wheel.y * 0.3, win_w * 0.5f, win_h * 0.5f);
                        SDL_Log("wheel: y=%.2f", e.wheel.y);
                        dirty = true;
                        break;
                    case SDL_EVENT_KEY_DOWN: {
                        // Keyboard zoom — always available on the emulator's HW
                        // keyboard, so it isolates zoom from touch/wheel input.
                        // '+'/'=' in, '-' out.
                        const SDL_Keycode k = e.key.key;
                        double dz = 0;
                        if (k == SDLK_EQUALS || k == SDLK_PLUS || k == SDLK_KP_PLUS) dz = 0.5;
                        else if (k == SDLK_MINUS || k == SDLK_KP_MINUS) dz = -0.5;
                        if (dz != 0) {
                            lookout_zoom_at(l, dz, win_w * 0.5f, win_h * 0.5f);
                            SDL_Log("key zoom: dz=%.2f (win %.0fx%.0f)", dz, win_w, win_h);
                            dirty = true;
                        }
                        break;
                    }
                    default:
                        break;
                }
            } while (running && SDL_PollEvent(&e));
        }

        const Uint64 now = SDL_GetTicks();
        const double dt = (double)(now - last) / 1000.0;
        last = now;
        if (lookout_animating(l)) lookout_tick_anim(l, dt);
        if (dirty || lookout_needs_redraw(l) || lookout_animating(l)) lookout_render(l);
    }

    lookout_close(l);
    return 0;
}
