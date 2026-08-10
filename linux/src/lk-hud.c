#include "lk-hud.h"

#include <math.h>
#include <string.h>

/* Amber, and only past a threshold: an overscale badge that is always up is
 * just decoration, and this one means "you are magnifying past the survey". */
#define LK_OVERSCALE_VISIBLE_AT 1.05

/* ---- readout formatting ------------------------------------------------- */

/* Degrees, minutes and seconds with a hemisphere. The longitude has three
 * degree digits, so a pair keeps its column width. It agrees with
 * CoordFormat.dm (macOS and iOS), lkw::FormatCoord (Windows) and Hud.kt
 * (Android). Each host prints the same string. */
char *
lk_coord_format_dm (double value, gboolean is_lat)
{
  const char *hemi = is_lat ? (value >= 0 ? "N" : "S") : (value >= 0 ? "E" : "W");
  double magnitude = fabs (value);
  int degrees = (int) magnitude;
  double minutes = (magnitude - degrees) * 60.0;

  /* Carry the rounding. 59.9996' prints as 60.000', the next degree. */
  if (llround (minutes * 1000.0) >= 60000)
    {
      minutes = 0.0;
      degrees++;
    }

  return g_strdup_printf (is_lat ? "%02d°%06.3f'%s" : "%03d°%06.3f'%s",
                          degrees, minutes, hemi);
}

/* The full 1:N with group separators: 1:13,267. The separator is a comma on
 * every shell — the readout is a chart scale, and a mariner reads it the same
 * way whatever the locale sorts numbers by. */
char *
lk_format_scale (double denominator)
{
  if (denominator <= 0)
    return g_strdup ("1:—");

  g_autofree char *plain = g_strdup_printf ("%" G_GINT64_FORMAT, (gint64) llround (denominator));
  gsize length = strlen (plain);
  g_autoptr (GString) grouped = g_string_new ("1:");

  for (gsize i = 0; i < length; i++)
    {
      if (i > 0 && (length - i) % 3 == 0)
        g_string_append_c (grouped, ',');
      g_string_append_c (grouped, plain[i]);
    }

  return g_string_free (g_steal_pointer (&grouped), FALSE);
}

/* The S-52 navigational purpose band for a display scale. It agrees with
 * CoordFormat.band (macOS and iOS), lkw::BandForDenom (Windows) and
 * bandString (Android). */
const char *
lk_format_band (double denominator)
{
  if (denominator < 0.001)     return "—";
  if (denominator < 5000)      return "Berthing";
  if (denominator < 25000)     return "Harbor";
  if (denominator < 75000)     return "Approach";
  if (denominator < 300000)    return "Coastal";
  if (denominator < 1500000)   return "General";
  return "Overview";
}

/* ---- the scale entry ---------------------------------------------------- */

/* One usual scale for each S-52 navigational purpose band. */
static const struct {
  const char *band;
  double      denominator;
  const char *shorthand;
} LK_SCALE_PRESETS[] = {
  { "Berthing",   2000, "1:2k" },
  { "Harbor",    12000, "1:12k" },
  { "Approach",  50000, "1:50k" },
  { "Coastal",  150000, "1:150k" },
  { "General",  700000, "1:700k" },
};

typedef struct {
  LkAppModel *model;
  GtkWidget  *popover;
  GtkWidget  *entry;
  GtkWidget  *hint;
  GtkWidget  *now;
  GtkWidget  *go;
  GtkWidget  *presets[G_N_ELEMENTS (LK_SCALE_PRESETS)];
} LkScaleEntry;

static void
lk_scale_entry_free (gpointer data, GClosure *closure)
{
  g_free (data);
}

/* The band the typed scale belongs to, or how to write a scale. */
static void
lk_scale_entry_refresh (LkScaleEntry *entry)
{
  const char *text = gtk_editable_get_text (GTK_EDITABLE (entry->entry));
  double denominator = 0;
  gboolean valid = lk_scale_parse (text, &denominator);

  gtk_widget_set_sensitive (entry->go, valid);

  if (valid)
    {
      g_autofree char *hint =
          g_strdup_printf ("%s band. The chart holds the nearest scale it has.",
                           lk_format_band (denominator));
      gtk_label_set_text (GTK_LABEL (entry->hint), hint);
    }
  else
    {
      gtk_label_set_text (GTK_LABEL (entry->hint),
                          "Type a scale, for example 25,000 or 1:25k.");
    }
}

static void
lk_scale_entry_changed (GtkEditable *editable, gpointer user_data)
{
  lk_scale_entry_refresh (user_data);
}

static void
lk_scale_entry_submit (LkScaleEntry *entry)
{
  double denominator = 0;

  if (!lk_scale_parse (gtk_editable_get_text (GTK_EDITABLE (entry->entry)), &denominator))
    return;

  lk_app_model_zoom_to_scale (entry->model, denominator);
  gtk_popover_popdown (GTK_POPOVER (entry->popover));
}

static void
lk_scale_entry_activated (GtkEntry *widget, gpointer user_data)
{
  lk_scale_entry_submit (user_data);
}

static void
lk_scale_entry_go_clicked (GtkButton *button, gpointer user_data)
{
  lk_scale_entry_submit (user_data);
}

static void
lk_scale_preset_clicked (GtkButton *button, gpointer user_data)
{
  LkScaleEntry *entry = user_data;
  double denominator = *(double *) g_object_get_data (G_OBJECT (button), "lk-denominator");

  lk_app_model_zoom_to_scale (entry->model, denominator);
  gtk_popover_popdown (GTK_POPOVER (entry->popover));
}

