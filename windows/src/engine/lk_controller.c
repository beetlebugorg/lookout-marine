#include "lk_controller.h"
#include "lk_store.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct lk_controller {
    lookout *handle;          /* NULL until a chart is open */
    unsigned width, height;   /* logical points */
};

/* The render thread parks between frames (lk_controller_wait); any mutation
 * kicks it, so the frame that shows the change starts now instead of at the
 * end of an idle sleep. One event for the process: the app runs one
 * controller, and a spurious kick costs one needs_tick check.
 *
 * MADE ONCE, BEFORE EITHER THREAD LOOKS AT IT. The wait runs on the render
 * thread and the kick on the UI thread, so creating it lazily inside the wait
 * was one thread writing the handle while the other read it — and every kick
 * before the render thread's first park was dropped on the floor. InitOnce
 * makes the creation happen exactly once, whichever thread arrives first. */
static INIT_ONCE render_wake_once = INIT_ONCE_STATIC_INIT;
static HANDLE render_wake;

static BOOL CALLBACK
make_render_wake(PINIT_ONCE once, PVOID param, PVOID *context)
{
    (void)once;
    (void)param;
    (void)context;
    render_wake = CreateEventW(NULL, FALSE, FALSE, NULL);
    return TRUE;
}

static HANDLE
wake_event(void)
{
    InitOnceExecuteOnce(&render_wake_once, make_render_wake, NULL, NULL);
    return render_wake;
}

void
lk_controller_kick(void)
{
    HANDLE h = wake_event();
    if (h != NULL)
        SetEvent(h);
}

void
lk_controller_wait(int ms)
{
    HANDLE h = wake_event();
    if (h == NULL) {
        /* No event to park on: sleep short, so a kick that cannot be
         * delivered costs a few milliseconds rather than the whole timeout,
         * and an idle park does not stop the thread for good. */
        Sleep(ms > 8 || ms == LK_WAIT_IDLE ? 8 : (DWORD)ms);
        return;
    }
    WaitForSingleObject(h, ms == LK_WAIT_IDLE ? INFINITE : (DWORD)ms);
}

/* Every mutating call kicks: the render thread's park ends now, so the frame
 * that shows the change starts at once, and the engine's frame loop counts
 * from a change this shell made rather than from where it had stopped. */
static void
kick(lk_controller *self)
{
    if (self != NULL && self->handle != NULL)
        lookout_frame_kick(self->handle);
    lk_controller_kick();
}

/* $LOOKOUT_VIEW="lon,lat,zoom[,rot]" pins the opening camera (screenshots). */
static void
apply_env_view(lookout *h)
{
    char spec[128];
    DWORD n = GetEnvironmentVariableA("LOOKOUT_VIEW", spec, sizeof spec);
    if (n == 0 || n >= sizeof spec)
        return;
    lookout_view v = { 0, 0, 0, 0 };
    int got = sscanf_s(spec, "%lf,%lf,%lf,%lf", &v.lon, &v.lat, &v.zoom, &v.rotation_deg);
    if (got >= 3)
        lookout_set_view(h, &v);
}

lk_controller *
lk_controller_new(void)
{
    /* The core's cache-dir fallbacks are XDG_CACHE_HOME then HOME — neither
     * exists on Windows, so without this the atlas cache has nowhere to live
     * and every launch pays the one-time bake again (the Android shell makes
     * the same call with its Context cache dir). */
    char local[MAX_PATH];
    DWORD n = GetEnvironmentVariableA("LOCALAPPDATA", local, sizeof local);
    if (n > 0 && n < sizeof local)
        lookout_set_cache_dir(local);

    lk_controller *self = (lk_controller *)calloc(1, sizeof *self);
    return self;
}

void
lk_controller_free(lk_controller *self)
{
    if (self == NULL)
        return;
    lk_controller_close(self);
    free(self);
}

int
lk_controller_is_open(lk_controller *self)
{
    return self != NULL && self->handle != NULL;
}

int
lk_controller_atlas_ready(void)
{
    return lookout_atlas_cache_ready();
}

/* ---- wasm plugins -------------------------------------------------------- */

