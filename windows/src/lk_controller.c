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
    unsigned long long last_view_saved_ms;
};

/* The render thread parks between frames (lk_controller_wait); any mutation
 * kicks it, so the frame that shows the change starts now instead of at the
 * end of an idle sleep. One event for the process: the app runs one
 * controller, and a spurious kick costs one needs_tick check. */
static HANDLE render_wake;

void
lk_controller_kick(void)
{
    if (render_wake != NULL)
        SetEvent(render_wake);
}

void
lk_controller_wait(int ms)
{
    if (render_wake == NULL)
        render_wake = CreateEventW(NULL, FALSE, FALSE, NULL);
    if (render_wake == NULL) {
        Sleep(ms > 8 ? 8 : (DWORD)ms);
        return;
    }
    WaitForSingleObject(render_wake, (DWORD)ms);
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

char *
lk_controller_plugins_json(lk_controller *self)
{
    if (!lk_controller_is_open(self))
        return NULL;

    size_t len = 0;
    const char *json = lookout_plugins_json(self->handle, &len);
    if (json == NULL || len == 0)
        return NULL;

    /* Borrowed until the next plugin query, so it is copied out here. */
    char *copy = (char *)malloc(len + 1);
    if (copy == NULL)
        return NULL;
    memcpy(copy, json, len);
    copy[len] = '\0';
    return copy;
}

int
lk_controller_set_plugin_config(lk_controller *self, const char *id, const char *json)
{
    lk_controller_kick();
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
 * wrapper copies out before it returns. */
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

char *
lk_controller_alerts_json(lk_controller *self)
{
    if (!lk_controller_is_open(self))
        return NULL;
    size_t len = 0;
    const char *json = lookout_plugin_alerts_json(self->handle, &len);
    if (json == NULL || len == 0)
        return NULL;
    return copy_out(json, len);
}

int
lk_controller_alert_ack(lk_controller *self, unsigned long long id)
{
    lk_controller_kick();
    if (!lk_controller_is_open(self))
        return 0;
    return lookout_plugin_alert_ack(self->handle, (uint64_t)id) == 0;
}

char *
lk_controller_tables_json(lk_controller *self)
{
    if (!lk_controller_is_open(self))
        return NULL;
    size_t len = 0;
    const char *json = lookout_plugin_tables_json(self->handle, &len);
    if (json == NULL || len == 0)
        return NULL;
    return copy_out(json, len);
}

char *
lk_controller_table_rows(lk_controller *self, const char *plugin, const char *key,
                         const char *sort_key, int ascending)
{
    if (!lk_controller_is_open(self) || plugin == NULL || key == NULL)
        return NULL;
    size_t len = 0;
    const char *json = lookout_plugin_table_rows(self->handle, plugin, key,
                                                 sort_key, ascending, &len);
    if (json == NULL || len == 0)
        return NULL;
    return copy_out(json, len);
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
    lk_controller_kick();
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
    lk_controller_kick();
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
    lk_controller_kick();
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
    lk_controller_kick();
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
    lk_controller_kick();
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
    lk_controller_kick();
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

    /* Reopen where we left off; a first run (no saved pose) takes the core's
     * default view, not fit_chart: fitting a big library lands on an
     * arbitrary harbor cell, and the default keeps that centre but pulls back
     * to an overview (the one piece of this policy the core keeps in one
     * place — see lookout.h). */
    lookout_view v;
    if (!lk_store_load_view(&v))
        lookout_default_view(h, &v);
    lookout_set_view(h, &v);
    apply_env_view(h);

    /* device_scale (physical symbol/text size) is the host's to state. */
    tile57_mariner m;
    lookout_get_mariner(h, &m);
    m.device_scale = density;
    /* Saved settings overlay the defaults, so the chart reopens as left. */
    lk_store_apply_saved_mariner(&m);
    lookout_set_mariner(h, &m);

    /* The plugins belong to the handle this open just made, so they are loaded
     * per open, and the settings an earlier session saved are replayed into
     * them. A saved key the schema no longer declares is ignored by the core. */
    load_plugins(h);
    lk_store_apply_saved_plugins(h);

    self->last_view_saved_ms = GetTickCount64();
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
    lk_controller_kick();
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

    /* Persist the pose to reopen on, before the handle dies. */
    lookout_view v;
    lookout_get_view(self->handle, &v);
    lk_store_save_view(&v);

    lookout_close(self->handle);
    self->handle = NULL;
}

/* ---- render loop -------------------------------------------------------- */

int
lk_controller_needs_tick(lk_controller *self)
{
    if (!lk_controller_is_open(self))
        return 0;
    return lookout_animating(self->handle) || lookout_needs_redraw(self->handle) ||
           lookout_is_building(self->handle);
}

int
lk_controller_tick(lk_controller *self, double dt)
{
    if (!lk_controller_is_open(self))
        return 0;

    if (dt > 0.05)
        dt = 0.05; /* cap after an idle gap so a resumed fling doesn't teleport */

    int animating = lookout_animating(self->handle);
    if (animating)
        lookout_tick_anim(self->handle, dt);

    int drew = 0;
    if (animating || lookout_needs_redraw(self->handle)) {
        drew = lookout_render(self->handle);

        /* Persist periodically: a crash never reaches close(). */
        unsigned long long now = GetTickCount64();
        if (now - self->last_view_saved_ms >= 3000) {
            self->last_view_saved_ms = now;
            lookout_view v;
            lookout_get_view(self->handle, &v);
            lk_store_save_view(&v);
        }
    }
    return drew;
}

void
lk_controller_resize(lk_controller *self, unsigned width_pt, unsigned height_pt)
{
    lk_controller_kick();
    if (!lk_controller_is_open(self) || width_pt == 0 || height_pt == 0)
        return;
    self->width = width_pt;
    self->height = height_pt;
    lookout_resize(self->handle, width_pt, height_pt);
}

void
lk_controller_set_density(lk_controller *self, float density)
{
    lk_controller_kick();
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
    lk_controller_kick();
    if (lk_controller_is_open(self))
        lookout_pan_logical(self->handle, (float)dx, (float)dy);
}

void
lk_controller_zoom_at(lk_controller *self, double dzoom, double x, double y)
{
    lk_controller_kick();
    if (lk_controller_is_open(self))
        lookout_zoom_at_logical(self->handle, dzoom, (float)x, (float)y);
}

void
lk_controller_zoom_centered(lk_controller *self, double dzoom, unsigned w_px, unsigned h_px)
{
    lk_controller_kick();
    if (lk_controller_is_open(self))
        lookout_zoom_at_logical(self->handle, dzoom, (float)w_px / 2.0f, (float)h_px / 2.0f);
}

void
lk_controller_rotate_drag(lk_controller *self, double x0, double y0, double x1, double y1)
{
    lk_controller_kick();
    if (lk_controller_is_open(self))
        lookout_rotate_drag_logical(self->handle, (float)x0, (float)y0, (float)x1, (float)y1);
}

void
lk_controller_reset_rotation(lk_controller *self)
{
    lk_controller_kick();
    if (lk_controller_is_open(self))
        lookout_reset_rotation(self->handle);
}

void
lk_controller_fling_start(lk_controller *self, double vx, double vy)
{
    lk_controller_kick();
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
    lk_controller_kick();
    if (!lk_controller_is_open(self))
        return;
    lookout_view v;
    lookout_fit_chart(self->handle, &v);
    lookout_set_view(self->handle, &v);
}

void
lk_controller_set_center(lk_controller *self, double lon, double lat)
{
    lk_controller_kick();
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
    if (lk_controller_is_open(self))
        lookout_get_mariner(self->handle, out);
    else
        lookout_mariner_defaults(out);
}

void
lk_controller_set_mariner(lk_controller *self, const tile57_mariner *m)
{
    lk_controller_kick();
    if (lk_controller_is_open(self) && m != NULL)
        lookout_set_mariner(self->handle, m);
}

void
lk_controller_set_scheme(lk_controller *self, int scheme)
{
    lk_controller_kick();
    if (!lk_controller_is_open(self))
        return;
    tile57_mariner m;
    lookout_get_mariner(self->handle, &m);
    m.scheme = (tile57_scheme)scheme;
    lookout_set_mariner(self->handle, &m);
    lk_store_save_mariner(&m);
}

void
lk_controller_cycle_scheme(lk_controller *self)
{
    lk_controller_kick();
    if (!lk_controller_is_open(self))
        return;
    lookout_cycle_scheme(self->handle);
    tile57_mariner m;
    lookout_get_mariner(self->handle, &m);
    lk_store_save_mariner(&m);
}

void
lk_controller_toggle_text(lk_controller *self)
{
    lk_controller_kick();
    if (lk_controller_is_open(self))
        lookout_toggle_text(self->handle);
}

void
lk_controller_toggle_soundings(lk_controller *self)
{
    lk_controller_kick();
    if (lk_controller_is_open(self))
        lookout_toggle_soundings(self->handle);
}

void
lk_controller_toggle_other_category(lk_controller *self)
{
    lk_controller_kick();
    if (lk_controller_is_open(self))
        lookout_toggle_other_category(self->handle);
}

/* ---- raster underlay ----------------------------------------------------- */

int
lk_controller_raster_add(lk_controller *self, const char *path)
{
    lk_controller_kick();
    if (!lk_controller_is_open(self) || path == NULL || path[0] == '\0')
        return 0;
    return lookout_raster_add(self->handle, path);
}

void
lk_controller_raster_cycle(lk_controller *self)
{
    lk_controller_kick();
    if (lk_controller_is_open(self))
        lookout_raster_cycle(self->handle);
}

void
lk_controller_raster_select(lk_controller *self, int index)
{
    lk_controller_kick();
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
    lk_controller_kick();
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
    lk_controller_kick();
    if (lk_controller_is_open(self))
        lookout_raster_set_shown(self->handle, i, on);
}

void
lk_controller_set_chart_hidden(lk_controller *self, int hidden)
{
    lk_controller_kick();
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

void
lk_controller_toggle_chart(lk_controller *self)
{
    lk_controller_kick();
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

typedef struct {
    lk_pick_feature *feats;
    int count, cap;
} pick_ctx;

static char *
pick_dup(const char *s, size_t len)
{
    char *out = (char *)malloc(len + 1);
    if (out == NULL)
        return NULL;
    memcpy(out, s ? s : "", s ? len : 0);
    out[s ? len : 0] = '\0';
    return out;
}

static void
pick_cb(void *ctx, const char *cls, size_t cls_len, const char *s57, size_t s57_len,
        const char *chart, size_t chart_len)
{
    pick_ctx *pc = (pick_ctx *)ctx;
    if (pc->count == pc->cap) {
        int cap = pc->cap == 0 ? 8 : pc->cap * 2;
        lk_pick_feature *grown =
            (lk_pick_feature *)realloc(pc->feats, (size_t)cap * sizeof *grown);
        if (grown == NULL)
            return;
        pc->feats = grown;
        pc->cap = cap;
    }
    lk_pick_feature *f = &pc->feats[pc->count];
    f->cls = pick_dup(cls, cls_len);
    f->json = pick_dup(s57, s57_len);
    f->chart = pick_dup(chart, chart_len);
    if (f->cls == NULL || f->json == NULL || f->chart == NULL) {
        free(f->cls);
        free(f->json);
        free(f->chart);
        return;
    }
    pc->count++;
}

int
lk_controller_pick_at(lk_controller *self, double x, double y, lk_pick_feature **out)
{
    if (out == NULL)
        return 0;
    *out = NULL;
    if (!lk_controller_is_open(self))
        return 0;

    double lon, lat;
    lookout_screen_to_geo(self->handle, (float)x, (float)y, &lon, &lat);

    pick_ctx pc = { NULL, 0, 0 };
    tile57_query_cb cb;
    cb.ctx = &pc;
    cb.feature = pick_cb;
    lookout_pick_ranked(self->handle, lon, lat, &cb);
    if (pc.count == 0) {
        free(pc.feats);
        return 0;
    }
    *out = pc.feats;
    return pc.count;
}

void
lk_controller_pick_free(lk_pick_feature *feats, int n)
{
    if (feats == NULL)
        return;
    for (int i = 0; i < n; ++i) {
        free(feats[i].cls);
        free(feats[i].json);
        free(feats[i].chart);
    }
    free(feats);
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
