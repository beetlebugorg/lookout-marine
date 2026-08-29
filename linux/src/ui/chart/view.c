#include "ui/chart/view.h"

#include "model/app-model.h"
#include "lk-hud.h"
#include "util/json.h"

/* S-52 NODATA, day scheme — what lookout's first frame clears to. */
static const GdkRGBA LK_NODATA_COLOR = { 0.576f, 0.682f, 0.733f, 1.0f };

/* A press travelling no further than this is a tap (identify), not a throw. */
#define LK_TAP_SLOP 4.0
/* Re-contact this soon after a lift, and this close to it, is the same finger
   still dragging rather than a second tap. Measured off the AR1100: a drag
   fragments into sequences a few milliseconds and a few pixels apart. */
#define LK_TOUCH_STITCH_MS  220
#define LK_TOUCH_STITCH_PX  72.0
#define LK_TOUCH_PRESS_MS   550
/* A fingertip covers far more than the pointer's few pixels, and a resistive
   panel jitters under a still finger, so a touch has its own slop. Below it
   the chart does not move at all: the contact is still a candidate tap. */
#define LK_TOUCH_SLOP       22.0
/* Below this the coast is jitter, not a throw. Pixels per second. */
#define LK_TOUCH_FLING_MIN  120.0
/* Two taps this close together, in time and in place, are one gesture. The
   window has to outlast the stitch window below, because a tap cannot be
   answered until it is known not to be the first half of a double tap. */
#define LK_TOUCH_DOUBLE_MS  350
#define LK_TOUCH_DOUBLE_PX  48.0

/* Rotation stays inert until the fingers turn past this, so an incidental twist
 * during a pinch doesn't spin the chart. */
#define LK_ROTATE_DEADZONE (18.0 * G_PI / 180.0)

struct _LkChartView {
  GtkWidget parent_instance;

  LkAppModel        *model;      /* not owned */
  LkChartController *controller; /* not owned; lives on the model */

  LkNativeSurface *surface;   /* the chart's presentation surface */
  gboolean         did_auto_open;
  guint            auto_open_id;

  int      last_scale, last_width, last_height;
  gboolean presented; /* lookout has shown a frame; the surface may map */

  /* drag state */
  gboolean dragging, rotating;
  double   down_x, down_y;
  double   last_x, last_y;
  double   vx, vy;
  gint64   last_sample_us;

  /* Touch. The resistive panel breaks contact mid-drag, so one drag arrives as
     a run of short sequences; these stitch them back into one. */
  double   touch_x, touch_y;       /* last point seen, in either sequence */
  double   touch_down_x, touch_down_y;
  double   touch_moved;            /* path length since the first contact */
  gint64   touch_us;               /* when that point was seen */
  gboolean touch_taken;            /* a long press already answered for it */
  gboolean touch_was_tap;          /* the last contact ended without moving */
  guint    touch_settle_id;
  guint    touch_press_id;
  int      touch_points;           /* fingers down now, by begin/end count */
  gboolean touch_multi;            /* a second finger joined; the pinch and
                                      rotate gestures own the episode until all
                                      fingers lift, so pan stands off */

  /* pointer position, for scroll-anchored zoom */
  double   pointer_x, pointer_y;
  gboolean pointer_valid;

  /* rotate-gesture state */
  gboolean rotate_engaged;
  double   rotate_base_deg;
  double   rotate_offset;

  /* pinch state */
  double last_zoom_scale;

  /* The chart menu, and the point it was raised at. Every item acts on THIS
   * point: not the view centre, and not where the pointer drifts to afterwards,
   * so the coordinates are taken once, when the menu opens, and kept here. */
  GtkWidget *menu;
  double     menu_lon, menu_lat;
  double     menu_x, menu_y;
  LkMarker  *menu_marker; /* the mark under the press, when there is one */
};

G_DEFINE_FINAL_TYPE (LkChartView, lk_chart_view, GTK_TYPE_WIDGET)

/* ---- geometry ----------------------------------------------------------- */

void
lk_chart_view_get_point_size (LkChartView *self, int *width, int *height)
{
  int w = gtk_widget_get_width (GTK_WIDGET (self));
  int h = gtk_widget_get_height (GTK_WIDGET (self));

  /* Never open into a zero swapchain (allocation is 0 before first layout). */
  if (width != NULL)
    *width = w > 1 ? w : 1280;
  if (height != NULL)
    *height = h > 1 ? h : 800;
}

/* Where the surface sits inside the toplevel's GdkSurface. The native's offset
 * within the GdkSurface is non-zero whenever CSD reserves a shadow. */
static gboolean
lk_chart_view_compute_surface_rect (LkChartView *self, int *x, int *y, int *width, int *height)
{
  GtkNative *native = gtk_widget_get_native (GTK_WIDGET (self));
  if (native == NULL)
    return FALSE;

  graphene_rect_t bounds;
  if (!gtk_widget_compute_bounds (GTK_WIDGET (self), GTK_WIDGET (native), &bounds))
    return FALSE;

  double nx = 0, ny = 0;
  gtk_native_get_surface_transform (native, &nx, &ny);

  *x = (int) (nx + bounds.origin.x);
  *y = (int) (ny + bounds.origin.y);
  *width = MAX (1, (int) bounds.size.width);
  *height = MAX (1, (int) bounds.size.height);
  return TRUE;
}

static void
lk_chart_view_sync_surface (LkChartView *self)
{
  int x, y, width, height;
  if (!lk_chart_view_compute_surface_rect (self, &x, &y, &width, &height))
    return;

  int scale = gtk_widget_get_scale_factor (GTK_WIDGET (self));
  gboolean resized = self->surface != NULL
                         ? lk_native_surface_move_resize (self->surface, x, y, width, height, scale)
                         : (width != self->last_width || height != self->last_height);
  self->last_width = width;
  self->last_height = height;

  if (scale != self->last_scale)
    {
      self->last_scale = scale;
      lk_chart_controller_set_scale (self->controller, scale);
      resized = TRUE;
    }

  if (resized)
    lk_chart_controller_resize (self->controller, width, height);
}