/* The plugin set that travels with the app: the "plugins" folder beside the
 * exe, which the vcxproj's LkCopyBundledPlugins target fills out of
 * zig-out\plugins-bundled. Anything that is not the directory LOOKOUT_PLUGINS
 * names loads with origin "bundled", which is what this is.
 *
 * 0 when the app carries no such folder, which is a build without the copy
 * target rather than a mariner's problem. */
static int
load_bundled_plugins(lookout *h)
{
    char exe[MAX_PATH];
    DWORD n = GetModuleFileNameA(NULL, exe, sizeof exe);
    if (n == 0 || n >= sizeof exe)
        return 0;

    char *slash = strrchr(exe, '\\');
    if (slash == NULL)
        return 0;
    *slash = '\0';

    char dir[MAX_PATH];
    if (_snprintf_s(dir, sizeof dir, _TRUNCATE, "%s\\plugins", exe) < 0)
        return 0;

    DWORD attrs = GetFileAttributesA(dir);
    if (attrs == INVALID_FILE_ATTRIBUTES || !(attrs & FILE_ATTRIBUTE_DIRECTORY))
        return 0;

    return lookout_plugins_load(h, dir) == 0;
}

/* Bundled first, then installed. The order is the precedence the core
 * documents: LOOKOUT_PLUGINS (which loads at open, before this runs), then
 * bundled, then installed — on an id collision the first copy loaded wins. */
static void
load_plugins(lookout *h)
{
    if (!load_bundled_plugins(h))
        OutputDebugStringA("lookout: no bundled plugins beside the exe\n");

    lookout_plugins_load_installed(h);

    if (!lookout_plugins_active(h))
        OutputDebugStringA("lookout: no plugin layer; this chart has no own ship, "
                           "no AIS and no instrument input\n");
}

int
lk_controller_plugins_active(lk_controller *self)
{
    if (!lk_controller_is_open(self))
        return 0;
    return lookout_plugins_active(self->handle) != 0;
}

lookout_plugins *
lk_controller_plugins_read(lk_controller *self)
{
    if (!lk_controller_is_open(self))
        return NULL;
    return lookout_plugins_read(self->handle);
}

int
lk_controller_set_plugin_config(lk_controller *self, const char *id, const char *json)
{
    kick(self);
    if (!lk_controller_is_open(self) || id == NULL || json == NULL)
        return 0;
    if (lookout_plugin_config_set(self->handle, id, json) != 0)
        return 0;
    /* The plugin redraws inside the call, so the view is marked for the next tick. */
    lk_controller_invalidate(self);
    return 1;
}

/* Every const char* a plugin query returns is borrowed into ONE shared scratch
 * buffer, invalidated by the next query — whichever query that is. So every
 * wrapper that still hands back a string copies out before it returns. A read
 * owns its own arena and needs none of this. */
static char *
copy_out(const char *s, size_t len)
{
    if (s == NULL)
        return NULL;
    char *copy = (char *)malloc(len + 1);
    if (copy == NULL)
        return NULL;
    memcpy(copy, s, len);
    copy[len] = '\0';
    return copy;
}

lookout_alerts *
lk_controller_alerts_read(lk_controller *self)
{
    if (!lk_controller_is_open(self))
        return NULL;
    return lookout_alerts_read(self->handle);
}

int
lk_controller_alert_ack(lk_controller *self, unsigned long long id)
{
    kick(self);
    if (!lk_controller_is_open(self))
        return 0;
    return lookout_plugin_alert_ack(self->handle, (uint64_t)id) == 0;
}

lookout_tables *
lk_controller_tables_read(lk_controller *self)
{
    if (!lk_controller_is_open(self))
        return NULL;
    return lookout_tables_read(self->handle);
}

lookout_table_rows *
lk_controller_table_rows_read(lk_controller *self, const char *plugin, const char *key,
                              const char *sort_key, int ascending)
{
    if (!lk_controller_is_open(self) || plugin == NULL || key == NULL)
        return NULL;
    return lookout_table_rows_read(self->handle, plugin, key, sort_key, ascending);
}

void
lk_controller_table_open(lk_controller *self, const char *plugin, const char *key, int open)
{
    if (lk_controller_is_open(self) && plugin != NULL && key != NULL)
        lookout_plugin_table_open(self->handle, plugin, key, open);
}

