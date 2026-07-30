#include "lk_controller.h"
#include "lk_store.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdlib.h>
#include <string.h>

struct lk_controller {
    lookout *handle;          /* NULL until a chart is open */
    unsigned width, height;   /* device pixels */
    unsigned long long last_view_saved_ms;
};

lk_controller *
lk_controller_new(void)
{
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

/* ---- lifecycle ---------------------------------------------------------- */

int
lk_controller_open(lk_controller *self, void *hinstance, void *hwnd,
                   const char *const *paths, int n,
                   unsigned width_px, unsigned height_px, float density)
{
    if (self == NULL || paths == NULL || n <= 0 || hwnd == NULL)
        return 0;

    lk_controller_close(self);

    lookout_win32_window native;
    native.hinstance = hinstance;
    native.hwnd = hwnd;

    lookout *h = (n == 1)
        ? lookout_open_in_window(LOOKOUT_NATIVE_WIN32_HWND, &native, paths[0],
                                 width_px, height_px, 1)
        : lookout_open_charts_in_window(LOOKOUT_NATIVE_WIN32_HWND, &native, paths, (size_t)n,
                                        width_px, height_px, 1);
    if (h == NULL)
        return 0;

    self->handle = h;
    self->width = width_px;
    self->height = height_px;

    lookout_set_pixel_density(h, density);
    lookout_resize(h, width_px, height_px);

    /* Reopen where we left off; a first run (no saved pose) frames the opened
     * chart, so the user sees their cells and not a world-zoom speck. */
    lookout_view v;
    if (!lk_store_load_view(&v))
        lookout_fit_chart(h, &v);
    lookout_set_view(h, &v);

    /* device_scale (physical symbol/text size) is the host's to state. */
    tile57_mariner m;
    lookout_get_mariner(h, &m);
    m.device_scale = density;
    /* Saved settings overlay the defaults, so the chart reopens as left. */
    lk_store_apply_saved_mariner(&m);
    lookout_set_mariner(h, &m);

    self->last_view_saved_ms = GetTickCount64();
    return 1;
}

int
lk_controller_open_dxgi(lk_controller *self, const lookout_dxgi_target *target,
                        const char *const *paths, int n,
                        unsigned width_pt, unsigned height_pt, float density)
{
    if (self == NULL || target == NULL || paths == NULL || n <= 0)
        return 0;

    lk_controller_close(self);

    lookout *h = (n == 1)
        ? lookout_open_in_window(LOOKOUT_NATIVE_DXGI_TARGET, (void *)target, paths[0],
                                 width_pt, height_pt, 1)
        : lookout_open_charts_in_window(LOOKOUT_NATIVE_DXGI_TARGET, (void *)target, paths, (size_t)n,
                                        width_pt, height_pt, 1);
    if (h == NULL)
        return 0;

    self->handle = h;
    self->width = width_pt;
    self->height = height_pt;

    lookout_set_pixel_density(h, density);
    lookout_resize(h, width_pt, height_pt);

    lookout_view v;
    if (!lk_store_load_view(&v))
        lookout_fit_chart(h, &v);
    lookout_set_view(h, &v);

    tile57_mariner m;
    lookout_get_mariner(h, &m);
    m.device_scale = density;
    lk_store_apply_saved_mariner(&m);
    lookout_set_mariner(h, &m);

    self->last_view_saved_ms = GetTickCount64();
    return 1;
}

void
lk_controller_tick_anim(lk_controller *self, double dt)
{
    if (!lk_controller_is_open(self))
        return;
    if (dt > 0.05)
        dt = 0.05;
    if (lookout_animating(self->handle))
        lookout_tick_anim(self->handle, dt);

    unsigned long long now = GetTickCount64();
    if (now - self->last_view_saved_ms >= 3000) {
        self->last_view_saved_ms = now;
        lookout_view v;
        lookout_get_view(self->handle, &v);
        lk_store_save_view(&v);
    }
}

void
lk_controller_invalidate(lk_controller *self)
{
    if (!lk_controller_is_open(self))
        return;
    lookout_view v;
    lookout_get_view(self->handle, &v);
    lookout_set_view(self->handle, &v); /* marks the view dirty */
}

int
lk_controller_needs_frame(lk_controller *self)
{
    if (!lk_controller_is_open(self))
        return 0;
    return lookout_animating(self->handle) || lookout_needs_redraw(self->handle);
}

int
lk_controller_render_dxgi(lk_controller *self, unsigned index,
                          unsigned long long wait_value, unsigned long long signal_value)
{
    if (!lk_controller_is_open(self))
        return 0;
    return lookout_render_dxgi(self->handle, index, wait_value, signal_value);
}

int
lk_controller_retarget_dxgi(lk_controller *self, const lookout_dxgi_target *target)
{
    if (!lk_controller_is_open(self) || target == NULL)
        return 0;
    return lookout_retarget_dxgi(self->handle, target);
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
lk_controller_resize(lk_controller *self, unsigned width_px, unsigned height_px)
{
    if (!lk_controller_is_open(self) || width_px == 0 || height_px == 0)
        return;
    self->width = width_px;
    self->height = height_px;
    lookout_resize(self->handle, width_px, height_px);
}

void
lk_controller_set_density(lk_controller *self, float density)
{
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
    if (lk_controller_is_open(self))
        lookout_pan_logical(self->handle, (float)dx, (float)dy);
}

void
lk_controller_zoom_at(lk_controller *self, double dzoom, double x, double y)
{
    if (lk_controller_is_open(self))
        lookout_zoom_at_logical(self->handle, dzoom, (float)x, (float)y);
}

void
lk_controller_zoom_centered(lk_controller *self, double dzoom, unsigned w_px, unsigned h_px)
{
    if (lk_controller_is_open(self))
        lookout_zoom_at_logical(self->handle, dzoom, (float)w_px / 2.0f, (float)h_px / 2.0f);
}

void
lk_controller_rotate_drag(lk_controller *self, double x0, double y0, double x1, double y1)
{
    if (lk_controller_is_open(self))
        lookout_rotate_drag_logical(self->handle, (float)x0, (float)y0, (float)x1, (float)y1);
}

void
lk_controller_reset_rotation(lk_controller *self)
{
    if (lk_controller_is_open(self))
        lookout_reset_rotation(self->handle);
}

void
lk_controller_fling_start(lk_controller *self, double vx, double vy)
{
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

/* ---- view --------------------------------------------------------------- */

void
lk_controller_fit_chart(lk_controller *self)
{
    if (!lk_controller_is_open(self))
        return;
    lookout_view v;
    lookout_fit_chart(self->handle, &v);
    lookout_set_view(self->handle, &v);
}

void
lk_controller_set_center(lk_controller *self, double lon, double lat)
{
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
    if (lk_controller_is_open(self) && m != NULL)
        lookout_set_mariner(self->handle, m);
}

void
lk_controller_set_scheme(lk_controller *self, int scheme)
{
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
    if (lk_controller_is_open(self))
        lookout_toggle_text(self->handle);
}

void
lk_controller_toggle_soundings(lk_controller *self)
{
    if (lk_controller_is_open(self))
        lookout_toggle_soundings(self->handle);
}

void
lk_controller_toggle_other_category(lk_controller *self)
{
    if (lk_controller_is_open(self))
        lookout_toggle_other_category(self->handle);
}

/* ---- pick --------------------------------------------------------------- */

typedef struct {
    lk_pick_feature *out;
    int max;
    int count;
} pick_ctx;

static void
pick_cb(void *ctx, const char *cls, size_t cls_len, const char *s57, size_t s57_len,
        const char *chart, size_t chart_len)
{
    pick_ctx *pc = (pick_ctx *)ctx;
    if (pc->count >= pc->max)
        return;
    lk_pick_feature *f = &pc->out[pc->count++];

    size_t n;
    n = cls_len < sizeof f->cls - 1 ? cls_len : sizeof f->cls - 1;
    memcpy(f->cls, cls ? cls : "", n);
    f->cls[n] = '\0';
    n = s57_len < sizeof f->s57 - 1 ? s57_len : sizeof f->s57 - 1;
    memcpy(f->s57, s57 ? s57 : "", n);
    f->s57[n] = '\0';
    n = chart_len < sizeof f->chart - 1 ? chart_len : sizeof f->chart - 1;
    memcpy(f->chart, chart ? chart : "", n);
    f->chart[n] = '\0';
}

int
lk_controller_pick_at(lk_controller *self, double x, double y, lk_pick_feature *out, int max)
{
    if (!lk_controller_is_open(self) || out == NULL || max <= 0)
        return 0;

    double lon, lat;
    lookout_screen_to_geo(self->handle, (float)x, (float)y, &lon, &lat);

    pick_ctx pc = { out, max, 0 };
    tile57_query_cb cb;
    cb.ctx = &pc;
    cb.feature = pick_cb;
    lookout_pick(self->handle, lon, lat, &cb);
    return pc.count;
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
}
