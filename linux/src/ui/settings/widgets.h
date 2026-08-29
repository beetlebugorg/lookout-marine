/* ui/settings/widgets.h — the pieces every settings page is built from.
 *
 * Each page includes this and ui/settings/private.h, and builds itself out of
 * sections and rows. A control that edits one mariner field takes a pointer to
 * it: the binding writes the field and touches the mariner, so no page carries
 * an apply function of its own.
 */
#pragma once

#include "ui/settings/private.h"

G_BEGIN_DECLS

/* A page: a scrolling column in the stack, and its row in the sidebar. */
GtkWidget *lk_page_new (LkSettings *settings, const char *id, const char *title,
                        const char *icon_name);

/* A titled group of rows on a page. The `titled` form hands back the title
 * label, for a page that re-letters it; the `hinted` form puts a shortcut hint
 * at the right of the header. */
GtkWidget *lk_section (GtkWidget *page, const char *title);
GtkWidget *lk_section_titled (GtkWidget *page, const char *title, GtkWidget **out_title);
GtkWidget *lk_section_hinted (GtkWidget *page, const char *title, const char *hint);

/* A caption under a section, for what a control cannot say on its own. */
GtkWidget *lk_footer (GtkWidget *section, const char *text);

/* One row: a label at the left, one control at the right. */
GtkWidget *lk_row (GtkWidget *section, const char *title, GtkWidget *control);

/* A row bound to one mariner field. Each writes the field and touches the
 * mariner, and each does nothing while the window is reprogramming its own
 * widgets. */
void lk_switch_row (GtkWidget *section, LkSettings *settings, const char *title, bool *field);
void lk_size_row (GtkWidget *section, LkSettings *settings, const char *title, double *field);

/* A dropdown row. It writes `field`, or calls `apply` where the choice needs
 * more than a store. The dropdown is handed back for a page that reprograms
 * it. */
GtkWidget *lk_choice_row (GtkWidget          *section,
                          LkSettings         *settings,
                          const char         *title,
                          const char *const  *options,
                          int                 selected,
                          int                *field,
                          void              (*apply) (LkSettings *, int));

/* Frees a per-widget binding when its closure dies. Exposed because the pages
 * build bindings of their own. */
void lk_binding_free (gpointer data, GClosure *closure);

G_END_DECLS