char *
lk_controller_plugin_inspect(lk_controller *self, const char *path)
{
    if (!lk_controller_is_open(self) || path == NULL)
        return NULL;
    size_t len = 0;
    const char *json = lookout_plugin_inspect(self->handle, path, &len);
    if (json == NULL || len == 0)
        return NULL;
    return copy_out(json, len);
}

char *
lk_controller_plugin_install(lk_controller *self, const char *path)
{
    kick(self);
    if (!lk_controller_is_open(self) || path == NULL)
        return _strdup("No chart is open.");
    const char *err = lookout_plugin_install(self->handle, path);
    if (err == NULL) {
        /* The plugin starts drawing inside the call. */
        lk_controller_invalidate(self);
        return NULL;
    }
    return _strdup(err);
}

int
lk_controller_plugin_uninstall(lk_controller *self, const char *id)
{
    kick(self);
    if (!lk_controller_is_open(self) || id == NULL)
        return 0;
    if (lookout_plugin_uninstall(self->handle, id) != 0)
        return 0;
    lk_controller_invalidate(self); /* everything it drew is gone */
    return 1;
}

int
lk_controller_plugin_grant_set(lk_controller *self, const char *id, const char *cap, int on)
{
    kick(self);
    if (!lk_controller_is_open(self) || id == NULL || cap == NULL)
        return 0;
    if (lookout_plugin_grant_set(self->handle, id, cap, on) != 0)
        return 0;
    lk_controller_invalidate(self);
    return 1;
}

int
lk_controller_open_file(lk_controller *self, const char *path)
{
    kick(self);
    if (!lk_controller_is_open(self) || path == NULL)
        return 0;
    return lookout_open_file(self->handle, path);
}

int
lk_controller_own_ship(lk_controller *self, double *lon, double *lat)
{
    if (!lk_controller_is_open(self))
        return 0;
    return lookout_own_ship(self->handle, lon, lat);
}

void
lk_controller_follow_set(lk_controller *self, int on)
{
    kick(self);
    if (lk_controller_is_open(self))
        lookout_follow_set(self->handle, on);
}

int
lk_controller_follow_active(lk_controller *self)
{
    if (!lk_controller_is_open(self))
        return 0;
    return lookout_follow_active(self->handle);
}

void
lk_controller_course_up_set(lk_controller *self, int on)
{
    kick(self);
    if (lk_controller_is_open(self))
        lookout_course_up_set(self->handle, on);
}

int
lk_controller_course_up_active(lk_controller *self)
{
    if (!lk_controller_is_open(self))
        return 0;
    return lookout_course_up_active(self->handle);
}

/* ---- overlay objects ----------------------------------------------------- */

char *
lk_controller_overlay_at(lk_controller *self, double x_pt, double y_pt)
{
    if (!lk_controller_is_open(self))
        return NULL;
    size_t len = 0;
    const char *json = lookout_overlay_at(self->handle, (float)x_pt, (float)y_pt, &len);
    if (json == NULL || len == 0)
        return NULL;
    return copy_out(json, len);
}

static int
copy_overlay_obj(const lookout_overlay_obj *in, lk_overlay_obj *out)
{
    out->id = copy_out(in->id, in->id_len);
    out->info = in->info != NULL ? copy_out(in->info, in->info_len) : NULL;
    out->lon = in->lon;
    out->lat = in->lat;
    if (out->id == NULL) {
        free(out->info);
        out->info = NULL;
        return 0;
    }
    return 1;
}

int
lk_controller_overlay_hit(lk_controller *self, double x_pt, double y_pt, lk_overlay_obj *out)
{
    if (out == NULL)
        return 0;
    memset(out, 0, sizeof *out);
    if (!lk_controller_is_open(self))
        return 0;
    lookout_overlay_obj obj;
    if (!lookout_overlay_hit(self->handle, (float)x_pt, (float)y_pt, &obj))
        return 0;
    return copy_overlay_obj(&obj, out);
}

