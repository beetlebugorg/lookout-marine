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

/* Mariner settings. Load overlays onto a struct already holding engine
 * defaults, so unknown/engine-only fields are left untouched. */
void lk_store_save_mariner (const tile57_mariner *mariner);
void lk_store_apply_saved_mariner (tile57_mariner *mariner);

/* HUD coordinate format. */
gboolean lk_store_load_use_dms (void);
void     lk_store_save_use_dms (gboolean use_dms);

G_END_DECLS