/* ---- auto-open ---------------------------------------------------------- */

static gboolean
lk_chart_view_do_auto_open (gpointer user_data)
{
  LkChartView *self = user_data;

  self->auto_open_id = 0;

  if (!lk_chart_controller_is_open (self->controller))
    {
      g_auto (GStrv) paths = lk_app_model_initial_chart_paths (self->model);
      if (paths != NULL && g_strv_length (paths) > 0)
        {
          lk_chart_controller_open (self->controller, (const char *const *) paths, GTK_WIDGET (self));
        }
      else
        {
          /* Nothing here draws yet. It may still be charts: an exchange set as
             an agency publishes it is raw cells, which bake first. */
          g_autofree char *source = lk_app_model_initial_source (self->model);
          if (source != NULL)
            lk_app_model_open_chart_directory (self->model, source);
        }
    }

  lk_app_model_set_opening (self->model, FALSE, FALSE);
  return G_SOURCE_REMOVE;
}

/* Open the recent/default chart once the widget has a surface and a real size
 * (resizing mid-open wedges the swapchain). Deferred to an idle because the open
 * is synchronous and can take seconds, blocking the spinner's layout pass. */
static void
lk_chart_view_maybe_auto_open (LkChartView *self)
{
  if (self->did_auto_open || self->auto_open_id != 0)
    return;
  if (!gtk_widget_get_realized (GTK_WIDGET (self)))
    return;
  if (lk_chart_controller_is_open (self->controller))
    return;

  int width, height;
  if (gtk_widget_get_width (GTK_WIDGET (self)) <= 1 || gtk_widget_get_height (GTK_WIDGET (self)) <= 1)
    return;
  lk_chart_view_get_point_size (self, &width, &height);

  g_auto (GStrv) paths = lk_app_model_initial_chart_paths (self->model);
  /* Nothing baked is not nothing to do: the path may be an exchange set of raw
     cells, which the open below scans and bakes. Only a path with neither
     stops here. */
  g_autofree char *source = lk_app_model_initial_source (self->model);
  if ((paths == NULL || g_strv_length (paths) == 0) && source == NULL)
    return;

  self->did_auto_open = TRUE;
  /* Loader up before the synchronous open; the flag marks a first-ever run,
   * when the symbol/font atlases still have to be baked. */
  lk_app_model_set_opening_cells (self->model, paths != NULL ? g_strv_length (paths) : 0);
  lk_app_model_set_opening (self->model, TRUE, lookout_atlas_cache_ready () == 0);
  self->auto_open_id = g_idle_add (lk_chart_view_do_auto_open, self);
}

/* ---- widget lifecycle --------------------------------------------------- */

static void
lk_chart_view_realize (GtkWidget *widget)
{
  LkChartView *self = LK_CHART_VIEW (widget);

  GTK_WIDGET_CLASS (lk_chart_view_parent_class)->realize (widget);

  GtkNative *native = gtk_widget_get_native (widget);
  GdkSurface *parent = native != NULL ? gtk_native_get_surface (native) : NULL;
  if (parent == NULL)
    {
      g_warning ("chart view realized with no GdkSurface — no chart will render");
      return;
    }

  self->last_scale = gtk_widget_get_scale_factor (widget);

  /* No surface yet: the texture path needs none, and the path is chosen at open. */
  lk_chart_controller_attach_view (self->controller, widget);
  lk_chart_view_maybe_auto_open (self);
}

gboolean
lk_chart_view_ensure_native_surface (LkChartView *self)
{
  g_return_val_if_fail (LK_IS_CHART_VIEW (self), FALSE);

  if (self->surface != NULL)
    return TRUE;

  GtkNative *native = gtk_widget_get_native (GTK_WIDGET (self));
  GdkSurface *parent = native != NULL ? gtk_native_get_surface (native) : NULL;
  if (parent == NULL)
    return FALSE;

  int x = 0, y = 0, width = 1, height = 1;
  lk_chart_view_compute_surface_rect (self, &x, &y, &width, &height);

  g_autoptr (GError) error = NULL;
  self->surface = lk_native_surface_new (parent, x, y, width, height,
                                         gtk_widget_get_scale_factor (GTK_WIDGET (self)), &error);
  if (self->surface == NULL)
    {
      g_warning ("no native chart surface: %s", error->message);
      lk_app_model_set_open_error (self->model, error->message);
      return FALSE;
    }

  g_message ("chart surface up (%s), %d×%d pt at %d,%d",
             lk_native_surface_backend (self->surface), width, height, x, y);
  return TRUE;
}

static void
lk_chart_view_unrealize (GtkWidget *widget)
{
  LkChartView *self = LK_CHART_VIEW (widget);

  g_clear_handle_id (&self->auto_open_id, g_source_remove);
  g_clear_handle_id (&self->touch_settle_id, g_source_remove);
  g_clear_handle_id (&self->touch_press_id, g_source_remove);
  /* Close before the surface goes: lookout is presenting into it. */
  lk_chart_controller_close (self->controller);
  g_clear_pointer (&self->surface, lk_native_surface_free);
  /* A re-realize must open the chart and present a frame again. Reset the two
     flags that gate those steps, so the fresh surface repeats them instead of
     staying blank. */
  self->did_auto_open = FALSE;
  self->presented = FALSE;
  /* No finger can still be down across a re-realize, so clear the touch count
     and the multi-finger latch that would otherwise strand the pan. */
  self->touch_points = 0;
  self->touch_multi = FALSE;

  GTK_WIDGET_CLASS (lk_chart_view_parent_class)->unrealize (widget);
}

static void
lk_chart_view_map (GtkWidget *widget)
{
  LkChartView *self = LK_CHART_VIEW (widget);

  GTK_WIDGET_CLASS (lk_chart_view_parent_class)->map (widget);

  if (self->surface != NULL)
    {
      lk_native_surface_set_visible (self->surface, self->presented);
      lk_chart_view_sync_surface (self);
    }
}

