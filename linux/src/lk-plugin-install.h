/* lk-plugin-install.h — installing a plugin the mariner chose.
 *
 * A .lkplug is a package: a manifest and one wasm module. The core reads it
 * without installing it (lookout_plugin_inspect), which is everything the
 * consent sheet shows, and installs it only after the mariner agrees.
 *
 * NOTHING IS INSTALLED WITHOUT CONSENT, and the consent is informed: the sheet
 * lists what the package will be able to do, in the core's own sentences, and
 * calls out what CHANGES when the id is already running. The core refuses a
 * package that claims a bundled plugin's id, and the sheet shows the reason
 * instead of offering Install.
 *
 * The package loads hot, so the plugin draws without a restart.
 */
#pragma once

#include <gtk/gtk.h>

#include "lk-app-model.h"

G_BEGIN_DECLS

/* Read the package and put the consent sheet on screen. A package the core
 * refuses shows the reason and offers nothing.
 *
 * `on_installed` runs after a successful install, so the caller can re-read the
 * registry. It may be NULL. */
void lk_plugin_install_begin (GtkWindow  *parent,
                              LkAppModel *model,
                              const char *path,
                              GFunc       on_installed,
                              gpointer    user_data);

/* Present the file picker for a package, then the sheet. */
void lk_plugin_install_choose (GtkWindow  *parent,
                               LkAppModel *model,
                               GFunc       on_installed,
                               gpointer    user_data);

/* TRUE when `path` names a plugin package. A package goes to consent and never
 * to the chart engine: the extension is the package's own, so this is routing
 * rather than sniffing. */
gboolean lk_plugin_package_path (const char *path);

G_END_DECLS
