/* lk-licenses.h — the licenses screen.
 *
 * The core bakes vendor/licenses/licenses.json into the binary and hands it
 * over whole (lookout_licenses_json), so this needs no connection and no file.
 * The entries whose `shells` array names "linux" are the ones this build
 * carries; the rest belong to other shells and are dropped.
 *
 * A license text is shown WHOLE. Nothing here truncates one, reflows one or
 * summarises one: only the width of the view breaks a line.
 */
#pragma once

#include <gtk/gtk.h>

G_BEGIN_DECLS

/* One component this build carries. Every field is set, and a field upstream
 * states nothing for is an empty string rather than NULL. The strings live as
 * long as the process. */
typedef struct {
  const char *id;
  const char *name;
  const char *group;
  const char *summary;
  const char *license;       /* empty when the terms could not be determined */
  const char *license_short; /* the same terms, for a narrow column */
  const char *license_note;  /* why, when `license` is empty */
  const char *version;
  const char *commit;
  const char *pinned_in;
  const char *copyright;
  const char *url;
  const char *text;         /* the license, whole */
  const char *notice;       /* the NOTICE file, empty when it ships none */
} LkLicenseComponent;

/* This app's own terms. Not a component, and never in the component count. */
typedef struct {
  const char *name;
  const char *summary;
  const char *license;
  const char *copyright;
  const char *url;
  const char *text;
} LkLicenseApp;

/* This app's terms, or NULL when the baked list will not parse. */
const LkLicenseApp *lk_licenses_app (void);

/* The components this build carries, in manifest order. Never NULL, and empty
 * when the list will not parse. The array and its rows belong to the module. */
const GPtrArray *lk_licenses_components (void);

/* One component by id, or NULL when this build carries none by that name. */
const LkLicenseComponent *lk_licenses_component (const char *id);

/* The version this build reports, as the About and Licenses screens say it. */
const char *lk_licenses_app_version (void);

/* What a component is pinned at: its version, or the first seven of its
 * commit. Empty when it states neither. Transfer full. */
char *lk_licenses_pin (const LkLicenseComponent *component);

/* Put the Licenses window on screen, on `id`'s entry. NULL or an empty id
 * opens on this app's own. A second call raises the window it already has. */
void lk_licenses_window_present (GtkWindow *parent, const char *id);

G_END_DECLS