static void
lk_chart_view_unmap (GtkWidget *widget)
{
  LkChartView *self = LK_CHART_VIEW (widget);

  if (self->surface != NULL)
    lk_native_surface_set_visible (self->surface, FALSE);

  GTK_WIDGET_CLASS (lk_chart_view_parent_class)->unmap (widget);
}

static void
lk_chart_view_size_allocate (GtkWidget *widget, int width, int height, int baseline)
{
  LkChartView *self = LK_CHART_VIEW (widget);

  GTK_WIDGET_CLASS (lk_chart_view_parent_class)->size_allocate (widget, width, height, baseline);

  /* The chrome is laid out against this: the capsule reads it to decide
   * whether the window is narrow, and the pick report is placed inside it. */
  lk_app_model_set_view_size (self->model, width, height);

  lk_chart_view_sync_surface (self);

  /* A popover parented to a widget is positioned from the widget's own
   * allocation, and this class does its own allocating. Without this the chart
   * menu stays where the window used to be after a resize. */
  if (self->menu != NULL)
    gtk_popover_present (GTK_POPOVER (self->menu));

  if (!self->did_auto_open)
    lk_chart_view_maybe_auto_open (self);
}

static void
lk_chart_view_snapshot (GtkWidget *widget, GtkSnapshot *snapshot)
{
  LkChartView *self = LK_CHART_VIEW (widget);

  /* Once the chart is presenting, paint NOTHING: a transparent hole the
   * subsurface BELOW shows through, with the chrome floating over it. Until the
   * first frame lands, fill NODATA so the desktop doesn't flash through. */
  if (!(self->surface != NULL && self->presented))
    {
      graphene_rect_t bounds = GRAPHENE_RECT_INIT (0, 0,
                                                   gtk_widget_get_width (widget),
                                                   gtk_widget_get_height (widget));
      gtk_snapshot_append_color (snapshot, &LK_NODATA_COLOR, &bounds);
    }

  GTK_WIDGET_CLASS (lk_chart_view_parent_class)->snapshot (widget, snapshot);
}

/* ---- input -------------------------------------------------------------- */

static void
lk_chart_view_sample_velocity (LkChartView *self, double dx, double dy)
{
  gint64 now = g_get_monotonic_time ();

  if (self->last_sample_us != 0 && now > self->last_sample_us)
    {
      double dt = (now - self->last_sample_us) / (double) G_USEC_PER_SEC;
      if (dt > 0.0005)
        {
          self->vx = self->vx * 0.5 + (dx / dt) * 0.5;
          self->vy = self->vy * 0.5 + (dy / dt) * 0.5;
        }
    }
  self->last_sample_us = now;
}

/* A plain click or tap on the chart. It pins an overlay symbol's bubble and
 * does nothing else.
 *
 * IT DOES NOT PICK. A stray click while panning used to throw a pick report
 * the mariner never asked for, and the plain click belongs to the chart. What
 * is at a point is asked for by name, from the menu a secondary click or a
 * held finger raises there. The reference shell follows the same rule
 * (ChartView.swift, tapChart).
 *
 * A PLUGIN'S SYMBOL STILL ANSWERS. A click that lands on a vessel pins its
 * bubble: the mariner clicked the target, not the water it is over. A click
 * elsewhere closes the bubble. */
static void
lk_chart_view_tap (LkChartView *self, double x, double y)
{
  g_autoptr (LkOverlayObject) object =
      lk_chart_controller_overlay_hit (self->controller, x, y);

  lk_app_model_pin_overlay (self->model, object != NULL ? object->id : NULL);
}

/* ---- the chart menu ------------------------------------------------------ */

static void
lk_chart_view_close_menu (LkChartView *self)
{
  if (self->menu != NULL)
    gtk_popover_popdown (GTK_POPOVER (self->menu));
}

/* Close the chart menu if it is open, for the window's Escape cascade. TRUE
 * when there was one to close. The marker rename field lives in the menu, so it
 * goes with it. */
gboolean
lk_chart_view_dismiss (LkChartView *self)
{
  g_return_val_if_fail (LK_IS_CHART_VIEW (self), FALSE);

  if (self->menu != NULL && gtk_widget_get_mapped (self->menu))
    {
      gtk_popover_popdown (GTK_POPOVER (self->menu));
      return TRUE;
    }
  return FALSE;
}

/* The model retired the chrome after a camera move. Close the menu with it. */
static void
lk_chart_view_chrome_retired (LkAppModel *model, gpointer user_data)
{
  LkChartView *self = user_data;

  if (gtk_widget_in_destruction (GTK_WIDGET (self)))
    return;
  lk_chart_view_close_menu (self);
}

/* The report for the point the menu was raised at. The report itself is
 * unchanged; only the way it is raised is new. */
static void
lk_chart_menu_pick (GtkButton *button, gpointer user_data)
{
  LkChartView *self = user_data;

  lk_chart_view_close_menu (self);
  lk_app_model_set_pick (self->model,
                         lk_chart_controller_pick (self->controller,
                                                   self->menu_lon, self->menu_lat),
                         self->menu_x, self->menu_y, self->menu_lon, self->menu_lat);
}

/* THE DROP NEVER WAITS FOR TYPING. The core places the mark and names it in one
 * call, because a mariner drops a mark one-handed on a moving boat, often to
 * record something they have just seen. Renaming is a separate, unhurried
 * action. */
static void
lk_chart_menu_drop_marker (GtkButton *button, gpointer user_data)
{
  LkChartView *self = user_data;

  lk_chart_view_close_menu (self);
  lk_chart_controller_marker_add (self->controller, self->menu_lon, self->menu_lat);
}

static void
lk_chart_menu_remove_marker (GtkButton *button, gpointer user_data)
{
  LkChartView *self = user_data;

  lk_chart_view_close_menu (self);
  if (self->menu_marker != NULL)
    lk_chart_controller_marker_remove (self->controller, self->menu_marker->id);
}

/* The point's coordinates in the mariner's own format: the one the readout, the
 * deck log and the radio all use. This is where the coordinates of a PLACE come
 * from, which is why the readout never has to guess. */