/* Opening the entry seeds it with the scale on show, so a small correction is
 * an edit rather than a retype. */
static void
lk_scale_entry_shown (GtkPopover *popover, gpointer user_data)
{
  LkScaleEntry *entry = user_data;
  double denominator = lk_app_model_get_scale_denominator (entry->model);
  g_autofree char *scale = lk_format_scale (denominator);
  g_autofree char *now = g_strconcat ("now ", scale, NULL);

  if (denominator > 0)
    {
      g_autofree char *seed = g_strdup_printf ("%" G_GINT64_FORMAT, (gint64) llround (denominator));
      gtk_editable_set_text (GTK_EDITABLE (entry->entry), seed);
      gtk_editable_select_region (GTK_EDITABLE (entry->entry), 0, -1);
    }

  /* The band the view is in is marked, so the panel says where the chart
   * stands before it asks where to go. */
  const char *band = lk_format_band (denominator);
  for (gsize i = 0; i < G_N_ELEMENTS (LK_SCALE_PRESETS); i++)
    {
      if (g_str_equal (LK_SCALE_PRESETS[i].band, band))
        gtk_widget_add_css_class (entry->presets[i], "lk-preset-current");
      else
        gtk_widget_remove_css_class (entry->presets[i], "lk-preset-current");
    }

  gtk_label_set_text (GTK_LABEL (entry->now), now);
  lk_scale_entry_refresh (entry);
  gtk_widget_grab_focus (entry->entry);
}

/* Type a scale or pick a band, and the view zooms to it. The twin of
 * ScaleEntryPanel (macOS, iOS) and ScaleEntryDialog (Android). */
static GtkWidget *
lk_scale_entry_popover_new (LkAppModel *model)
{
  LkScaleEntry *entry = g_new0 (LkScaleEntry, 1);
  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, 12);

  entry->model = model;
  entry->popover = gtk_popover_new ();
  gtk_popover_set_child (GTK_POPOVER (entry->popover), box);
  gtk_widget_set_margin_start (box, 6);
  gtk_widget_set_margin_end (box, 6);
  gtk_widget_set_margin_top (box, 6);
  gtk_widget_set_margin_bottom (box, 6);
  gtk_widget_set_size_request (box, 320, -1);

  /* Title, and the scale the view is on now. */
  GtkWidget *header = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
  GtkWidget *title = gtk_label_new ("Zoom to scale");
  gtk_widget_add_css_class (title, "heading");
  gtk_widget_set_hexpand (title, TRUE);
  gtk_label_set_xalign (GTK_LABEL (title), 0);
  entry->now = gtk_label_new ("");
  gtk_widget_add_css_class (entry->now, "dim-label");
  gtk_widget_add_css_class (entry->now, "caption");
  gtk_box_append (GTK_BOX (header), title);
  gtk_box_append (GTK_BOX (header), entry->now);
  gtk_box_append (GTK_BOX (box), header);

  /* The entry, prefixed with the 1: a scale is always written with. */
  GtkWidget *row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
  entry->entry = gtk_entry_new ();
  gtk_entry_set_placeholder_text (GTK_ENTRY (entry->entry), "25,000");
  gtk_entry_set_input_purpose (GTK_ENTRY (entry->entry), GTK_INPUT_PURPOSE_DIGITS);
  gtk_entry_set_activates_default (GTK_ENTRY (entry->entry), FALSE);
  gtk_widget_set_hexpand (entry->entry, TRUE);

  GtkWidget *prefix = gtk_label_new ("1:");
  gtk_widget_add_css_class (prefix, "dim-label");
  entry->go = gtk_button_new_with_label ("Go");
  gtk_widget_add_css_class (entry->go, "suggested-action");

  gtk_box_append (GTK_BOX (row), prefix);
  gtk_box_append (GTK_BOX (row), entry->entry);
  gtk_box_append (GTK_BOX (row), entry->go);
  gtk_box_append (GTK_BOX (box), row);

  entry->hint = gtk_label_new ("");
  gtk_widget_add_css_class (entry->hint, "caption");
  gtk_widget_add_css_class (entry->hint, "dim-label");
  gtk_label_set_xalign (GTK_LABEL (entry->hint), 0);
  gtk_label_set_wrap (GTK_LABEL (entry->hint), TRUE);
  gtk_box_append (GTK_BOX (box), entry->hint);

  gtk_box_append (GTK_BOX (box), gtk_separator_new (GTK_ORIENTATION_HORIZONTAL));

  /* The bands, so a mariner picks a purpose instead of a number. */
  GtkWidget *presets = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 6);
  gtk_box_set_homogeneous (GTK_BOX (presets), TRUE);
  for (gsize i = 0; i < G_N_ELEMENTS (LK_SCALE_PRESETS); i++)
    {
      GtkWidget *stack = gtk_box_new (GTK_ORIENTATION_VERTICAL, 2);
      GtkWidget *band = gtk_label_new (LK_SCALE_PRESETS[i].band);
      GtkWidget *shorthand = gtk_label_new (LK_SCALE_PRESETS[i].shorthand);
      GtkWidget *button = gtk_button_new ();
      double *denominator = g_new (double, 1);

      gtk_widget_add_css_class (band, "caption-heading");
      gtk_widget_add_css_class (shorthand, "caption");
      gtk_widget_add_css_class (shorthand, "dim-label");
      gtk_box_append (GTK_BOX (stack), band);
      gtk_box_append (GTK_BOX (stack), shorthand);

      gtk_button_set_child (GTK_BUTTON (button), stack);
      gtk_widget_add_css_class (button, "flat");
      gtk_widget_set_tooltip_text (button, LK_SCALE_PRESETS[i].shorthand);

      *denominator = LK_SCALE_PRESETS[i].denominator;
      g_object_set_data_full (G_OBJECT (button), "lk-denominator", denominator, g_free);
      g_signal_connect (button, "clicked", G_CALLBACK (lk_scale_preset_clicked), entry);
      gtk_box_append (GTK_BOX (presets), button);
      entry->presets[i] = button;
    }
  gtk_box_append (GTK_BOX (box), presets);

  g_signal_connect (entry->entry, "changed", G_CALLBACK (lk_scale_entry_changed), entry);
  g_signal_connect (entry->entry, "activate", G_CALLBACK (lk_scale_entry_activated), entry);
  g_signal_connect (entry->go, "clicked", G_CALLBACK (lk_scale_entry_go_clicked), entry);
  g_signal_connect_data (entry->popover, "show", G_CALLBACK (lk_scale_entry_shown),
                         entry, lk_scale_entry_free, 0);

  return entry->popover;
}

