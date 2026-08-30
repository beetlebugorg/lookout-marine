/* ui/settings/display.h — the Display page.
 *
 * The colour scheme, the display category, and the soundings rule.
 */
#pragma once

#include "ui/settings/private.h"

G_BEGIN_DECLS

/* Build the page and add it to the window's stack and sidebar. */
void lk_build_display_page (LkSettings *settings);

G_END_DECLS