static void
lk_chart_menu_copy_position (GtkButton *button, gpointer user_data)
{
  LkChartView *self = user_data;
  g_autofree char *lat = lk_coord_format_dm (self->menu_lat, TRUE);
  g_autofree char *lon = lk_coord_format_dm (self->menu_lon, FALSE);
  g_autofree char *text = g_strdup_printf ("%s %s", lat, lon);

  lk_chart_view_close_menu (self);
  gdk_clipboard_set_text (gtk_widget_get_clipboard (GTK_WIDGET (self)), text);
}

/* Return commits. An EMPTY name keeps the old one, which the core decides, so
 * every shell agrees on what an emptied field means. */
static void
lk_chart_menu_rename_committed (GtkEntry *entry, gpointer user_data)
{
  LkChartView *self = user_data;

  if (self->menu_marker != NULL)
    lk_chart_controller_marker_rename (self->controller, self->menu_marker->id,
                                       gtk_editable_get_text (GTK_EDITABLE (entry)));
  lk_chart_view_close_menu (self);
}

static void
lk_chart_menu_item (GtkWidget *box, const char *label, GCallback action, gpointer data)
{
  GtkWidget *item = gtk_button_new_with_label (label);

  gtk_widget_add_css_class (item, "flat");
  gtk_button_set_has_frame (GTK_BUTTON (item), FALSE);
  gtk_widget_set_halign (item, GTK_ALIGN_FILL);
  gtk_label_set_xalign (GTK_LABEL (gtk_button_get_child (GTK_BUTTON (item))), 0.0);
  g_signal_connect (item, "clicked", action, data);
  gtk_box_append (GTK_BOX (box), item);
}

/* Over a marker the menu offers Rename and Remove IN PLACE OF Drop: a mariner
 * pressing on a mark is acting on that mark, not adding a second one on top of
 * it. */
static void
lk_chart_view_open_menu (LkChartView *self, double x, double y)
{
  double lon, lat;

  if (!lk_chart_controller_geo_at (self->controller, x, y, &lon, &lat))
    return;

  /* One thing at a time over the chart. */
  lk_app_model_pin_overlay (self->model, NULL);

  self->menu_x = x;
  self->menu_y = y;
  self->menu_lon = lon;
  self->menu_lat = lat;
  g_clear_pointer (&self->menu_marker, lk_marker_free);
  self->menu_marker = lk_chart_controller_marker_at (self->controller, x, y);

  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);

  /* A header naming the place the menu acts on: the mark's name when the press
     was on one, and the coordinate under it. A label, not a button, as the
     reference's menu header is. */
  if (self->menu_marker != NULL && self->menu_marker->name != NULL &&
      self->menu_marker->name[0] != '\0')
    {
      GtkWidget *title = gtk_label_new (self->menu_marker->name);
      gtk_widget_add_css_class (title, "lk-menu-title");
      gtk_label_set_xalign (GTK_LABEL (title), 0.0);
      gtk_box_append (GTK_BOX (box), title);
    }
  g_autofree char *hlat = lk_coord_format_dm (lat, TRUE);
  g_autofree char *hlon = lk_coord_format_dm (lon, FALSE);
  g_autofree char *coord = g_strdup_printf ("%s  %s", hlat, hlon);
  GtkWidget *header = gtk_label_new (coord);
  gtk_widget_add_css_class (header, "dim-label");
  gtk_widget_add_css_class (header, "lk-menu-coord");
  gtk_label_set_xalign (GTK_LABEL (header), 0.0);
  gtk_box_append (GTK_BOX (box), header);

  /* The reference's order: Pick report, then Drop or (rename + Remove), then
     Copy position. The strings match it verbatim. */
  lk_chart_menu_item (box, "Pick report", G_CALLBACK (lk_chart_menu_pick), self);

  if (self->menu_marker != NULL)
    {
      /* The field opens with the mark's current name in it. */
      GtkWidget *entry = gtk_entry_new ();

      gtk_entry_set_placeholder_text (GTK_ENTRY (entry), "Mark name");
      gtk_editable_set_text (GTK_EDITABLE (entry), self->menu_marker->name);
      gtk_entry_set_max_length (GTK_ENTRY (entry), 32);
      gtk_entry_set_activates_default (GTK_ENTRY (entry), FALSE);
      g_signal_connect (entry, "activate", G_CALLBACK (lk_chart_menu_rename_committed), self);
      gtk_box_append (GTK_BOX (box), entry);

      lk_chart_menu_item (box, "Remove marker", G_CALLBACK (lk_chart_menu_remove_marker), self);
    }
  else
    {
      lk_chart_menu_item (box, "Drop marker", G_CALLBACK (lk_chart_menu_drop_marker), self);
    }

  lk_chart_menu_item (box, "Copy position", G_CALLBACK (lk_chart_menu_copy_position), self);

  if (self->menu == NULL)
    {
      self->menu = gtk_popover_new ();
      gtk_widget_set_parent (self->menu, GTK_WIDGET (self));
      gtk_popover_set_has_arrow (GTK_POPOVER (self->menu), FALSE);
      gtk_popover_set_position (GTK_POPOVER (self->menu), GTK_POS_BOTTOM);
      gtk_widget_add_css_class (self->menu, "menu");
    }

  gtk_popover_set_child (GTK_POPOVER (self->menu), box);
  gtk_popover_set_pointing_to (GTK_POPOVER (self->menu),
                               &(GdkRectangle){ (int) x, (int) y, 1, 1 });
  gtk_popover_popup (GTK_POPOVER (self->menu));
}

/* A click gesture's current event came from a touchscreen. Touch is handled by
   the legacy controller and the zoom and rotate gestures, so the click handlers
   stand off it — the same test the scroll handler makes. */
static gboolean
lk_chart_view_gesture_is_touch (GtkGesture *gesture)
{
  GdkEvent *event =
      gtk_event_controller_get_current_event (GTK_EVENT_CONTROLLER (gesture));
  GdkDevice *source = event != NULL ? gdk_event_get_device (event) : NULL;

  return source != NULL && gdk_device_get_source (source) == GDK_SOURCE_TOUCHSCREEN;
}