/* ---- the readouts capsule ----------------------------------------------- */

typedef struct {
  LkAppModel *model;
  GtkWidget  *root;
  GtkWidget  *band;
  GtkWidget  *band_rule;
  GtkWidget  *scale;
  GtkWidget  *zoom;
  GtkWidget  *fix_pill;  /* the button that says whether to believe the position */
  GtkWidget  *fix_icon;
  GtkWidget  *fix_label;
  GtkWidget  *coord;
  GtkWidget  *overscale;
} LkHudCapsule;

static void
lk_hud_capsule_free (gpointer data, GClosure *closure)
{
  g_free (data);
}

/* OWN SHIP's position, and a pill saying how much to believe it.
 *
 * The readout carries own ship and nothing else. It does not follow the view
 * centre and it does not change meaning when the mariner pans away, because
 * panning away is exactly when a mistaken value is dangerous. With no fix it
 * shows NO NUMBERS: a coordinate with no boat behind it is the ambiguity this
 * removes. The coordinates of a PLACE come from the chart menu, on demand, at
 * the point the mariner asked about.
 *
 * The pill differs by more than its words, so it reads at a glance in bad
 * light: the colour changes, the icon changes, and the third state carries the
 * fix-it, because it is the one place the app tells a mariner they have no
 * position at all. */
static void
lk_hud_update_coord (LkHudCapsule *capsule)
{
  static const struct {
    const char *icon, *text, *css, *tooltip;
  } pill[] = {
    { "preferences-system-symbolic", "Configure GPS", "lk-fix-none",
      "No source of position. Add a gateway or a Signal K server." },
    { "network-offline-symbolic", "NO GPS", "lk-fix-lost",
      "The position source stopped answering. Opens the settings." },
    { "find-location-symbolic", "GPS", "lk-fix-live",
      "Own ship's reported position. Opens the settings." },
  };

  int state = lk_app_model_get_fix_state (capsule->model);
  double lon = 0, lat = 0;

  gtk_image_set_from_icon_name (GTK_IMAGE (capsule->fix_icon), pill[state].icon);
  gtk_label_set_text (GTK_LABEL (capsule->fix_label), pill[state].text);
  gtk_widget_set_tooltip_text (capsule->fix_pill, pill[state].tooltip);

  for (gsize i = 0; i < G_N_ELEMENTS (pill); i++)
    gtk_widget_remove_css_class (capsule->fix_pill, pill[i].css);
  gtk_widget_add_css_class (capsule->fix_pill, pill[state].css);

  if (lk_app_model_get_fix (capsule->model, &lon, &lat))
    {
      g_autofree char *lat_s = lk_coord_format_dm (lat, TRUE);
      g_autofree char *lon_s = lk_coord_format_dm (lon, FALSE);
      g_autofree char *text = g_strdup_printf ("%s %s", lat_s, lon_s);

      gtk_label_set_text (GTK_LABEL (capsule->coord), text);
      gtk_widget_set_visible (capsule->coord, TRUE);
      return;
    }

  gtk_widget_set_visible (capsule->coord, FALSE);
}

static void
lk_hud_update_scale (LkHudCapsule *capsule)
{
  double denominator = lk_app_model_get_scale_denominator (capsule->model);
  g_autofree char *text = lk_format_scale (denominator);

  gtk_label_set_text (GTK_LABEL (capsule->scale), text);
  gtk_label_set_text (GTK_LABEL (capsule->band), lk_format_band (denominator));
}

static void
lk_hud_update_zoom (LkHudCapsule *capsule)
{
  g_autofree char *text = g_strdup_printf ("z%.1f", lk_app_model_get_zoom (capsule->model));

  gtk_label_set_text (GTK_LABEL (capsule->zoom), text);
}

static void
lk_hud_update_overscale (LkHudCapsule *capsule)
{
  double overscale = lk_app_model_get_overscale (capsule->model);
  gboolean show = overscale > LK_OVERSCALE_VISIBLE_AT;

  gtk_widget_set_visible (capsule->overscale, show);
  if (show)
    {
      g_autofree char *text = g_strdup_printf ("×%.1f", overscale);
      gtk_label_set_text (GTK_LABEL (capsule->overscale), text);
    }
}

/* A narrow window drops the band and takes a smaller type. The position, the
 * scale and the zoom stay: they are what a mariner is reading. */