int
lk_controller_overlay_info(lk_controller *self, const char *id, lk_overlay_obj *out)
{
    if (out == NULL)
        return 0;
    memset(out, 0, sizeof *out);
    if (!lk_controller_is_open(self) || id == NULL)
        return 0;
    lookout_overlay_obj obj;
    if (!lookout_overlay_info(self->handle, id, &obj))
        return 0;
    return copy_overlay_obj(&obj, out);
}

void
lk_controller_overlay_free(lk_overlay_obj *obj)
{
    if (obj == NULL)
        return;
    free(obj->id);
    free(obj->info);
    obj->id = NULL;
    obj->info = NULL;
}

/* ---- lifecycle ---------------------------------------------------------- */

/* The store hands over the config object each plugin was last given; pushing
 * it into a handle is this file's business, because what a lookout handle is
 * is this file's business. */
static void
push_saved_plugin_config(void *user, const char *id, const char *json)
{
    lookout_plugin_config_set((lookout *)user, id, json);
}

int
lk_controller_open(lk_controller *self, const char *const *paths, int n,
                   unsigned width_pt, unsigned height_pt, float density)
{
    if (self == NULL || paths == NULL || n <= 0)
        return 0;

    lk_controller_close(self);

    lookout *h = (n == 1)
        ? lookout_open_in_window(LOOKOUT_NATIVE_D3D12_PANEL, NULL, paths[0],
                                 width_pt, height_pt, 1)
        : lookout_open_charts_in_window(LOOKOUT_NATIVE_D3D12_PANEL, NULL, paths, (size_t)n,
                                        width_pt, height_pt, 1);
    if (h == NULL)
        return 0;

    self->handle = h;
    self->width = width_pt;
    self->height = height_pt;

    lookout_set_pixel_density(h, density);
    lookout_resize(h, width_pt, height_pt);

    /* The engine keeps the pose and the mariner's settings in the store from
     * here: it restores both now, writes the pose down as the mariner moves,
     * and writes both at close. */
    lookout_set_store(h, lk_store_handle());

    /* A first run (no saved pose) takes the core's default view, not
     * fit_chart: fitting a big library lands on an arbitrary harbor cell, and
     * the default keeps that centre but pulls back to an overview (the one
     * piece of this policy the core keeps in one place — see lookout.h). */
    if (!lk_store_has_saved_view()) {
        lookout_view v;
        lookout_default_view(h, &v);
        lookout_set_view(h, &v);
    }
    apply_env_view(h);

    /* device_scale (physical symbol/text size) is the host's to state, and is
     * the one field the store leaves alone. */
    tile57_mariner m;
    lookout_get_mariner(h, &m);
    m.device_scale = density;
    lookout_set_mariner(h, &m);

    /* The plugins belong to the handle this open just made, so they are loaded
     * per open, and the settings an earlier session saved are replayed into
     * them. A saved key the schema no longer declares is ignored by the core. */
    load_plugins(h);
    lk_store_each_plugin_config(push_saved_plugin_config, h);

    return 1;
}

void *
lk_controller_swapchain(lk_controller *self)
{
    if (!lk_controller_is_open(self))
        return NULL;
    return lookout_d3d12_swapchain(self->handle);
}

void
lk_controller_invalidate(lk_controller *self)
{
    kick(self);
    if (!lk_controller_is_open(self))
        return;
    lookout_view v;
    lookout_get_view(self->handle, &v);
    lookout_set_view(self->handle, &v); /* marks the view dirty */
}

void
lk_controller_close(lk_controller *self)
{
    if (self == NULL || self->handle == NULL)
        return;

    /* lookout_close writes the pose and the mariner's settings on the way
     * out, so the store the handle was given is what reopens it. */
    lookout_close(self->handle);
    self->handle = NULL;
}

/* ---- render loop -------------------------------------------------------- */

int
lk_controller_tick(lk_controller *self, int *wait_ms)
{
    if (wait_ms != NULL)
        *wait_ms = LK_WAIT_IDLE;
    if (!lk_controller_is_open(self))
        return 0;

    lookout_frame f;
    lookout_frame_next(self->handle, &f);

    if (wait_ms != NULL) {
        switch (f.verdict) {
        /* The present paces a drawn frame, so the loop comes straight back. A
         * wait of zero is the next display tick, which is the same thing on a
         * thread with no display link to hang off. */
        case LOOKOUT_FRAME_RENDER: *wait_ms = 0; break;
        case LOOKOUT_FRAME_WAIT:   *wait_ms = f.wait_ms; break;
        default:                   *wait_ms = LK_WAIT_IDLE; break;
        }
    }
    if (f.verdict != LOOKOUT_FRAME_RENDER)
        return 0;
    return lookout_render(self->handle);
}