static void
lk_chart_view_menu_pressed (GtkGestureClick *gesture, int n_press, double x, double y,
                            gpointer user_data)
{
  if (lk_chart_view_gesture_is_touch (GTK_GESTURE (gesture)))
    return;
  lk_chart_view_open_menu (user_data, x, y);
}

static void
lk_chart_view_pressed (GtkGestureClick *gesture,
                       int              n_press,
                       double           x,
                       double           y,
                       gpointer         user_data)
{
  LkChartView *self = user_data;
  GdkModifierType state =
      gtk_event_controller_get_current_event_state (GTK_EVENT_CONTROLLER (gesture));

  if (lk_chart_view_gesture_is_touch (GTK_GESTURE (gesture)))
    return;

  self->down_x = x;
  self->down_y = y;
  self->last_x = x;
  self->last_y = y;
  self->vx = 0;
  self->vy = 0;
  self->last_sample_us = 0;

  /* Grabbing stops any coast. */
  lk_chart_controller_fling_start (self->controller, 0, 0);

  if (state & GDK_SHIFT_MASK)
    {
      self->rotating = TRUE;
      self->dragging = FALSE;
    }
  else
    {
      self->dragging = TRUE;
      self->rotating = FALSE;
    }

  /* Double-click zooms in a level, as on the other shells. */
  if (n_press == 2)
    {
      self->dragging = FALSE;
      self->rotating = FALSE;
      lk_chart_controller_zoom_at (self->controller, 1.0, x, y);
    }

  gtk_widget_grab_focus (GTK_WIDGET (self));
}

static void
lk_chart_view_released (GtkGestureClick *gesture,
                        int              n_press,
                        double           x,
                        double           y,
                        gpointer         user_data)
{
  LkChartView *self = user_data;
  gboolean was_rotating = self->rotating;

  if (lk_chart_view_gesture_is_touch (GTK_GESTURE (gesture)))
    return;

  self->dragging = FALSE;
  self->rotating = FALSE;

  if (was_rotating || n_press > 1)
    return;

  double moved = hypot (x - self->down_x, y - self->down_y);
  if (moved <= LK_TAP_SLOP)
    lk_chart_view_tap (self, x, y);
  else
    lk_chart_controller_fling_start (self->controller, self->vx, self->vy);
}

/* Single-finger touch, stitched.
 *
 * A resistive panel does not hold contact through a drag: one finger crossing
 * the chart arrives as a run of short sequences, each a begin, a couple of
 * updates and an end, tens of milliseconds apart. Left to the click gesture
 * that reads as repeated double taps, which zoom, and no sequence lives long
 * enough to pass the drag threshold, so nothing pans.
 *
 * So one-finger touch is stitched here instead, in the capture phase, and a
 * begin that lands soon after and near the last lift continues the drag it
 * belongs to. The decision between a tap and the end of a drag waits out the
 * stitch window, because until it passes there is no telling which one this
 * was. The handler propagates every event, so the pinch and rotate gestures
 * still see two-finger episodes; the click gesture ignores touch instead. */
static gboolean
lk_chart_view_touch_settle (gpointer user_data)
{
  LkChartView *self = user_data;

  self->touch_settle_id = 0;
  self->touch_was_tap = FALSE;

  if (self->touch_taken)
    self->touch_taken = FALSE;
  else if (self->touch_moved <= LK_TOUCH_SLOP)
    lk_chart_view_tap (self, self->touch_down_x, self->touch_down_y);
  else if (hypot (self->vx, self->vy) > LK_TOUCH_FLING_MIN)
    lk_chart_controller_fling_start (self->controller, self->vx, self->vy);

  return G_SOURCE_REMOVE;
}

/* A finger held still on the chart raises the menu a secondary click raises. */
static gboolean
lk_chart_view_touch_press (gpointer user_data)
{
  LkChartView *self = user_data;

  self->touch_press_id = 0;

  if (self->touch_moved <= LK_TOUCH_SLOP)
    {
      self->touch_taken = TRUE;
      lk_chart_view_open_menu (self, self->touch_down_x, self->touch_down_y);
    }

  return G_SOURCE_REMOVE;
}

