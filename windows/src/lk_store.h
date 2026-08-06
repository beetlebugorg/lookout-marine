/* lk_store — persistence for the Windows shell.
 *
 * Mirrors linux/src/lk-store.c: camera pose, recents, the full mariner state
 * (saved field-by-field, never raw struct bytes), and the DMS HUD pref. Stored
 * as an INI at %APPDATA%\lookout-marine\settings.ini via the Win32 profile API.
 * The mariner overlay applies each key only when present, so an older file
 * leaves newer fields at engine defaults. */
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

#ifdef __cplusplus
}
#endif
#endif /* LK_STORE_H */
