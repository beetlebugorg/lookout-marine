/* ui/settings/plugins.h — the controls a plugin declared.
 *
 * The app knows nothing about what a plugin does. A number with a unit and a
 * range, a toggle, a text box, and a list of rows is the whole vocabulary.
 *
 * lk_plugin_fill_tab is declared in ui/settings/private.h instead: every page
 * ends with a call to it, and a page must not have to know this unit exists.
 */
#pragma once

#include "ui/settings/private.h"

G_BEGIN_DECLS

/* Re-letter the status lines in place. The plugins report their own state on
 * their own schedule, so the labels move without the page being rebuilt under
 * the mariner's hands. A GSourceFunc: the window runs it once a second while
 * the window is up. */
gboolean lk_plugin_status_poll (gpointer user_data);
void     lk_plugin_refresh_status_labels (LkSettings *settings);

/* Browse for what the loaded lists declare, and for nothing else. A window
 * with no list that browses starts nothing at all. */
void lk_settings_start_discovery (LkSettings *settings);

G_END_DECLS
