/* ui/settings/plugins-page.h — the Plugins page.
 *
 * What is loaded, what each one may reach, and how to add or remove one.
 */
#pragma once

#include "ui/settings/private.h"

G_BEGIN_DECLS

/* Build the page and add it to the window's stack and sidebar. */
void lk_build_plugins_page (LkSettings *settings);

G_END_DECLS
