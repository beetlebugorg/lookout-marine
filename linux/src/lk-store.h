/* lk-store.h — persisted preferences (camera pose, recents, mariner settings)
 * in one GKeyFile at $XDG_CONFIG_HOME/lookout-marine/settings.ini. Mariner
 * state is stored field by field, not raw struct bytes (the layout is an engine
 * ABI detail); missing keys leave engine defaults in place. */
#pragma once

#include <glib.h>
#include <lookout.h>

G_BEGIN_DECLS

/* Camera pose. TRUE when a pose had been saved. */
gboolean lk_store_load_view (lookout_view *out);
void     lk_store_save_view (const lookout_view *view);

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
gboolean lk_store_load_chart_hidden (void);
void     lk_store_save_chart_hidden (gboolean hidden);

/* The chart links the mariner added, as one JSON array text — the same
 * document every shell stores ([{url,name,doc},…]), so what a link means is
 * defined once, in the chart-links code, not per store. NULL when none are
 * saved; free the load. The active link is the url of the one being sailed
 * on, or NULL/empty for lookout's own chart. */
char *lk_store_load_chart_links (void);
void  lk_store_save_chart_links (const char *json);
char *lk_store_load_chart_link_active (void);
void  lk_store_save_chart_link_active (const char *url);

/* Mariner settings. Load overlays onto a struct already holding engine
 * defaults, so unknown/engine-only fields are left untouched. */
void lk_store_save_mariner (const tile57_mariner *mariner);
void lk_store_apply_saved_mariner (tile57_mariner *mariner);

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

/* HUD coordinate format. */

G_END_DECLS