static void
lk_hud_update_compact (LkHudCapsule *capsule)
{
  gboolean compact = lk_app_model_get_view_width (capsule->model) < LK_CHROME_COMPACT_WIDTH;

  gtk_widget_set_visible (capsule->band, !compact);
  gtk_widget_set_visible (capsule->band_rule, !compact);

  if (compact)
    gtk_widget_add_css_class (capsule->root, "lk-compact");
  else
    gtk_widget_remove_css_class (capsule->root, "lk-compact");
}

static void
lk_hud_capsule_notify (GObject *object, GParamSpec *pspec, gpointer user_data)
{
  LkHudCapsule *capsule = user_data;
  const char *name = g_param_spec_get_name (pspec);

  if (g_str_equal (name, "fix-state") || g_str_equal (name, "fix-lon") ||
      g_str_equal (name, "fix-lat"))
    lk_hud_update_coord (capsule);
  else if (g_str_equal (name, "scale-denominator"))
    lk_hud_update_scale (capsule);
  else if (g_str_equal (name, "zoom"))
    lk_hud_update_zoom (capsule);
  else if (g_str_equal (name, "overscale"))
    lk_hud_update_overscale (capsule);
  else if (g_str_equal (name, "view-width"))
    lk_hud_update_compact (capsule);
}

static GtkWidget *
lk_hud_rule (void)
{
  GtkWidget *rule = gtk_separator_new (GTK_ORIENTATION_VERTICAL);

  gtk_widget_set_size_request (rule, 1, 20);
  gtk_widget_set_valign (rule, GTK_ALIGN_CENTER);
  return rule;
}

GtkWidget *
lk_hud_capsule_new (LkAppModel *model)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (model), NULL);

  LkHudCapsule *capsule = g_new0 (LkHudCapsule, 1);
  capsule->model = model;

  GtkWidget *root = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 12);
  capsule->root = root;
  gtk_widget_add_css_class (root, "lk-capsule");
  gtk_widget_set_size_request (root, -1, LK_CHROME_CAPSULE);
  /* The capsule is a control surface, so it takes the presses that land on it
   * — as the WinUI pill and the Compose surface do. It is small and it sits at
   * the bottom centre; the chart keeps everything around it. */
  gtk_widget_set_halign (root, GTK_ALIGN_CENTER);
  gtk_widget_set_valign (root, GTK_ALIGN_END);

  /* The amber dot every shell leads the capsule with. It is CSS, not a
   * drawing: a 10pt circle of one colour is what a stylesheet is for. */
  GtkWidget *dot = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 0);
  gtk_widget_set_size_request (dot, 10, 10);
  gtk_widget_set_valign (dot, GTK_ALIGN_CENTER);
  gtk_widget_add_css_class (dot, "lk-amber-dot");
  gtk_box_append (GTK_BOX (root), dot);

  /* The band is the first thing a mariner reads, and the first thing a narrow
   * window gives up. */
  capsule->band = gtk_label_new ("");
  gtk_widget_add_css_class (capsule->band, "heading");
  gtk_box_append (GTK_BOX (root), capsule->band);

  capsule->band_rule = lk_hud_rule ();
  gtk_box_append (GTK_BOX (root), capsule->band_rule);

  /* The 1:N is the capsule's one control: it opens the scale entry. */
  capsule->scale = gtk_label_new ("");
  gtk_widget_add_css_class (capsule->scale, "heading");
  gtk_widget_add_css_class (capsule->scale, "lk-accent");

  GtkWidget *scale_button = gtk_menu_button_new ();
  gtk_menu_button_set_child (GTK_MENU_BUTTON (scale_button), capsule->scale);
  gtk_menu_button_set_popover (GTK_MENU_BUTTON (scale_button),
                               lk_scale_entry_popover_new (model));
  gtk_menu_button_set_direction (GTK_MENU_BUTTON (scale_button), GTK_ARROW_UP);
  gtk_widget_add_css_class (scale_button, "flat");
  gtk_widget_add_css_class (scale_button, "lk-scale-button");
  gtk_widget_set_tooltip_text (scale_button, "Zoom to a scale…");
  gtk_box_append (GTK_BOX (root), scale_button);

  gtk_box_append (GTK_BOX (root), lk_hud_rule ());

  capsule->zoom = gtk_label_new ("");
  gtk_widget_add_css_class (capsule->zoom, "dim-label");
  gtk_box_append (GTK_BOX (root), capsule->zoom);

  gtk_box_append (GTK_BOX (root), lk_hud_rule ());

  /* The position source, beside the position it qualifies. It is a button in
   * every state, and it opens the settings, where the connections are. */
  GtkWidget *pill_row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 5);
  capsule->fix_icon = gtk_image_new ();
  capsule->fix_label = gtk_label_new ("");
  gtk_image_set_pixel_size (GTK_IMAGE (capsule->fix_icon), 11);
  gtk_widget_add_css_class (capsule->fix_label, "caption-heading");
  gtk_box_append (GTK_BOX (pill_row), capsule->fix_icon);
  gtk_box_append (GTK_BOX (pill_row), capsule->fix_label);

  capsule->fix_pill = gtk_button_new ();
  gtk_button_set_child (GTK_BUTTON (capsule->fix_pill), pill_row);
  gtk_widget_add_css_class (capsule->fix_pill, "lk-fix-pill");
  gtk_widget_set_valign (capsule->fix_pill, GTK_ALIGN_CENTER);
  /* A fix-it names the section that fixes it: a position source is added
   * under Connections, so that is where this opens. */
  gtk_actionable_set_detailed_action_name (GTK_ACTIONABLE (capsule->fix_pill),
                                          "win.settings-at::connections");
  gtk_box_append (GTK_BOX (root), capsule->fix_pill);

  capsule->coord = gtk_label_new ("");
  gtk_widget_add_css_class (capsule->coord, "monospace");
  gtk_label_set_selectable (GTK_LABEL (capsule->coord), TRUE);
  gtk_box_append (GTK_BOX (root), capsule->coord);

  capsule->overscale = gtk_label_new ("");
  gtk_widget_add_css_class (capsule->overscale, "lk-overscale");
  gtk_widget_set_valign (capsule->overscale, GTK_ALIGN_CENTER);
  gtk_widget_set_visible (capsule->overscale, FALSE);
  gtk_box_append (GTK_BOX (root), capsule->overscale);

  /* The raster chart pill closes the capsule. It hides itself where no raster
   * chart is in view, which is most water. */
  gtk_box_append (GTK_BOX (root), lk_raster_pill_new (model));

  g_signal_connect_data (model, "notify", G_CALLBACK (lk_hud_capsule_notify), capsule,
                         lk_hud_capsule_free, 0);

  lk_hud_update_coord (capsule);
  lk_hud_update_scale (capsule);
  lk_hud_update_zoom (capsule);
  lk_hud_update_overscale (capsule);
  lk_hud_update_compact (capsule);
  return root;
}

