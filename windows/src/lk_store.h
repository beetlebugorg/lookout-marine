/* lk_store — persistence for the Windows shell.
 *
 * Mirrors linux/src/lk-store.c: camera pose, recents, the full mariner state
 * (saved field-by-field, never raw struct bytes), and the DMS HUD pref. Stored
 * as an INI at %APPDATA%\lookout-marine\settings.ini via the Win32 profile
 * API, except the raster library, which lives in rasters.list beside it — the
 * profile API truncates a section read at 32,767 chars, a fifth of the sheet
 * bundles the store is sized for. The mariner overlay applies each key only
 * when present, so an older file leaves newer fields at engine defaults.
 *
 * Thread-safe: one lock inside serializes every entry point, because the
 * render thread saves the pose while the UI thread writes settings. */
#ifndef LK_STORE_H
#define LK_STORE_H

#include <lookout.h> /* lookout_view, tile57_mariner */

#ifdef __cplusplus
extern "C" {
#endif

/* Camera pose. load returns 1 if a saved pose exists. */
int  lk_store_load_view(lookout_view *out);
void lk_store_save_view(const lookout_view *view);

/* Recents (most-recent-first, capped, deduped). Returns a NULL-terminated array
 * of malloc'd strings the caller frees with lk_store_free_recents. */
char **lk_store_load_recents(void);
void   lk_store_note_recent(const char *path);
void   lk_store_free_recents(char **recents);

/* Mariner state, saved/overlaid field-by-field. */
void lk_store_save_mariner(const tile57_mariner *m);
void lk_store_apply_saved_mariner(tile57_mariner *m);

/* The settings window's client size, so it opens where it was left. load
 * returns 1 when a size was saved. */
int  lk_store_load_settings_size(int *width, int *height);
void lk_store_save_settings_size(int width, int height);

/* Raster charts: the installed list survives a change of ENC and a restart —
 * the shell re-adds every stored path after each open. Each path carries its
 * own enabled flag (half-gigabyte downloads are switched off, not deleted).
 * load returns a NULL-terminated array of malloc'd paths, freed with
 * lk_store_free_rasters; *enabled_out (optional) receives a malloc'd int per
 * path, freed by the same call. note appends (deduped, enabled); forget
 * removes the path. */
char **lk_store_load_rasters(int **enabled_out);
void   lk_store_note_raster(const char *path);
void   lk_store_forget_raster(const char *path);
void   lk_store_set_raster_enabled(const char *path, int enabled);
void   lk_store_free_rasters(char **paths, int *enabled);
/* Batch forms: one load + one save whatever the count. A baked BSB/KAP
 * bundle adds hundreds of sheets at once. */
void   lk_store_note_rasters(const char *const *paths, int n);
void   lk_store_forget_rasters(const char *const *paths, int n);
void   lk_store_set_rasters_enabled(const char *const *paths, int n, int enabled);

/* Which raster SETS are not drawn, by set name — the pill's per-set choice,
 * distinct from a path's enabled flag. load returns a NULL-terminated array
 * of malloc'd names, freed with lk_store_free_recents. save replaces the
 * whole list (entries for sets not installed this launch are kept by the
 * caller). chart_hidden persists the "hide ENC over raster" toggle. */
char **lk_store_load_hidden_sets(void);
void   lk_store_save_hidden_sets(const char *const *names, int n);
int    lk_store_chart_hidden(void);
void   lk_store_set_chart_hidden(int hidden);

/* Chart sets: the folders of charts the mariner has aboard, each with an
 * on/off switch (switched off, not removed, when its water is not today's).
 * load returns a NULL-terminated array of malloc'd paths freed with
 * lk_store_free_rasters (same shape); *on_out (optional) receives a malloc'd
 * flag per path. note appends switched on (an existing entry keeps its
 * switch); forget removes. */
char **lk_store_load_chartsets(int **on_out);
void   lk_store_note_chartset(const char *path);
void   lk_store_forget_chartset(const char *path);
void   lk_store_set_chartset_on(const char *path, int on);

/* Chart links (an online map AS the chart): the whole list as one JSON text
 * the UI layer owns the shape of, plus the picked link's url. load returns a
 * malloc'd NUL-terminated string or NULL; caller frees. Written whole through
 * a temp file, like the raster library. */
char *lk_store_load_chartlinks(void);
void  lk_store_save_chartlinks(const char *json);
/* The active link's url, or "" for the built-in chart. */
int   lk_store_load_chartlink_active(char *out, int out_len);
void  lk_store_save_chartlink_active(const char *url);

/* Plugin settings, kept as the config object each plugin was last handed —
 * `{"cpa_limit":926,"cpa_alarm":true,"connections":[…]}` — one string per
 * plugin id.
 *
 * The whole object rather than field by field, because a LIST is in it: the
 * rows of a mariner's NMEA connections are the shell's to keep, and there is
 * nothing to get them back from once they are gone. Replaying the object the
 * plugin last accepted needs no schema on this side, and the core ignores a key
 * the manifest no longer declares.
 *
 * apply_saved pushes every stored object into the plugins of a freshly opened
 * chart, which is where a mariner's connections come back from. */
void lk_store_save_plugin_config(const char *plugin_id, const char *json);
void lk_store_apply_saved_plugins(lookout *h);

#ifdef __cplusplus
}
#endif
#endif /* LK_STORE_H */
