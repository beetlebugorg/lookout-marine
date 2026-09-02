/* lk_store — what the shell keeps across launches.
 *
 * The CORE owns the file: one JSON object of groups at
 * %APPDATA%\lookout-marine\settings.json, with coalesced writes, one lock over
 * the file, and a set-aside copy when a file will not parse (see
 * lookout-shell.h). The group and key names are the core's, so a setting means
 * the same thing on every shell.
 *
 * THE CAMERA POSE AND THE MARINER SETTINGS ARE NOT HERE. The engine keeps both
 * in the same store once lk_store_handle() is passed to lookout_set_store.
 * The INSTALLED SETS are not here either: lookout_chart_sets keeps them, in
 * this same store. This holds what the SHELL alone knows about: the recents,
 * the window frames, the raster charts, the chart links and the plugin
 * configs.
 *
 * A mariner arriving from a build that wrote settings.ini keeps their settings:
 * that file and the four lists beside it are read once, into the same groups
 * and key names, and left on disk.
 */
#ifndef LK_STORE_H
#define LK_STORE_H

#include <lookout.h> /* lookout_store, lookout_view, tile57_mariner */

#ifdef __cplusplus
extern "C" {
#endif

/* The store itself, for lookout_set_store and for the settings form's
 * chartless read. Opened on the first call and kept for the process. NULL
 * only when it cannot be opened. */
lookout_store *lk_store_handle(void);

/* Write anything waiting and close. Call it once, as the app shuts down. */
void lk_store_shutdown(void);

/* Where the store lives. The app never calls this: it defaults to
 * %APPDATA%\lookout-marine, which is the only place a mariner's settings
 * belong. It exists so a test can point the store at a directory it may
 * write, and it must be called before the first read or write. */
void lk_store_set_dir(const char *dir);

/* 1 when a camera pose has been saved. The ENGINE restores it; the shell asks
 * only because the answer decides whether it wants an opening view. */
int lk_store_has_saved_view(void);

/* Recents (most-recent-first, capped, deduped). Returns a NULL-terminated array
 * of malloc'd strings the caller frees with lk_store_free_recents. */
char **lk_store_load_recents(void);
void   lk_store_note_recent(const char *path);
void   lk_store_free_recents(char **recents);

/* The settings window's client size, so it opens where it was left. load
 * returns 1 when a size was saved. */
int  lk_store_load_settings_size(int *width, int *height);
void lk_store_save_settings_size(int width, int height);

/* One NAMED window frame (client size, physical px), for the windows that
 * should open where they were left — the vessel tables, one per plugin
 * table key. load returns 1 when a size was saved. */
int  lk_store_load_frame(const char *name, int *width, int *height);
void lk_store_save_frame(const char *name, int width, int height);

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
/* Forget the whole raster library, and the per-set hidden list with it:
 * hidden entries are keyed by set name, and leaving them behind means the
 * same file added again months later comes back not drawn with nothing on
 * screen to say why. The open chart is untouched — this takes effect at the
 * next open (the reference's clearRasterCharts). */
void   lk_store_clear_rasters(void);

/* Which raster SETS are not drawn, by set name — the pill's per-set choice,
 * distinct from a path's enabled flag. load returns a NULL-terminated array
 * of malloc'd names, freed with lk_store_free_recents. save replaces the
 * whole list (entries for sets not installed this launch are kept by the
 * caller). chart_hidden persists the "hide ENC over raster" toggle. */
char **lk_store_load_hidden_sets(void);
void   lk_store_save_hidden_sets(const char *const *names, int n);
int    lk_store_chart_hidden(void);
void   lk_store_set_chart_hidden(int hidden);

/* Chart links (an online map AS the chart): the whole list as one JSON text
 * the UI layer owns the shape of, plus the picked link's url. load returns a
 * malloc'd NUL-terminated string or NULL; caller frees. */
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
 * each_saved hands every stored object over, which is where a mariner's
 * connections come back from at every open. The store does not push them
 * itself: what a lookout handle is, is the controller's business
 * (lk_controller.c). */
void lk_store_save_plugin_config(const char *plugin_id, const char *json);
void lk_store_each_plugin_config(void (*fn)(void *user, const char *id, const char *json),
                                 void *user);

#ifdef __cplusplus
}
#endif
#endif /* LK_STORE_H */