void
lk_controller_resize(lk_controller *self, unsigned width_pt, unsigned height_pt)
{
    kick(self);
    if (!lk_controller_is_open(self) || width_pt == 0 || height_pt == 0)
        return;
    self->width = width_pt;
    self->height = height_pt;
    lookout_resize(self->handle, width_pt, height_pt);
}

void
lk_controller_set_density(lk_controller *self, float density)
{
    kick(self);
    if (!lk_controller_is_open(self) || density <= 0)
        return;
    lookout_set_pixel_density(self->handle, density);
    tile57_mariner m;
    lookout_get_mariner(self->handle, &m);
    m.device_scale = density;
    lookout_set_mariner(self->handle, &m);
}

/* ---- interaction -------------------------------------------------------- */

void
lk_controller_pan(lk_controller *self, double dx, double dy)
{
    kick(self);
    if (lk_controller_is_open(self))
        lookout_pan_logical(self->handle, (float)dx, (float)dy);
}

void
lk_controller_zoom_at(lk_controller *self, double dzoom, double x, double y)
{
    kick(self);
    if (lk_controller_is_open(self))
        lookout_zoom_at_logical(self->handle, dzoom, (float)x, (float)y);
}

void
lk_controller_zoom_centered(lk_controller *self, double dzoom, unsigned w_px, unsigned h_px)
{
    kick(self);
    if (lk_controller_is_open(self))
        lookout_zoom_at_logical(self->handle, dzoom, (float)w_px / 2.0f, (float)h_px / 2.0f);
}

void
lk_controller_rotate_drag(lk_controller *self, double x0, double y0, double x1, double y1)
{
    kick(self);
    if (lk_controller_is_open(self))
        lookout_rotate_drag_logical(self->handle, (float)x0, (float)y0, (float)x1, (float)y1);
}

void
lk_controller_reset_rotation(lk_controller *self)
{
    kick(self);
    if (lk_controller_is_open(self))
        lookout_reset_rotation(self->handle);
}

void
lk_controller_fling_start(lk_controller *self, double vx, double vy)
{
    kick(self);
    if (lk_controller_is_open(self))
        lookout_fling_start(self->handle, vx, vy);
}

int
lk_controller_geo_at(lk_controller *self, double x, double y, double *lon, double *lat)
{
    if (!lk_controller_is_open(self))
        return 0;
    lookout_screen_to_geo(self->handle, (float)x, (float)y, lon, lat);
    return 1;
}

int
lk_controller_screen_of(lk_controller *self, double lon, double lat, double *x, double *y)
{
    if (!lk_controller_is_open(self) || x == NULL || y == NULL)
        return 0;
    /* Camera px are logical points in this shell (lookout_resize is given
     * points; density scales only the swapchain) — same space geo_at reads. */
    float fx = 0, fy = 0;
    lookout_geo_to_screen(self->handle, lon, lat, &fx, &fy);
    *x = fx;
    *y = fy;
    return 1;
}

/* ---- view --------------------------------------------------------------- */

void
lk_controller_fit_chart(lk_controller *self)
{
    kick(self);
    if (!lk_controller_is_open(self))
        return;
    lookout_view v;
    lookout_fit_chart(self->handle, &v);
    lookout_set_view(self->handle, &v);
}

void
lk_controller_set_center(lk_controller *self, double lon, double lat)
{
    kick(self);
    if (!lk_controller_is_open(self))
        return;
    lookout_view v;
    lookout_get_view(self->handle, &v);
    v.lon = lon;
    v.lat = lat;
    if (!(v.zoom > 0))
        v.zoom = 12.0; /* a chart-less view gets a harbour-ish default */
    lookout_set_view(self->handle, &v);
}

/* ---- mariner ------------------------------------------------------------ */

