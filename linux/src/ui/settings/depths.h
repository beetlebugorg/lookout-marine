/* ui/settings/depths.h — the Depths page.
 *
 * Four contours, the unit they are read in, and how many shades of water sit
 * between them.
 */
#pragma once

#include "ui/settings/private.h"

G_BEGIN_DECLS

/* Build the page and add it to the window's stack and sidebar. */
void lk_build_depths_page (LkSettings *settings);

G_END_DECLS