/* ---- the raster chart pill ---------------------------------------------- */

/* It names the raster chart set drawn over this view and opens the list of what
 * covers it.
 *
 * The COLOUR reports the raster chart, not the ENC: the accent while the
 * picture is drawn, amber while one is here and off. Hiding the ENC above it
 * does not change the colour, because the picture is still drawn — the "ENC
 * OFF" text carries that, and a warning colour there would say the picture was
 * off when it is the only thing on the screen. */
typedef struct {
  LkAppModel *model;
  GtkWidget  *root;   /* the rule and the pill, which appear together */
  GtkWidget  *button;
  GtkWidget  *name;
  GtkWidget  *bar;    /* the rule between the name and the state */
  GtkWidget  *state;
} LkRasterPill;

static void
lk_raster_pill_free (gpointer data, GClosure *closure)
{
  g_free (data);
}

/* The set the pill NAMES: the drawn one when it is in view, else the first one
 * that is. Naming one set and reporting the state of another is how a pill
 * comes to read "NAVIONICS | OFF" while Navionics is drawn. */
static const LkRasterSet *
lk_raster_pill_named_set (LkRasterPill *pill, guint *out_visible)
{
  GPtrArray *sets = lk_app_model_get_raster_sets (pill->model);
  int active = lk_app_model_get_raster_active (pill->model);
  const LkRasterSet *named = NULL;
  guint visible = 0;

  for (guint i = 0; i < sets->len; i++)
    {
      const LkRasterSet *set = g_ptr_array_index (sets, i);

      if (!set->in_view)
        continue;
      visible++;
      if (named == NULL || set->id == active)
        named = set;
    }

  if (out_visible != NULL)
    *out_visible = visible;
  return named;
}

static void
lk_raster_pill_update (LkRasterPill *pill)
{
  guint visible = 0;
  const LkRasterSet *named = lk_raster_pill_named_set (pill, &visible);

  gtk_widget_set_visible (pill->root, named != NULL);
  if (named == NULL)
    return;

  gboolean drawn = named->id == lk_app_model_get_raster_active (pill->model);
  gboolean hidden = lk_app_model_get_chart_hidden (pill->model);

  g_autofree char *upper = g_utf8_strup (named->name, -1);
  gtk_label_set_text (GTK_LABEL (pill->name), upper);

  gtk_widget_set_visible (pill->bar, !drawn || hidden);
  gtk_widget_set_visible (pill->state, !drawn || hidden);
  gtk_label_set_text (GTK_LABEL (pill->state), drawn ? "ENC OFF" : "OFF");

  if (drawn)
    gtk_widget_remove_css_class (pill->button, "lk-off");
  else
    gtk_widget_add_css_class (pill->button, "lk-off");

  const char *what = drawn ? (hidden ? "%s, with the ENC hidden above it. Click to choose another."
                                     : "%s below the ENC. Click to choose another.")
                           : "%s is here but off. Click to choose it.";
  g_autofree char *help = g_strdup_printf (what, named->name);
  g_autofree char *tooltip =
      visible > 1 ? g_strdup_printf ("%s %u raster charts cover this view.", help, visible)
                  : g_strdup (help);
  gtk_widget_set_tooltip_text (pill->button, tooltip);
}

static void
lk_raster_pill_changed (LkAppModel *model, gpointer user_data)
{
  lk_raster_pill_update (user_data);
}

/* The list the pill opens: every set covering this view, the drawn one marked,
 * then None, the ENC switch and the picker. It is rebuilt on each press, so
 * what it offers is what the view has under it now. */
