/* ui/dev-hooks.h — the LOOKOUT_* development hooks.
 *
 * The window applies them once it is built. Each hook names a change to make
 * after launch, so a screenshot run stages the app without a hand on the mouse.
 */
#pragma once

#include "ui/window-private.h"

G_BEGIN_DECLS

/* Read the LOOKOUT_* hooks and schedule each one. */
void lk_window_apply_dev_hooks (LkWindow *self);

G_END_DECLS
