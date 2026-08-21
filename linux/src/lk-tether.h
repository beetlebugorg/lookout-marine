/* Tie a signal handler on the app-lifetime model to a widget's life.
 *
 * The model outlives every widget listening to it, so a plain
 * g_signal_connect from a widget's builder leaves a handler that fires into
 * freed rows once the widget goes. g_signal_connect_object cannot carry the
 * builders' heap structs as data, so this cuts the handler from a weak
 * reference instead: when the widget finalizes, the handler is disconnected
 * and its closure notify (if any) frees the struct at the right moment.
 *
 * This does not silence the teardown emission — a notify fired WHILE the
 * widget tree is coming down still reaches the handler, because weak
 * references run after GtkWidget's own dispose. Handlers that touch children
 * must also guard with gtk_widget_in_destruction on their root.
 */
#ifndef LK_TETHER_H
#define LK_TETHER_H

#include <gtk/gtk.h>

typedef struct {
  gpointer instance; /* what the handler is connected on; not owned */
  gulong   id;
} LkTether;

static void
lk_tether_cut (gpointer data, GObject *dead)
{
  LkTether *t = data;

  (void) dead;
  g_signal_handler_disconnect (t->instance, t->id);
  g_free (t);
}

static inline void
lk_tether (gpointer instance, gulong handler_id, GtkWidget *widget)
{
  LkTether *t = g_new0 (LkTether, 1);

  t->instance = instance;
  t->id = handler_id;
  g_object_weak_ref (G_OBJECT (widget), lk_tether_cut, t);
}

#endif /* LK_TETHER_H */