static void
lk_raster_pill_build_menu (GtkMenuButton *button, gpointer user_data)
{
  LkRasterPill *pill = user_data;
  GPtrArray *sets = lk_app_model_get_raster_sets (pill->model);
  g_autoptr (GMenu) menu = g_menu_new ();
  g_autoptr (GMenu) choices = g_menu_new ();
  g_autoptr (GMenu) commands = g_menu_new ();

  for (guint i = 0; i < sets->len; i++)
    {
      const LkRasterSet *set = g_ptr_array_index (sets, i);

      if (!set->in_view)
        continue;

      g_autoptr (GMenuItem) item = g_menu_item_new (set->name, NULL);
      g_menu_item_set_action_and_target_value (item, "win.raster-select",
                                               g_variant_new_int32 (set->id));
      g_menu_append_item (choices, item);
    }

  g_autoptr (GMenuItem) none = g_menu_item_new ("None", NULL);
  g_menu_item_set_action_and_target_value (none, "win.raster-select",
                                           g_variant_new_int32 (-1));
  g_menu_append_item (choices, none);

  g_menu_append (commands,
                 lk_app_model_get_chart_hidden (pill->model) ? "Show ENC Over Raster"
                                                             : "Hide ENC Over Raster",
                 "win.toggle-chart");
  g_menu_append (commands, "Add Raster Charts…", "win.raster-add");

  g_menu_append_section (menu, NULL, G_MENU_MODEL (choices));
  g_menu_append_section (menu, NULL, G_MENU_MODEL (commands));
  gtk_menu_button_set_menu_model (button, G_MENU_MODEL (menu));
}

GtkWidget *
lk_raster_pill_new (LkAppModel *model)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (model), NULL);

  LkRasterPill *pill = g_new0 (LkRasterPill, 1);
  pill->model = model;

  GtkWidget *content = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 5);
  pill->name = gtk_label_new ("");
  pill->bar = gtk_label_new ("|");
  pill->state = gtk_label_new ("");

  gtk_widget_add_css_class (pill->bar, "lk-raster-bar");
  gtk_box_append (GTK_BOX (content), pill->name);
  gtk_box_append (GTK_BOX (content), pill->bar);
  gtk_box_append (GTK_BOX (content), pill->state);

  /* The chevron is a promise: a press opens a list. It is therefore always
   * shown, because a press always does. */
  GtkWidget *chevron = gtk_image_new_from_icon_name ("pan-down-symbolic");
  gtk_image_set_pixel_size (GTK_IMAGE (chevron), 12);
  gtk_box_append (GTK_BOX (content), chevron);

  pill->button = gtk_menu_button_new ();
  gtk_menu_button_set_child (GTK_MENU_BUTTON (pill->button), content);
  gtk_menu_button_set_direction (GTK_MENU_BUTTON (pill->button), GTK_ARROW_UP);
  gtk_menu_button_set_create_popup_func (GTK_MENU_BUTTON (pill->button),
                                         lk_raster_pill_build_menu, pill, NULL);
  gtk_widget_add_css_class (pill->button, "lk-raster-pill");

  pill->root = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 12);
  gtk_box_append (GTK_BOX (pill->root), lk_hud_rule ());
  gtk_box_append (GTK_BOX (pill->root), pill->button);

  g_signal_connect_data (model, "raster-changed", G_CALLBACK (lk_raster_pill_changed),
                         pill, lk_raster_pill_free, 0);
  lk_raster_pill_update (pill);
  return pill->root;
}

/* ---- the distance bar --------------------------------------------------- */

/* Ground metres per logical point at a 1:1 display scale, from the standard
 * 0.28 mm pixel the engine's denominator is defined against. */
#define LK_METRES_PER_POINT_AT_1_TO_1 0.00028

/* The bar is this wide or less; the distance rounds down to a round number, so
 * the label always reads as one. */
#define LK_SCALE_BAR_TARGET 140.0

static const double LK_NICE_DISTANCES[] = {
  10, 20, 50, 100, 200, 500, 1000, 2000, 5000,
  10000, 20000, 50000, 100000, 200000, 500000,
};

typedef struct {
  LkAppModel *model;
  GtkWidget  *root;
  GtkWidget  *label;
  GtkWidget  *bar;
} LkScaleBar;

static void
lk_scale_bar_free (gpointer data, GClosure *closure)
{
  g_free (data);
}

/* Four alternating segments in a hairline box. The chart under it can be light
 * or dark, so the segments alternate the label's own colour with its inverse
 * and the box is drawn in the label's colour. */
static void
lk_scale_bar_draw (GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer data)
{
  GdkRGBA ink;
  gtk_widget_get_color (GTK_WIDGET (area), &ink);
  gboolean dark_ink = (ink.red + ink.green + ink.blue) / 3.0 < 0.5;

  for (int i = 0; i < 4; i++)
    {
      double x = width * i / 4.0;
      double w = width / 4.0;

      if (i % 2 == 0)
        gdk_cairo_set_source_rgba (cr, &ink);
      else if (dark_ink)
        cairo_set_source_rgba (cr, 1, 1, 1, 0.92);
      else
        cairo_set_source_rgba (cr, 0, 0, 0, 0.75);

      cairo_rectangle (cr, x, 0, w, height);
      cairo_fill (cr);
    }

  gdk_cairo_set_source_rgba (cr, &ink);
  cairo_set_line_width (cr, 1);
  cairo_rectangle (cr, 0.5, 0.5, width - 1, height - 1);
  cairo_stroke (cr);
}

static void
lk_scale_bar_update (LkScaleBar *bar)
{
  double denominator = lk_app_model_get_scale_denominator (bar->model);

  if (denominator <= 0)
    {
      gtk_widget_set_visible (bar->root, FALSE);
      return;
    }

  double metres_per_point = denominator * LK_METRES_PER_POINT_AT_1_TO_1;
  double target = LK_SCALE_BAR_TARGET * metres_per_point;
  double metres = LK_NICE_DISTANCES[0];

  for (gsize i = 0; i < G_N_ELEMENTS (LK_NICE_DISTANCES); i++)
    {
      if (LK_NICE_DISTANCES[i] <= target)
        metres = LK_NICE_DISTANCES[i];
    }

  /* Every nice number of 1000 or more is a whole number of kilometres. */
  g_autofree char *label = metres >= 1000
                               ? g_strdup_printf ("%d km", (int) (metres / 1000))
                               : g_strdup_printf ("%d m", (int) metres);

  gtk_label_set_text (GTK_LABEL (bar->label), label);
  gtk_widget_set_size_request (bar->bar, (int) round (metres / metres_per_point), 6);
  gtk_widget_set_visible (bar->root, TRUE);
}

