/* lk_controller — the one lookout* handle and the on-demand render loop.
 *
 * Host-agnostic C (no WinUI, no GTK): the C++/WinRT shell owns the window, the
 * SwapChainPanel, the per-frame pacemaker and input; it drives this each frame
 * with lk_controller_tick() and forwards gestures to the lk_controller_* calls.
 * Mirrors linux/src/lk-chart-controller.c, minus GObject/GTK. */
#ifndef LK_CONTROLLER_H
#define LK_CONTROLLER_H

#include <lookout.h> /* lookout, lookout_view, tile57_mariner */

#ifdef __cplusplus
extern "C" {
#endif

typedef struct lk_controller lk_controller;

/* Live HUD values, polled by the host each tick (see lk_controller_readout). */
typedef struct {
    double lon, lat;       /* view centre */
    double zoom;           /* fractional web-mercator zoom */
    double rotation_deg;   /* course-up rotation (0 = north-up) */
    double scale_denom;    /* 1:N */
    double overscale;      /* >=1; indicate when > ~1.05 */
    int    scheme;         /* 0 day, 1 dusk, 2 night */
    int    building;       /* 1 while a background tessellation fills in */
    /* Raster underlay, for the pill (see lookout.h "raster underlay"): the set
     * DRAWN over this view (or ""), the set COVERING this view while switched
     * off (or ""), whether the chart is drawing reduced over a picture, and
     * whether the ENC is hidden where pictures cover. */
    char   raster_active[96];
    char   raster_available[96];
    int    raster_over;
    int    chart_hidden;
} lk_readout;

/* One identified feature from a ranked pick. Strings are malloc'd,
 * NUL-terminated, never NULL; free the whole list with
 * lk_controller_pick_free. `json` is the engine's report envelope
 * {"report":{...},"s57":<raw attributes>} (see lookout_pick_ranked). */
typedef struct {
    char *cls;   /* S-57 object-class acronym */
    char *json;  /* report envelope */
    char *chart; /* source cell name */
} lk_pick_feature;

lk_controller *lk_controller_new(void);
void           lk_controller_free(lk_controller *self);

/* 1 if the one-time symbol/font atlas bake is already cached; 0 means the
 * next open pays it (~1.3s at 1x) — show the first-run loader phase. */
int lk_controller_atlas_ready(void);

/* Open n baked cells (1 = single, >1 = composed library). The core makes its
 * own D3D12 device and composition swapchain (lk_controller_swapchain).
 * width/height are logical points; density is the DPI scale (dpi/96). 1 on ok. */
int  lk_controller_open(lk_controller *self, const char *const *paths, int n,
                        unsigned width_pt, unsigned height_pt, float density);
/* The core-owned IDXGISwapChain* for ISwapChainPanelNative::SetSwapChain. */
void *lk_controller_swapchain(lk_controller *self);
/* Mark the view dirty so the next tick renders (window newly visible, etc.). */
void lk_controller_invalidate(lk_controller *self);
void lk_controller_close(lk_controller *self);
int  lk_controller_is_open(lk_controller *self);

/* Per-frame. Advances animation, renders when needed, persists the pose every
 * few seconds. Returns 1 if a frame was drawn this tick. */
int  lk_controller_tick(lk_controller *self, double dt);
/* 1 while the host should keep ticking (animating / needs redraw / building). */
int  lk_controller_needs_tick(lk_controller *self);

/* Park the render thread until a mutation kicks it or `ms` passes. Every
 * mutating lk_controller_* call kicks, so the frame that shows a change
 * starts at once; the timeout covers what the engine does on its own. */
void lk_controller_wait(int ms);
void lk_controller_kick(void);

void lk_controller_resize(lk_controller *self, unsigned width_pt, unsigned height_pt);
void lk_controller_set_density(lk_controller *self, float density);

/* Interaction — logical points, origin top-left (see lookout.h). */
void lk_controller_pan(lk_controller *self, double dx, double dy);
void lk_controller_zoom_at(lk_controller *self, double dzoom, double x, double y);
void lk_controller_zoom_centered(lk_controller *self, double dzoom, unsigned w_px, unsigned h_px);
void lk_controller_rotate_drag(lk_controller *self, double x0, double y0, double x1, double y1);
/* Geo to logical points (the inverse of geo_at) — anchors chart-pinned chrome. */
int  lk_controller_screen_of(lk_controller *self, double lon, double lat, double *x, double *y);
void lk_controller_reset_rotation(lk_controller *self);
void lk_controller_fling_start(lk_controller *self, double vx, double vy);
int  lk_controller_geo_at(lk_controller *self, double x, double y, double *lon, double *lat);

/* View. */
void lk_controller_fit_chart(lk_controller *self);
void lk_controller_set_center(lk_controller *self, double lon, double lat); /* keep zoom/rot */

/* Mariner. */
void lk_controller_get_mariner(lk_controller *self, tile57_mariner *out);
void lk_controller_set_mariner(lk_controller *self, const tile57_mariner *m);
void lk_controller_set_scheme(lk_controller *self, int scheme); /* persists */
void lk_controller_cycle_scheme(lk_controller *self);           /* persists */
void lk_controller_toggle_text(lk_controller *self);
void lk_controller_toggle_soundings(lk_controller *self);
void lk_controller_toggle_other_category(lk_controller *self);

/* Ranked cursor pick at a screen point (lookout_pick_ranked: the features
 * worth reporting, best first, depths in the mariner's unit). Mallocs *out
 * (NULL when nothing was hit) and returns the count. */
int  lk_controller_pick_at(lk_controller *self, double x, double y,
                           lk_pick_feature **out);
void lk_controller_pick_free(lk_pick_feature *feats, int n);

/* A file a picked feature points at (TXTDSC / NTXTDS / PICREP /
 * fileReference). The bytes belong to the engine and stay valid until the
 * chart closes; *mime is static. 1 when found, 0 when the chart carries no
 * such file. */
int  lk_controller_aux_file(lk_controller *self, const char *cell, const char *name,
                            const unsigned char **bytes, size_t *len, const char **mime);

void lk_controller_readout(lk_controller *self, lk_readout *out);

/* ---- wasm plugins -------------------------------------------------------- */
/* Own ship, AIS, NMEA 0183, Signal K and laylines are all plugins, so a chart
 * with no plugin layer has no boat and no traffic on it. The set is loaded per
 * open (the plugins belong to the handle): the directory beside the exe first,
 * then the installed set under %APPDATA%. lk_controller_open does both. */

/* 1 while a plugin layer is running.
 *
 * This shell needs no idle poll of its own for them, unlike the render-on-demand
 * ones: RenderLoop already asks lookout_needs_redraw every few milliseconds on
 * its own thread, so geometry a plugin posts with no gesture behind it is picked
 * up by the next tick. */
int lk_controller_plugins_active(lk_controller *self);

/* Every loaded plugin with its settings schema and the values in force, as the
 * JSON lookout_plugins_json documents. The caller frees it with free().
 *
 * NULL IS NOT AN EMPTY REGISTRY: the core answers NULL with no chart open and
 * in a build with no plugin host, while a core holding no plugins answers
 * {"plugins":[]}. A caller with a registry already on screen keeps it. */
char *lk_controller_plugins_json(lk_controller *self);

/* Push one plugin's settings, applied live. `json` is an object of the keys its
 * schema declares. 1 when the plugin took them. */
int lk_controller_set_plugin_config(lk_controller *self, const char *id, const char *json);

/* Plugin alerts: {"seq":N,"alerts":[{id,plugin,severity,title,body,raised,
 * acknowledged}...]} as a malloc'd copy the caller frees, or NULL when
 * unreadable (no chart, no plugin layer). NULL is not "no alerts": the caller
 * clears the strip and silences the siren but keeps watching. */
char *lk_controller_alerts_json(lk_controller *self);
/* Acknowledge one alert: silences it and takes it off the strip. That alert
 * only; a second alarm keeps sounding. 1 on success. */
int lk_controller_alert_ack(lk_controller *self, unsigned long long id);

/* Plugin tables (the AIS Targets list). tables_json lists the declarations;
 * table_rows answers one dialog's rows ALREADY ORDERED by the core (sort_key
 * NULL = the declared default); table_open tells the plugin somebody is
 * looking — call it with 1 on open and 0 on close, or the plugin builds no
 * rows. Malloc'd copies; NULL when unreadable. */
char *lk_controller_tables_json(lk_controller *self);
char *lk_controller_table_rows(lk_controller *self, const char *plugin, const char *key,
                               const char *sort_key, int ascending);
void lk_controller_table_open(lk_controller *self, const char *plugin, const char *key, int open);

/* The install surface. inspect returns the consent-sheet JSON for a .lkplug
 * (malloc'd; NULL when the plugin layer cannot start). install returns NULL
 * on SUCCESS, else a malloc'd one-sentence reason to show the mariner. */
char *lk_controller_plugin_inspect(lk_controller *self, const char *path);
char *lk_controller_plugin_install(lk_controller *self, const char *path);
int  lk_controller_plugin_uninstall(lk_controller *self, const char *id);
/* Flip one capability while the plugin runs; the lost call answers -1. */
int  lk_controller_plugin_grant_set(lk_controller *self, const char *id, const char *cap, int on);

/* Route every opened or dropped file through the plugins first: 1 a plugin
 * took it, 0 nobody claims it (open it as a chart), -1 claimed but failed.
 * Charts always answer 0. */
int lk_controller_open_file(lk_controller *self, const char *path);

/* Own ship: 0 no source (show the fix-it), 1 fix lost, 2 live — lon/lat are
 * written only for live. A readout shows these or nothing, never the map
 * centre. */
int lk_controller_own_ship(lk_controller *self, double *lon, double *lat);
/* Follow / course-up: 0 off, 1 on, 2 waiting for a fix. THE CORE CANCELS
 * follow on a pan and course-up on manual rotation — poll every tick, or a
 * button tracks only its own taps and goes wrong. */
void lk_controller_follow_set(lk_controller *self, int on);
int  lk_controller_follow_active(lk_controller *self);
void lk_controller_course_up_set(lk_controller *self, int on);
int  lk_controller_course_up_active(lk_controller *self);

/* Overlay objects a plugin drew (vessels, markers). at = hover payload JSON
 * within ~14 pt (malloc'd, NULL when nothing is there). hit/info fill
 * lk_overlay_obj with MALLOC'D id and info (info may be NULL) — free both
 * with lk_controller_overlay_free. info returns 0 once the object is gone;
 * re-read it every tick, the anchor moves. Logical points. A hit here must
 * suppress the chart pick report. */
typedef struct {
    char *id;
    char *info;    /* pick payload JSON, or NULL */
    double lon, lat;
} lk_overlay_obj;
char *lk_controller_overlay_at(lk_controller *self, double x_pt, double y_pt);
int  lk_controller_overlay_hit(lk_controller *self, double x_pt, double y_pt, lk_overlay_obj *out);
int  lk_controller_overlay_info(lk_controller *self, const char *id, lk_overlay_obj *out);
void lk_controller_overlay_free(lk_overlay_obj *obj);

/* Raster underlay (see lookout.h). add installs one .mbtiles and returns 1 on
 * success — persistence is the host's job (lk_store_note_raster). The set
 * names are copied into `out` (truncated, always NUL-terminated); in_view and
 * the active index build the pill's menu. */
int  lk_controller_raster_add(lk_controller *self, const char *path);
void lk_controller_raster_cycle(lk_controller *self);
void lk_controller_raster_select(lk_controller *self, int index); /* -1 = none */
int  lk_controller_raster_set_count(lk_controller *self);
int  lk_controller_raster_set_name(lk_controller *self, unsigned i, char *out, size_t out_len);
int  lk_controller_raster_set_in_view(lk_controller *self, unsigned i);
int  lk_controller_raster_active_index(lk_controller *self);
int  lk_controller_raster_set_enabled(lk_controller *self, const char *path, int enabled);
int  lk_controller_raster_enabled(lk_controller *self, const char *path);
/* A set's own drawn state (not "drawn over this view"): what gets saved, and
 * what set_shown restores by index without reference to the camera. */
int  lk_controller_raster_shown(lk_controller *self, unsigned i);
void lk_controller_raster_set_shown(lk_controller *self, unsigned i, int on);
void lk_controller_set_chart_hidden(lk_controller *self, int hidden);
/* How many vector charts are open. Zero is a library of pictures alone. */
int  lk_controller_charts_count(lk_controller *self);
/* Hide/show the ENC where a picture covers it (instant, never rebuilds). */
void lk_controller_toggle_chart(lk_controller *self);
int  lk_controller_chart_hidden(lk_controller *self);

#ifdef __cplusplus
}
#endif
#endif /* LK_CONTROLLER_H */
