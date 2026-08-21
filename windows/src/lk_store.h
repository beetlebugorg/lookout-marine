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