void
lk_controller_get_mariner(lk_controller *self, tile57_mariner *out)
{
    if (out == NULL)
        return;
    if (lk_controller_is_open(self)) {
        lookout_get_mariner(self->handle, out);
        return;
    }
    /* The settings window opens before a chart does and after one closes, and
     * what it shows there is the mariner's own choices either way. The read
     * overlays the defaults, so a field the store never held is left alone. */
    lookout_mariner_defaults(out);
    lookout_store_read_mariner(lk_store_handle(), out);
}

void
lk_controller_set_mariner(lk_controller *self, const tile57_mariner *m)
{
    kick(self);
    if (m == NULL)
        return;
    /* With a chart open the engine writes the settings down itself. With none
     * open there is no engine to do it, and a choice made at the settings
     * window still has to be there at the next one. */
    if (lk_controller_is_open(self))
        lookout_set_mariner(self->handle, m);
    else
        lookout_store_write_mariner(lk_store_handle(), m);
}

void
lk_controller_set_scheme(lk_controller *self, int scheme)
{
    kick(self);
    if (!lk_controller_is_open(self))
        return;
    tile57_mariner m;
    lookout_get_mariner(self->handle, &m);
    m.scheme = (tile57_scheme)scheme;
    lookout_set_mariner(self->handle, &m);
}

void
lk_controller_cycle_scheme(lk_controller *self)
{
    kick(self);
    if (!lk_controller_is_open(self))
        return;
    lookout_cycle_scheme(self->handle);
}

void
lk_controller_toggle_text(lk_controller *self)
{
    kick(self);
    if (lk_controller_is_open(self))
        lookout_toggle_text(self->handle);
}

void
lk_controller_toggle_soundings(lk_controller *self)
{
    kick(self);
    if (lk_controller_is_open(self))
        lookout_toggle_soundings(self->handle);
}

void
lk_controller_toggle_other_category(lk_controller *self)
{
    kick(self);
    if (lk_controller_is_open(self))
        lookout_toggle_other_category(self->handle);
}

/* ---- raster underlay ----------------------------------------------------- */

int
lk_controller_raster_add(lk_controller *self, const char *path)
{
    kick(self);
    if (!lk_controller_is_open(self) || path == NULL || path[0] == '\0')
        return 0;
    return lookout_raster_add(self->handle, path);
}

void
lk_controller_raster_cycle(lk_controller *self)
{
    kick(self);
    if (lk_controller_is_open(self))
        lookout_raster_cycle(self->handle);
}

void
lk_controller_raster_select(lk_controller *self, int index)
{
    kick(self);
    if (lk_controller_is_open(self))
        lookout_raster_select(self->handle, index);
}

int
lk_controller_raster_set_count(lk_controller *self)
{
    if (!lk_controller_is_open(self))
        return 0;
    return (int)lookout_raster_set_count(self->handle);
}

/* Borrowed engine strings are copied out at once: the set list can change on
 * the next add, and the WinRT layer wants its own hstring anyway. */
static void
copy_name(const char *name, size_t len, char *out, size_t out_len)
{
    if (out == NULL || out_len == 0)
        return;
    if (name == NULL)
        len = 0;
    if (len >= out_len) {
        len = out_len - 1;
        /* Never cut mid-sequence: a truncated UTF-8 tail makes
         * winrt::to_hstring throw over a long non-ASCII set name. */
        while (len > 0 && ((unsigned char)name[len] & 0xC0) == 0x80)
            len--;
    }
    memcpy(out, name, len);
    out[len] = '\0';
}

int
lk_controller_raster_set_name(lk_controller *self, unsigned i, char *out, size_t out_len)
{
    if (out != NULL && out_len > 0)
        out[0] = '\0';
    if (!lk_controller_is_open(self))
        return 0;
    size_t len = 0;
    const char *name = lookout_raster_set_name(self->handle, i, &len);
    copy_name(name, len, out, out_len);
    return len > 0;
}

int
lk_controller_raster_set_in_view(lk_controller *self, unsigned i)
{
    if (!lk_controller_is_open(self))
        return 0;
    return lookout_raster_set_in_view(self->handle, i);
}

