/* ui/chrome/licenses.h — the licenses screen.
 *
 * The core bakes vendor/licenses/licenses.json into the binary and reads it
 * back filtered to one shell (lookout_licenses_read), so this needs no
 * connection and no file, and the entries that belong to other shells never
 * arrive.
 *
 * A license text is shown WHOLE. Nothing here truncates one, reflows one or
 * summarises one: only the width of the view breaks a line.
 */
#pragma once

#include <gtk/gtk.h>
#include <lookout.h>

G_BEGIN_DECLS

/* A component and this app's own terms are both `lookout_license`, read from
 * the core (lookout-shell.h). Every field is set, and a field upstream states
 * nothing for is an empty string. The strings live as long as the process.
 */

/* This app's terms, or NULL when the baked list will not parse. Not a
 * component, and never in the component count. */
const lookout_license *lk_licenses_app (void);

/* The components this build carries, in manifest order, as
 * `const lookout_license *`. Never NULL, and empty when the list will not
 * parse. The array and its rows belong to the module. */
const GPtrArray *lk_licenses_components (void);

/* One component by id, or NULL when this build carries none by that name. */
const lookout_license *lk_licenses_component (const char *id);

/* The version this build reports, as the About and Licenses screens say it. */
const char *lk_licenses_app_version (void);

/* What a component is pinned at: its version, or the first seven of its
 * commit. Empty when it states neither. Transfer full. */
char *lk_licenses_pin (const lookout_license *component);

/* Put the Licenses window on screen, on `id`'s entry. NULL or an empty id
 * opens on this app's own. A second call raises the window it already has. */
void lk_licenses_window_present (GtkWindow *parent, const char *id);

G_END_DECLS
