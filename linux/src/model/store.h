/* model/store.h — what the shell keeps across launches.
 *
 * The core owns the file: one JSON object of groups at
 * $XDG_CONFIG_HOME/lookout-marine/settings.json, with coalesced writes, one
 * lock over the file, and a set-aside copy when a file will not parse (see
 * lookout-shell.h). The group and key names are the core's, so a setting means
 * the same thing on every shell.
 *
 * THE CAMERA POSE AND THE MARINER SETTINGS ARE NOT HERE. The engine keeps both
 * in the same store, on its own cadence, once lk_store_handle() is passed to
 * lookout_set_store. This holds what the SHELL alone knows about: the recents,
 * the chart sets, the raster charts, the chart links and the plugin configs.
 *
 * A mariner arriving from a build that wrote settings.ini keeps their settings:
 * the ini is read once, into the same groups and keys, and left on disk.
 */
#pragma once

#include <glib.h>
#include <lookout.h>

G_BEGIN_DECLS

/* The store itself, for lookout_set_store. Opened on the first call and kept
 * for the process. Never NULL. */
lookout_store *lk_store_handle (void);

/* Write anything waiting and close. Call it once, as the app shuts down. */
void lk_store_shutdown (void);

/* TRUE when a camera pose has been saved. The ENGINE restores it; the shell
 * asks only because the answer decides whether it wants an opening view. */
gboolean lk_store_has_saved_view (void);

/* Recents, most recent first, capped. What the USER opened (folder or cell). */
char **lk_store_load_recents (void);
void   lk_store_note_recent (const char *path);

/* The raster charts the mariner installed, in the order added, and the ones
 * switched off. A raster chart must outlive both a change of ENC and a restart,
 * so the list is persisted here and replayed into each chart the engine opens. */
char **lk_store_load_raster_paths (void);
void   lk_store_save_raster_paths (const char *const *paths);
char **lk_store_load_raster_off (void);
void   lk_store_save_raster_off (const char *const *paths);

/* The SETS the mariner has stopped drawing, by set name, and whether the ENC
 * was hidden where a picture covers it. Both are choices the mariner made at
 * the pill, and neither survives on the installed list alone: the engine draws
 * a set as it opens it, so a launch that only replays the list turns a set they
 * switched off back on.
 *
 * Not the same thing as the off list. Off means "installed and quiet" and takes
 * a set out of the pill's list; this is the pill's own choice of which picture
 * covers this water, and a set that is not drawn is still offered. */
char   **lk_store_load_raster_hidden (void);
void     lk_store_save_raster_hidden (const char *const *names);

/* Write the installed list, the off list, and the hidden list in one pass. The
 * store coalesces writes, so this is one call rather than one file pass, and it
 * stays because the three belong to one change. */
void     lk_store_save_raster_all (const char *const *paths,
                                   const char *const *off,
                                   const char *const *hidden);

gboolean lk_store_load_chart_hidden (void);
void     lk_store_save_chart_hidden (gboolean hidden);

/* The chart SETS installed — the folders and archives the mariner added — and
 * the ones switched off. Only the path and the switch are stored: the cells
 * are scanned again at launch, because a folder changes underneath the app.
 * Load answers NULL when no library was ever saved (the caller seeds it from
 * the recents, once), and an empty strv for a library emptied on purpose. */
char **lk_store_load_chart_sets (void);
void   lk_store_save_chart_sets (const char *const *paths);
char **lk_store_load_chart_sets_off (void);
void   lk_store_save_chart_sets_off (const char *const *paths);

/* The chart links the mariner added, as one JSON array text — the same
 * document every shell stores ([{url,name,doc},…]), so what a link means is
 * defined once, in the chart-links code, not per store. NULL when none are
 * saved; free the load. The active link is the url of the one being sailed
 * on, or NULL/empty for lookout's own chart. */
char *lk_store_load_chart_links (void);
void  lk_store_save_chart_links (const char *json);
char *lk_store_load_chart_link_active (void);
void  lk_store_save_chart_link_active (const char *url);

/* Plugin settings, kept as the config object each plugin was last handed —
 * `{"cpa_limit":926,"cpa_alarm":true,"connections":[…]}` — one string per
 * plugin id.
 *
 * The whole object rather than field by field, because a LIST is in it: the
 * rows of a mariner's NMEA connections are the shell's to keep, and there is
 * nothing to get them back from once they are gone. Replaying the object the
 * plugin last accepted needs no schema on this side, and the core already
 * ignores a key the manifest no longer declares. */
char **lk_store_load_plugin_ids (void);
char  *lk_store_load_plugin_config (const char *plugin_id);
void   lk_store_save_plugin_config (const char *plugin_id, const char *json);

G_END_DECLS