static gboolean
lk_chart_view_touch (GtkEventControllerLegacy *controller, GdkEvent *event, gpointer user_data)
{
  LkChartView *self = user_data;
  GdkEventType type = gdk_event_get_event_type (event);
  double x, y;
  gint64 now;

  if (type != GDK_TOUCH_BEGIN && type != GDK_TOUCH_UPDATE && type != GDK_TOUCH_END)
    return GDK_EVENT_PROPAGATE;

  if (!gdk_event_get_position (event, &x, &y))
    return GDK_EVENT_PROPAGATE;

  now = g_get_monotonic_time ();

  /* Count the fingers down. The pinch and rotate gestures need two, and they
     only see these events because this handler propagates every one. A second
     finger ends the single-finger interaction and hands the episode to those
     gestures: pan, the tap and the long-press stand off until all fingers lift.
     Before this, the handler stopped every touch event, so the gestures were
     never fed and two fingers only shuddered the pan. */
  if (type == GDK_TOUCH_BEGIN)
    {
      self->touch_points++;
      if (self->touch_points >= 2 && !self->touch_multi)
        {
          self->touch_multi = TRUE;
          g_clear_handle_id (&self->touch_press_id, g_source_remove);
          g_clear_handle_id (&self->touch_settle_id, g_source_remove);
          lk_chart_controller_fling_start (self->controller, 0, 0);
          self->touch_taken = TRUE; /* the lift must not read as a tap */
        }
    }
  else if (type == GDK_TOUCH_END && self->touch_points > 0)
    {
      self->touch_points--;
    }

  if (self->touch_multi)
    {
      if (type == GDK_TOUCH_END && self->touch_points == 0)
        {
          self->touch_multi = FALSE;
          self->touch_taken = FALSE;
          self->touch_was_tap = FALSE;
          self->touch_us = 0; /* the next contact is fresh, not a stitch */
        }
      return GDK_EVENT_PROPAGATE;
    }

  switch ((int) type)
    {
    case GDK_TOUCH_BEGIN:
      {
        gint64 since = self->touch_us == 0 ? G_MAXINT64 : now - self->touch_us;
        double moved_since = hypot (x - self->touch_x, y - self->touch_y);

        /* Coming down again soon and nearby means one of two things, and which
           one depends on what the LAST contact was. After a tap it is the
           second half of a double tap. After a drag it is the same finger, which
           this panel drops mid-stroke, coming back to carry on. */
        gboolean double_tap = self->touch_was_tap &&
                              since < LK_TOUCH_DOUBLE_MS * 1000 &&
                              moved_since < LK_TOUCH_DOUBLE_PX;
        gboolean same_finger = !self->touch_was_tap &&
                               since < LK_TOUCH_STITCH_MS * 1000 &&
                               moved_since < LK_TOUCH_STITCH_PX;

        g_clear_handle_id (&self->touch_settle_id, g_source_remove);

        if (double_tap)
          {
            /* The first tap never got to identify anything: its settle was
               still pending, and cancelling it above is what makes the double
               tap read as one gesture rather than a pick and then a zoom. */
            g_clear_handle_id (&self->touch_press_id, g_source_remove);
            lk_chart_controller_fling_start (self->controller, 0, 0);
            lk_chart_controller_zoom_at (self->controller, 1.0, x, y);

            self->touch_was_tap = FALSE;
            self->touch_taken = TRUE; /* this contact has had its answer */
            self->touch_moved = 0;
            self->touch_x = x;
            self->touch_y = y;
            self->touch_us = now;
            return GDK_EVENT_PROPAGATE;
          }

        if (!same_finger)
          {
            g_clear_handle_id (&self->touch_press_id, g_source_remove);
            self->touch_down_x = x;
            self->touch_down_y = y;
            self->touch_moved = 0;
            self->touch_taken = FALSE;
            self->vx = 0;
            self->vy = 0;
            self->last_sample_us = 0;
            lk_chart_controller_fling_start (self->controller, 0, 0);
            self->touch_press_id =
                g_timeout_add (LK_TOUCH_PRESS_MS, lk_chart_view_touch_press, self);
          }
        else
          {
            /* The same finger came back to carry on the stroke. It rests on the
               glass now, so stop the coast and start velocity sampling fresh.
               Without this the old fling stays armed and the stitched contact
               relaunches it on release. */
            self->vx = 0;
            self->vy = 0;
            self->last_sample_us = 0;
            lk_chart_controller_fling_start (self->controller, 0, 0);
          }

        self->touch_x = x;
        self->touch_y = y;
        self->touch_us = now;
        gtk_widget_grab_focus (GTK_WIDGET (self));
        return GDK_EVENT_PROPAGATE;
      }

    case GDK_TOUCH_UPDATE:
      {
        double dx = x - self->touch_x;
        double dy = y - self->touch_y;
        /* How far the contact has actually got from where it went down, NOT
           the length of the path it wandered: a still finger on this panel
           jitters, and a sum would call that a drag within a few samples. */
        double moved = hypot (x - self->touch_down_x, y - self->touch_down_y);

        if (moved > self->touch_moved)
          self->touch_moved = moved;

        self->touch_x = x;
        self->touch_y = y;
        self->touch_us = now;

        /* Under the slop this is still a candidate tap, and the chart holds
           still: panning here is what makes a stationary finger shake it. */
        if (self->touch_moved <= LK_TOUCH_SLOP)
          return GDK_EVENT_PROPAGATE;

        g_clear_handle_id (&self->touch_press_id, g_source_remove);
        lk_chart_controller_pan (self->controller, dx, dy);
        lk_chart_view_sample_velocity (self, dx, dy);
        return GDK_EVENT_PROPAGATE;
      }

    case GDK_TOUCH_END:
      self->touch_x = x;
      self->touch_y = y;
      self->touch_us = now;
      /* A contact already answered (a long press, or the zoom half of a double
         tap) must not arm another one, or a third touch would zoom again. */
      self->touch_was_tap = !self->touch_taken && self->touch_moved <= LK_TOUCH_SLOP;
      g_clear_handle_id (&self->touch_press_id, g_source_remove);
      g_clear_handle_id (&self->touch_settle_id, g_source_remove);
      /* A tap waits out the double-tap window before it identifies anything;
         a drag only has to outlast this panel's dropouts. */
      self->touch_settle_id =
          g_timeout_add (self->touch_was_tap ? LK_TOUCH_DOUBLE_MS : LK_TOUCH_STITCH_MS,
                         lk_chart_view_touch_settle, self);
      return GDK_EVENT_PROPAGATE;

    default:
      return GDK_EVENT_PROPAGATE;
    }
}

static void
lk_chart_view_motion (GtkEventControllerMotion *controller,
                      double                    x,
                      double                    y,
                      gpointer                  user_data)
{
  LkChartView *self = user_data;

  self->pointer_x = x;
  self->pointer_y = y;
  self->pointer_valid = TRUE;

  if (self->rotating)
    {
      lk_chart_controller_rotate_drag (self->controller, self->last_x, self->last_y, x, y);
    }
  else if (self->dragging)
    {
      double dx = x - self->last_x;
      double dy = y - self->last_y;
      lk_chart_controller_pan (self->controller, dx, dy);
      lk_chart_view_sample_velocity (self, dx, dy);
    }

  self->last_x = x;
  self->last_y = y;
}

static void
lk_chart_view_leave (GtkEventControllerMotion *controller, gpointer user_data)
{
  LkChartView *self = user_data;

  self->pointer_valid = FALSE;
}

