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

/* THE PANE'S VERTICAL RHYTHM. Every gap on a settings page is one of these,
 * so a page reads as a stack of blocks and not as a list of one-off margins.
 *
 * They are BOX gaps, and a caption carries line leading of its own on top of
 * them. That is why the gap UNDER a shelf is set wider than the gap OVER the
 * next heading: measured on the screen the two then read the same, which is
 * what makes a shelf look like it closes its section. */
#define LK_GAP_HEADING 8  /* a heading to the shelf it heads */
#define LK_GAP_FOOTER  18 /* a shelf to the caption under it */
#define LK_GAP_SECTION 10 /* one section to the next, over the page's own gap */
#define LK_GAP_PAGE    12 /* between the sections of a page */
#define LK_GAP_ROW     8  /* between the rows on one shelf */

/* A page: a scrolling column in the stack, and its row in the sidebar. */
GtkWidget *lk_page_new (LkSettings *settings, const char *id, const char *title,
                        const char *icon_name);

/* A titled group of rows on a page. The `titled` form hands back the title
 * label, for a page that re-letters it; the `hinted` form puts a shortcut hint
 * or a summary at the right of the header, and hands that label back for a
 * page that re-letters it as the numbers land. */
GtkWidget *lk_section (GtkWidget *page, const char *title);
GtkWidget *lk_section_titled (GtkWidget *page, const char *title, GtkWidget **out_title);
GtkWidget *lk_section_hinted (GtkWidget *page, const char *title, const char *hint,
                              GtkWidget **out_hint);

/* A shaded shelf inside a section, holding the rows the heading names. The
 * shelf is what groups them: a page reads as a few blocks rather than one
 * column, and the rows inside can sit closer than the blocks do. `spacing` is
 * the gap between the rows put on it. */
GtkWidget *lk_group (GtkWidget *section, int spacing);

/* A caption that CLOSES a section, for what its controls cannot say on their
 * own. It sits outside the shelf, as the reference puts it, and LK_GAP_FOOTER
 * clear of whatever is above it — the shelf has an edge, and a note that hugs
 * that edge reads as the last row rather than as a note on the section. */
GtkWidget *lk_footer (GtkWidget *section, const char *text);

/* A caption under ONE control, where more controls follow. It belongs to the
 * control above it, so it sits closer to that than to the next one. A footer's
 * spacing here would read as the heading of what comes next. */
GtkWidget *lk_note (GtkWidget *section, const char *text);

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

/* The same row for a choice that saves somewhere other than the mariner: its
 * apply writes the store itself, and the mariner is left alone. */
GtkWidget *lk_choice_row_plain (GtkWidget         *section,
                                LkSettings        *settings,
                                const char        *title,
                                const char *const *options,
                                int                selected,
                                void             (*apply) (LkSettings *, int));

/* Bind a list on the Charts page to the function that fills it. */
void lk_deferred_list_bind (LkDeferredList *list, LkSettings *settings, GtkWidget *box,
                            void (*fill) (LkSettings *settings));

/* Rebuild the list on the next idle. Does nothing while the page is not built,
 * or while a rebuild is already waiting. */
void lk_deferred_list_schedule (LkDeferredList *list);

/* Drop a waiting rebuild. The window calls it as it goes. */
void lk_deferred_list_clear (LkDeferredList *list);

/* Frees a per-widget binding when its closure dies. Exposed because the pages
 * build bindings of their own. */
void lk_binding_free (gpointer data, GClosure *closure);

G_END_DECLS