int
lk_controller_raster_active_index(lk_controller *self)
{
    if (!lk_controller_is_open(self))
        return -1;
    return (int)lookout_raster_active_index(self->handle);
}

int
lk_controller_raster_set_enabled(lk_controller *self, const char *path, int enabled)
{
    kick(self);
    if (!lk_controller_is_open(self) || path == NULL)
        return 0;
    return lookout_raster_set_enabled(self->handle, path, enabled);
}

int
lk_controller_raster_enabled(lk_controller *self, const char *path)
{
    if (!lk_controller_is_open(self) || path == NULL)
        return 0;
    return lookout_raster_enabled(self->handle, path);
}

int
lk_controller_raster_shown(lk_controller *self, unsigned i)
{
    if (!lk_controller_is_open(self))
        return 0;
    return lookout_raster_shown(self->handle, i);
}

/* By index and without reference to the camera: raster_select answers for the
 * view on screen, and the view a launch opens into is often nowhere near the
 * set being restored. Showing still turns off the sets covering the same
 * water (the engine's election). */
void
lk_controller_raster_set_shown(lk_controller *self, unsigned i, int on)
{
    kick(self);
    if (lk_controller_is_open(self))
        lookout_raster_set_shown(self->handle, i, on);
}

void
lk_controller_set_chart_hidden(lk_controller *self, int hidden)
{
    kick(self);
    if (lk_controller_is_open(self))
        lookout_set_chart_hidden(self->handle, hidden);
}

/* How many vector charts are open. Zero is a library of pictures alone. */
int
lk_controller_charts_count(lk_controller *self)
{
    if (!lk_controller_is_open(self))
        return 0;
    return (int)lookout_charts_count(self->handle);
}

/* ---- charts by link ------------------------------------------------------ */

int
lk_controller_alt_style_active(lk_controller *self)
{
    if (!lk_controller_is_open(self))
        return 0;
    return lookout_alt_chart_style_active(self->handle);
}

void
lk_controller_set_http_provider(lk_controller *self, lk_http_get get,
                                lk_http_cancel cancel, void *user)
{
    if (lk_controller_is_open(self))
        lookout_set_http_provider(self->handle, (lookout_http_get)get,
                                  (lookout_http_cancel)cancel, user);
}

void
lk_controller_http_respond(lk_controller *self, unsigned long long req_id,
                           const void *bytes, size_t len, int status)
{
    /* lookout_http_respond takes no lock of the core's and ignores an unknown
     * id, so a fetch landing late is harmless — but never after close: the
     * shell detaches the provider and joins its fetches first. */
    if (!lk_controller_is_open(self))
        return;
    lookout_http_respond(self->handle, req_id, bytes, len, status);
    /* An answer is adopted at the top of a frame, and the render loop stands
     * down when nothing is moving, so a resolve landing with no gesture behind
     * it needs someone to ask for the next frame. */
    kick(self);
}

void
lk_controller_chart_link_add(lk_controller *self, const char *link)
{
    if (!lk_controller_is_open(self) || link == NULL)
        return;
    lookout_chart_link_add(self->handle, link);
    kick(self);
}

void
lk_controller_chart_link_select(lk_controller *self, const char *url)
{
    if (!lk_controller_is_open(self))
        return;
    lookout_chart_link_select(self->handle, url);
    kick(self);
}

void
lk_controller_chart_link_remove(lk_controller *self, const char *url)
{
    if (!lk_controller_is_open(self) || url == NULL)
        return;
    lookout_chart_link_remove(self->handle, url);
    kick(self);
}

void
lk_controller_chart_link_refresh(lk_controller *self, const char *url)
{
    if (!lk_controller_is_open(self) || url == NULL)
        return;
    lookout_chart_link_refresh(self->handle, url);
    kick(self);
}

void
lk_controller_chart_links_import(lk_controller *self, const char *json)
{
    if (!lk_controller_is_open(self) || json == NULL)
        return;
    lookout_chart_links_import(self->handle, json);
}

lookout_links *
lk_controller_chart_links_changed_read(lk_controller *self)
{
    if (!lk_controller_is_open(self))
        return NULL;
    if (!lookout_chart_links_changed(self->handle))
        return NULL;
    return lookout_links_read(self->handle);
}