static gboolean
lk_chart_view_scroll (GtkEventControllerScroll *controller,
                      double                    dx,
                      double                    dy,
                      gpointer                  user_data)
{
  LkChartView *self = user_data;

  if (dy == 0.0)
    return GDK_EVENT_PROPAGATE;

  /* A wheel notch arrives as ±1; a touchpad's scroll is far larger per event. */
  GdkEvent *event = gtk_event_controller_get_current_event (GTK_EVENT_CONTROLLER (controller));

  /* GTK synthesizes scroll from a one-finger drag on a touchscreen. The drag
     gesture already pans for that, so honouring it here would zoom as well. */
  GdkDevice *source = event != NULL ? gdk_event_get_device (event) : NULL;
  if (source != NULL && gdk_device_get_source (source) == GDK_SOURCE_TOUCHSCREEN)
    return GDK_EVENT_PROPAGATE;

  gboolean precise = event != NULL &&
                     gdk_scroll_event_get_unit (event) == GDK_SCROLL_UNIT_SURFACE;
  double factor = precise ? 0.01 : 0.25;

  double x = self->pointer_valid ? self->pointer_x : gtk_widget_get_width (GTK_WIDGET (self)) / 2.0;
  double y = self->pointer_valid ? self->pointer_y : gtk_widget_get_height (GTK_WIDGET (self)) / 2.0;

  /* GDK counts a downward scroll positive; zooming IN is negative dy. */
  lk_chart_controller_zoom_at (self->controller, -dy * factor, x, y);
  return GDK_EVENT_STOP;
}

static void
lk_chart_view_zoom_begin (GtkGesture *gesture, GdkEventSequence *sequence, gpointer user_data)
{
  LkChartView *self = user_data;

  self->last_zoom_scale = gtk_gesture_zoom_get_scale_delta (GTK_GESTURE_ZOOM (gesture));
  lk_chart_controller_fling_start (self->controller, 0, 0);
}

static void
lk_chart_view_zoom_changed (GtkGestureZoom *gesture, double scale, gpointer user_data)
{
  LkChartView *self = user_data;

  if (scale <= 0 || self->last_zoom_scale <= 0)
    return;

  double dz = log2 (scale / self->last_zoom_scale);
  self->last_zoom_scale = scale;
  if (dz == 0.0)
    return;

  /* Anchored at the centroid so the point under the fingers stays put. */
  double cx, cy;
  if (!gtk_gesture_get_bounding_box_center (GTK_GESTURE (gesture), &cx, &cy))
    {
      cx = gtk_widget_get_width (GTK_WIDGET (self)) / 2.0;
      cy = gtk_widget_get_height (GTK_WIDGET (self)) / 2.0;
    }
  lk_chart_controller_zoom_at (self->controller, dz, cx, cy);
}

static void
lk_chart_view_rotate_begin (GtkGesture *gesture, GdkEventSequence *sequence, gpointer user_data)
{
  LkChartView *self = user_data;

  self->rotate_engaged = FALSE;
}

double
lk_chart_view_unwrap_angle (double a)
{
  a = fmod (a, 2.0 * G_PI);
  if (a > G_PI)
    a -= 2.0 * G_PI;
  else if (a <= -G_PI)
    a += 2.0 * G_PI;
  return a;
}

static void
lk_chart_view_rotate_changed (GtkGestureRotate *gesture,
                              double            angle,
                              double            delta,
                              gpointer          user_data)
{
  LkChartView *self = user_data;
  double turn = lk_chart_view_unwrap_angle (delta);

  /* Inert until past the dead-zone, then track from there without jumping. */
  if (!self->rotate_engaged)
    {
      if (fabs (turn) < LK_ROTATE_DEADZONE)
        return;
      self->rotate_engaged = TRUE;
      self->rotate_base_deg = lk_chart_controller_get_view (self->controller).rotation_deg;
      self->rotate_offset = turn;
    }

  lookout_view view = lk_chart_controller_get_view (self->controller);
  view.rotation_deg =
      self->rotate_base_deg + lk_chart_view_unwrap_angle (turn - self->rotate_offset) * 180.0 / G_PI;
  lk_chart_controller_set_view (self->controller, view);
}

void
lk_chart_view_surface_ready (LkChartView *self)
{
  g_return_if_fail (LK_IS_CHART_VIEW (self));

  if (self->presented || self->surface == NULL)
    return;

  self->presented = TRUE;
  if (gtk_widget_get_mapped (GTK_WIDGET (self)))
    lk_native_surface_set_visible (self->surface, TRUE);
  /* Re-snapshot: the widget goes transparent now the subsurface is showing. */
  gtk_widget_queue_draw (GTK_WIDGET (self));
}

/* ---- construction ------------------------------------------------------- */

static void
lk_chart_view_dispose (GObject *object)
{
  LkChartView *self = LK_CHART_VIEW (object);

  g_clear_handle_id (&self->auto_open_id, g_source_remove);
  g_clear_handle_id (&self->touch_settle_id, g_source_remove);
  g_clear_handle_id (&self->touch_press_id, g_source_remove);
  g_clear_pointer (&self->surface, lk_native_surface_free);
  g_clear_pointer (&self->menu_marker, lk_marker_free);
  /* A popover parented to a widget has to be unparented before the widget
     goes, or GTK warns that it is finalising with a child still attached. */
  g_clear_pointer (&self->menu, gtk_widget_unparent);

  G_OBJECT_CLASS (lk_chart_view_parent_class)->dispose (object);
}

static void
lk_chart_view_class_init (LkChartViewClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);
  GtkWidgetClass *widget_class = GTK_WIDGET_CLASS (klass);

  object_class->dispose = lk_chart_view_dispose;

  widget_class->realize = lk_chart_view_realize;
  widget_class->unrealize = lk_chart_view_unrealize;
  widget_class->map = lk_chart_view_map;
  widget_class->unmap = lk_chart_view_unmap;
  widget_class->size_allocate = lk_chart_view_size_allocate;
  widget_class->snapshot = lk_chart_view_snapshot;

  gtk_widget_class_set_css_name (widget_class, "chartview");
}

/* The hover tip over a plugin's symbol: a vessel's name, course and speed,
 * formatted from the JSON lookout_overlay_at documents — title bold, then a
 * dim key beside each value. FALSE (no tip) over open water. GTK owns the
 * dwell and the re-query on movement, so the engine is asked only when a tip
 * could actually show. */