static void
lk_scale_bar_notify (GObject *object, GParamSpec *pspec, gpointer user_data)
{
  if (g_str_equal (g_param_spec_get_name (pspec), "scale-denominator") ||
      g_str_equal (g_param_spec_get_name (pspec), "has-chart"))
    lk_scale_bar_update (user_data);
}

GtkWidget *
lk_scale_bar_new (LkAppModel *model)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (model), NULL);

  LkScaleBar *bar = g_new0 (LkScaleBar, 1);
  bar->model = model;
  bar->root = gtk_box_new (GTK_ORIENTATION_VERTICAL, 3);
  bar->label = gtk_label_new ("");
  bar->bar = gtk_drawing_area_new ();

  gtk_widget_add_css_class (bar->label, "lk-scale-bar-label");
  gtk_label_set_xalign (GTK_LABEL (bar->label), 0);
  gtk_drawing_area_set_draw_func (GTK_DRAWING_AREA (bar->bar), lk_scale_bar_draw, NULL, NULL);
  gtk_widget_set_halign (bar->bar, GTK_ALIGN_START);

  gtk_box_append (GTK_BOX (bar->root), bar->label);
  gtk_box_append (GTK_BOX (bar->root), bar->bar);

  /* A drawing, not a control: a drag that starts on it is a drag on the chart. */
  gtk_widget_set_can_target (bar->root, FALSE);
  gtk_widget_set_halign (bar->root, GTK_ALIGN_START);
  gtk_widget_set_valign (bar->root, GTK_ALIGN_END);

  g_signal_connect_data (model, "notify", G_CALLBACK (lk_scale_bar_notify), bar,
                         lk_scale_bar_free, 0);
  lk_scale_bar_update (bar);
  return bar->root;
}

/* ---- the build indicator ------------------------------------------------ */

static void
lk_building_notify (GObject *object, GParamSpec *pspec, gpointer user_data)
{
  if (g_str_equal (g_param_spec_get_name (pspec), "building"))
    gtk_widget_set_visible (user_data, lk_app_model_get_building (LK_APP_MODEL (object)));
}

GtkWidget *
lk_building_pill_new (LkAppModel *model)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (model), NULL);

  GtkWidget *pill = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
  GtkWidget *spinner = gtk_spinner_new ();
  GtkWidget *label = gtk_label_new ("Building chart…");

  gtk_spinner_start (GTK_SPINNER (spinner));
  gtk_widget_add_css_class (label, "caption");
  gtk_box_append (GTK_BOX (pill), spinner);
  gtk_box_append (GTK_BOX (pill), label);

  gtk_widget_add_css_class (pill, "lk-pill");
  gtk_widget_set_halign (pill, GTK_ALIGN_CENTER);
  gtk_widget_set_valign (pill, GTK_ALIGN_START);
  gtk_widget_set_can_target (pill, FALSE);
  gtk_widget_set_visible (pill, lk_app_model_get_building (model));

  g_signal_connect (model, "notify", G_CALLBACK (lk_building_notify), pill);
  return pill;
}

/* ---- the bubbles -------------------------------------------------------- */

GtkWidget *
lk_bubble_new (const char *icon_name, const char *tooltip, const char *action)
{
  GtkWidget *button = gtk_button_new_from_icon_name (icon_name);

  gtk_widget_add_css_class (button, "lk-bubble");
  gtk_widget_set_tooltip_text (button, tooltip);
  if (action != NULL)
    gtk_actionable_set_action_name (GTK_ACTIONABLE (button), action);
  return button;
}

GtkWidget *
lk_bubble_menu_new (const char *icon_name, const char *tooltip, GMenuModel *menu)
{
  GtkWidget *button = gtk_menu_button_new ();

  gtk_menu_button_set_icon_name (GTK_MENU_BUTTON (button), icon_name);
  gtk_menu_button_set_menu_model (GTK_MENU_BUTTON (button), menu);
  gtk_menu_button_set_direction (GTK_MENU_BUTTON (button), GTK_ARROW_UP);
  gtk_widget_add_css_class (button, "lk-bubble");
  gtk_widget_set_tooltip_text (button, tooltip);
  return button;
}

GtkWidget *
lk_zoom_controls_new (LkAppModel *model)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (model), NULL);

  GtkWidget *box = gtk_box_new (GTK_ORIENTATION_VERTICAL, LK_CHROME_GAP);

  gtk_box_append (GTK_BOX (box), lk_bubble_new ("zoom-fit-best-symbolic", "Fit chart", "win.zoom-fit"));
  gtk_box_append (GTK_BOX (box), lk_bubble_new ("zoom-in-symbolic", "Zoom in", "win.zoom-in"));
  gtk_box_append (GTK_BOX (box), lk_bubble_new ("zoom-out-symbolic", "Zoom out", "win.zoom-out"));

  gtk_widget_set_halign (box, GTK_ALIGN_END);
  gtk_widget_set_valign (box, GTK_ALIGN_END);
  return box;
}

/* ---- the compass bubble ------------------------------------------------- */