/* ---- markers ------------------------------------------------------------- */

static void
copy_marker(const lookout_marker *in, lk_marker *out)
{
    out->id = in->id;
    out->lon = in->lon;
    out->lat = in->lat;
    size_t len = in->name_len;
    if (len >= sizeof out->name) {
        len = sizeof out->name - 1;
        while (len > 0 && ((unsigned char)in->name[len] & 0xC0) == 0x80)
            len--;
    }
    memcpy(out->name, in->name, len);
    out->name[len] = '\0';
}

uint64_t
lk_controller_marker_add(lk_controller *self, double lon, double lat)
{
    kick(self);
    if (!lk_controller_is_open(self))
        return 0;
    return lookout_marker_add(self->handle, lon, lat);
}

int
lk_controller_marker_at(lk_controller *self, double x_pt, double y_pt, lk_marker *out)
{
    if (!lk_controller_is_open(self) || out == NULL)
        return 0;
    lookout_marker m;
    if (!lookout_marker_at(self->handle, (float)x_pt, (float)y_pt, &m))
        return 0;
    copy_marker(&m, out);
    return 1;
}

int
lk_controller_marker_rename(lk_controller *self, uint64_t id, const char *name)
{
    kick(self);
    if (!lk_controller_is_open(self) || name == NULL)
        return -1;
    return lookout_marker_rename(self->handle, id, name);
}

int
lk_controller_marker_remove(lk_controller *self, uint64_t id)
{
    kick(self);
    if (!lk_controller_is_open(self))
        return -1;
    return lookout_marker_remove(self->handle, id);
}

void
lk_controller_toggle_chart(lk_controller *self)
{
    kick(self);
    if (lk_controller_is_open(self))
        lookout_toggle_chart(self->handle);
}

int
lk_controller_chart_hidden(lk_controller *self)
{
    if (!lk_controller_is_open(self))
        return 0;
    return lookout_chart_hidden(self->handle);
}

/* ---- pick --------------------------------------------------------------- */

lookout_picks *
lk_controller_picks_read(lk_controller *self, double x, double y)
{
    if (!lk_controller_is_open(self))
        return NULL;

    double lon, lat;
    lookout_screen_to_geo(self->handle, (float)x, (float)y, &lon, &lat);
    return lookout_picks_read(self->handle, lon, lat);
}

int
lk_controller_aux_file(lk_controller *self, const char *cell, const char *name,
                       const unsigned char **bytes, size_t *len, const char **mime)
{
    if (bytes != NULL)
        *bytes = NULL;
    if (len != NULL)
        *len = 0;
    if (mime != NULL)
        *mime = NULL;
    if (!lk_controller_is_open(self) || cell == NULL || name == NULL ||
        bytes == NULL || len == NULL || mime == NULL)
        return 0;
    lookout_aux_file(self->handle, cell, name, (const uint8_t **)bytes, len, mime);
    return *bytes != NULL && *len > 0;
}

/* ---- readouts ----------------------------------------------------------- */

void
lk_controller_readout(lk_controller *self, lk_readout *out)
{
    if (out == NULL)
        return;
    memset(out, 0, sizeof *out);
    out->overscale = 1.0;
    if (!lk_controller_is_open(self))
        return;

    lookout_view v;
    lookout_get_view(self->handle, &v);
    out->lon = v.lon;
    out->lat = v.lat;
    out->zoom = v.zoom;
    out->rotation_deg = v.rotation_deg;
    out->scale_denom = lookout_scale_denominator(self->handle);
    out->overscale = lookout_overscale(self->handle);

    tile57_mariner m;
    lookout_get_mariner(self->handle, &m);
    out->scheme = (int)m.scheme;
    out->building = lookout_is_building(self->handle);

    size_t len = 0;
    const char *name = lookout_raster_active_name(self->handle, &len);
    copy_name(name, len, out->raster_active, sizeof out->raster_active);
    len = 0;
    name = lookout_raster_available_name(self->handle, &len);
    copy_name(name, len, out->raster_available, sizeof out->raster_available);
    out->raster_over = lookout_raster_over_chart(self->handle);
    out->chart_hidden = lookout_chart_hidden(self->handle);
}