static gboolean
lk_chart_view_query_tooltip (GtkWidget *widget, int x, int y, gboolean keyboard,
                             GtkTooltip *tooltip, gpointer user_data)
{
  LkChartView *self = LK_CHART_VIEW (widget);

  if (keyboard)
    return FALSE;

  /* A pinned bubble already states the object; a tip floating over it would
   * say the same thing twice. The reference suppresses the hover too. */
  if (lk_app_model_get_overlay_pin (self->model) != NULL)
    return FALSE;

  g_autofree char *payload = lk_chart_controller_overlay_at (self->controller, x, y);
  if (payload == NULL)
    return FALSE;

  g_autoptr (LkJson) root = lk_json_parse (payload);
  const char *title = lk_json_member_string (root, "title");
  const LkJson *rows = lk_json_member (root, "rows");
  g_autoptr (GString) markup = g_string_new (NULL);

  if (title != NULL)
    {
      g_autofree char *escaped = g_markup_escape_text (title, -1);
      g_string_append_printf (markup, "<b>%s</b>", escaped);
    }
  for (guint i = 0; i < lk_json_length (rows); i++)
    {
      const LkJson *row = lk_json_at (rows, i);
      const char *key = lk_json_text (lk_json_at (row, 0));
      const char *value = lk_json_text (lk_json_at (row, 1));

      if (key[0] == '\0' && value[0] == '\0')
        continue;

      g_autofree char *ekey = g_markup_escape_text (key, -1);
      g_autofree char *evalue = g_markup_escape_text (value, -1);
      if (markup->len > 0)
        g_string_append_c (markup, '\n');
      g_string_append_printf (markup, "<span alpha='55%%'>%s</span>  %s", ekey, evalue);
    }
  if (markup->len == 0)
    return FALSE;

  gtk_tooltip_set_markup (tooltip, markup->str);
  return TRUE;
}

static void
lk_chart_view_init (LkChartView *self)
{
  gtk_widget_set_focusable (GTK_WIDGET (self), TRUE);
  gtk_widget_set_hexpand (GTK_WIDGET (self), TRUE);
  gtk_widget_set_vexpand (GTK_WIDGET (self), TRUE);

  /* The overlay hover tip, through GTK's own tooltip machinery. */
  gtk_widget_set_has_tooltip (GTK_WIDGET (self), TRUE);
  g_signal_connect (self, "query-tooltip",
                    G_CALLBACK (lk_chart_view_query_tooltip), NULL);

  GtkGesture *click = gtk_gesture_click_new ();
  gtk_gesture_single_set_button (GTK_GESTURE_SINGLE (click), GDK_BUTTON_PRIMARY);
  g_signal_connect (click, "pressed", G_CALLBACK (lk_chart_view_pressed), self);
  g_signal_connect (click, "released", G_CALLBACK (lk_chart_view_released), self);
  gtk_widget_add_controller (GTK_WIDGET (self), GTK_EVENT_CONTROLLER (click));

  /* The chart menu, raised at a point on the water. A secondary click is what
     opens it here, as a right-click does on the other desktop shell. */
  GtkGesture *menu = gtk_gesture_click_new ();
  gtk_gesture_single_set_button (GTK_GESTURE_SINGLE (menu), GDK_BUTTON_SECONDARY);
  g_signal_connect (menu, "pressed", G_CALLBACK (lk_chart_view_menu_pressed), self);
  gtk_widget_add_controller (GTK_WIDGET (self), GTK_EVENT_CONTROLLER (menu));

  GtkEventController *motion = gtk_event_controller_motion_new ();
  g_signal_connect (motion, "motion", G_CALLBACK (lk_chart_view_motion), self);
  g_signal_connect (motion, "leave", G_CALLBACK (lk_chart_view_leave), self);
  gtk_widget_add_controller (GTK_WIDGET (self), motion);

  GtkEventController *scroll =
      gtk_event_controller_scroll_new (GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES);
  g_signal_connect (scroll, "scroll", G_CALLBACK (lk_chart_view_scroll), self);
  gtk_widget_add_controller (GTK_WIDGET (self), scroll);

  GtkGesture *zoom = gtk_gesture_zoom_new ();
  g_signal_connect (zoom, "begin", G_CALLBACK (lk_chart_view_zoom_begin), self);
  g_signal_connect (zoom, "scale-changed", G_CALLBACK (lk_chart_view_zoom_changed), self);
  gtk_widget_add_controller (GTK_WIDGET (self), GTK_EVENT_CONTROLLER (zoom));

  GtkGesture *rotate = gtk_gesture_rotate_new ();
  g_signal_connect (rotate, "begin", G_CALLBACK (lk_chart_view_rotate_begin), self);
  g_signal_connect (rotate, "angle-changed", G_CALLBACK (lk_chart_view_rotate_changed), self);
  gtk_widget_add_controller (GTK_WIDGET (self), GTK_EVENT_CONTROLLER (rotate));

  /* Touch is stitched in the capture phase, ahead of the gestures above: a
     resistive panel's stutter would otherwise read as a stream of double taps.
     The handler propagates, so the pinch and rotate gestures still act on two
     fingers. See lk_chart_view_touch. */
  GtkEventController *touch = gtk_event_controller_legacy_new ();
  gtk_event_controller_set_propagation_phase (touch, GTK_PHASE_CAPTURE);
  g_signal_connect (touch, "event", G_CALLBACK (lk_chart_view_touch), self);
  gtk_widget_add_controller (GTK_WIDGET (self), touch);
}

GtkWidget *
lk_chart_view_new (LkAppModel *model)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (model), NULL);

  LkChartView *self = g_object_new (LK_TYPE_CHART_VIEW, NULL);
  self->model = model;
  self->controller = lk_app_model_get_controller (model);
  /* A camera move retires the chrome. The pick report clears through the model,
     and the chart menu closes here — a keyboard zoom or a follow move must not
     leave it standing over water it no longer points at. */
  g_signal_connect_object (model, "chrome-retired",
                           G_CALLBACK (lk_chart_view_chrome_retired), self, 0);
  return GTK_WIDGET (self);
}

LkNativeSurface *
lk_chart_view_get_native_surface (LkChartView *self)
{
  g_return_val_if_fail (LK_IS_CHART_VIEW (self), NULL);
  return self->surface;
}