/* A red pointer over the letter, the pair turned by -rotation so the pointer
 * keeps pointing true north.
 *
 * The LETTER names what is up. Under N the mark turns with the view and points
 * at north. Under C the course is up by definition, so the mark stands still. */
static void
lk_north_draw (GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer user_data)
{
  LkAppModel *model = user_data;
  LkOrientation orientation = lk_app_model_get_orientation (model);
  gboolean course_up = orientation == LK_ORIENT_COURSE_UP;
  double rotation = course_up ? 0.0 : lk_app_model_get_rotation (model) * G_PI / 180.0;
  GdkRGBA ink;

  /* The colour comes off the widget, so the CSS class the lock applies carries
   * both the letter and the pointer with it. */
  gtk_widget_get_color (GTK_WIDGET (area), &ink);

  cairo_save (cr);
  cairo_translate (cr, width / 2.0, height / 2.0);
  cairo_rotate (cr, -rotation);

  /* The pointer. It is red while the chart is the mariner's to move, and takes
   * the bubble's own ink once the lock fills the bubble: red on the accent fill
   * is a colour pair nobody can read. */
  cairo_move_to (cr, 0, -11);
  cairo_line_to (cr, 5, -3);
  cairo_line_to (cr, -5, -3);
  cairo_close_path (cr);
  if (orientation == LK_ORIENT_NORTH_UP || orientation == LK_ORIENT_COURSE_UP)
    gdk_cairo_set_source_rgba (cr, &ink);
  else
    cairo_set_source_rgb (cr, 0.898, 0.224, 0.208); /* #E53935 */
  cairo_fill (cr);

  /* The letter, in the interface font. A layout built from the cairo context
   * carries no family, so it falls back to the fontconfig default rather than
   * the font the rest of the chrome uses; the widget's own context carries the
   * theme font and the display's scale. Semibold, as in Chrome.swift and
   * Chrome.kt. */
  g_autoptr (PangoLayout) layout =
      gtk_widget_create_pango_layout (GTK_WIDGET (area), course_up ? "C" : "N");
  g_autoptr (PangoFontDescription) font = pango_font_description_copy (
      pango_context_get_font_description (gtk_widget_get_pango_context (GTK_WIDGET (area))));
  int text_width = 0, text_height = 0;

  pango_font_description_set_weight (font, PANGO_WEIGHT_SEMIBOLD);
  pango_layout_set_font_description (layout, font);
  pango_layout_get_pixel_size (layout, &text_width, &text_height);

  gdk_cairo_set_source_rgba (cr, &ink);
  cairo_move_to (cr, -text_width / 2.0, -1);
  pango_cairo_show_layout (cr, layout);
  cairo_restore (cr);
}

/* The lock, as style classes on the bubble. Armed is a ring: follow is on and
 * nothing is being followed yet. Locked is a fill. */
static void
lk_north_apply_orientation (GtkWidget *button, LkOrientation orientation)
{
  static const char *help[] = {
    "Follow own ship",
    "Following own ship, waiting for a fix",
    "Following own ship, north up. Click for course up",
    "Following own ship, course up. Click for north up",
  };

  gtk_widget_remove_css_class (button, "lk-mode-armed");
  gtk_widget_remove_css_class (button, "lk-mode-on");

  if (orientation == LK_ORIENT_ARMED)
    gtk_widget_add_css_class (button, "lk-mode-armed");
  else if (orientation != LK_ORIENT_UNLOCKED)
    gtk_widget_add_css_class (button, "lk-mode-on");

  gtk_widget_set_tooltip_text (button, help[orientation]);
}

static void
lk_north_notify (GObject *object, GParamSpec *pspec, gpointer user_data)
{
  LkAppModel *model = LK_APP_MODEL (object);
  GtkWidget *button = user_data;
  const char *name = g_param_spec_get_name (pspec);

  if (g_str_equal (name, "rotation"))
    {
      gtk_widget_queue_draw (gtk_button_get_child (GTK_BUTTON (button)));
      return;
    }

  /* Follow and course up are read off the engine on every readout push, so the
   * bubble answers a pan that cancelled follow as well as its own click. */
  if (g_str_equal (name, "follow") || g_str_equal (name, "course-up"))
    {
      lk_north_apply_orientation (button, lk_app_model_get_orientation (model));
      gtk_widget_queue_draw (gtk_button_get_child (GTK_BUTTON (button)));
    }
}

static void
lk_north_clicked (GtkButton *button, gpointer user_data)
{
  lk_app_model_cycle_orientation (user_data);
}

GtkWidget *
lk_north_bubble_new (LkAppModel *model)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (model), NULL);

  GtkWidget *button = gtk_button_new ();
  GtkWidget *area = gtk_drawing_area_new ();

  gtk_widget_set_size_request (area, 26, 26);
  gtk_drawing_area_set_draw_func (GTK_DRAWING_AREA (area), lk_north_draw, model, NULL);
  gtk_button_set_child (GTK_BUTTON (button), area);

  gtk_widget_add_css_class (button, "lk-bubble");
  /* The compass IS the follow lock, as on the other shells: a click always
   * locks the chart to own ship, and once locked it cycles north up and course
   * up. Ctrl+Up still snaps the chart back to north-up on its own. */
  g_signal_connect (button, "clicked", G_CALLBACK (lk_north_clicked), model);
  lk_north_apply_orientation (button, lk_app_model_get_orientation (model));
  gtk_widget_set_halign (button, GTK_ALIGN_END);
  gtk_widget_set_valign (button, GTK_ALIGN_START);

  g_signal_connect_object (model, "notify", G_CALLBACK (lk_north_notify), button, 0);
  return button;
}
