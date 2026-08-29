#include "lk-alerts.h"

#include "lk-hud.h"
#include "lk-json.h"

#include <math.h>
#include <string.h>

/* How often the set is read. The plugins raise alerts at their status cadence,
 * which is a second, so this is the same. The watch runs whenever a plugin
 * layer is up, and no faster than that: a collision alarm must not wait for the
 * mariner to touch anything, and a chart with no plugins can raise nothing, so
 * it costs nothing there. */
#define LK_ALERT_POLL_MS 1000

/* How often an unacknowledged alarm sounds again. Once a second is right on a
 * boat and unusable at a desk. Ten seconds cannot be mistaken for a one-off
 * chime, and it leaves room to speak on the radio between soundings. */
#define LK_SIREN_REPEAT_MS 10000

/* How many alerts the strip shows. It must not cover the water the mariner is
 * reading, least of all during a collision alarm, when the target it names is
 * on the chart underneath. The rest are counted on the last line and take their
 * turn as the ones above are answered. */
#define LK_ALERT_MAX_VISIBLE 2

/* The body label's cap, which is what bounds the strip. GTK sizes a box to its
 * children, so the width is stated where the long text is. */
#define LK_ALERT_MAX_CHARS 48

typedef enum {
  LK_ALERT_NOTICE,
  LK_ALERT_WARNING,
  LK_ALERT_ALARM,
} LkAlertSeverity;

typedef struct {
  guint64         id;
  LkAlertSeverity severity;
  char           *title;
  char           *body;
  gboolean        acknowledged;
} LkAlert;

typedef struct {
  LkAppModel *model;
  GtkWidget  *panel; /* the strip itself; the rows are rebuilt into it */
  GPtrArray  *alerts;

  guint  poll_id;
  gint64 seq; /* the batch on screen; -1 forces the next read to rebuild */

  /* The siren. `stream` is made on the first sounding and kept, because
   * building it per strike would cost latency an alarm cannot spend. */
  guint          siren_id;
  gboolean       siren_on;
  GtkMediaStream *stream;
} LkAlerts;

static gboolean lk_alerts_poll (gpointer user_data);

static void
lk_alert_free (LkAlert *alert)
{
  if (alert == NULL)
    return;
  g_free (alert->title);
  g_free (alert->body);
  g_free (alert);
}

/* ---- the tone ------------------------------------------------------------ */

/* One second of urgency: six pulses alternating between two pitches, each eased
 * in and out over 5 ms so it beeps instead of clicking. Two alternating tones
 * read as an alarm where one steady tone reads as a telephone. The pitches and
 * the shape are AlarmSiren's on macOS, so the same alarm sounds the same on
 * every shell.
 *
 * It is synthesised rather than shipped as an asset, because a WAV in the
 * source tree is one more thing a packager can drop. Transfer full. */
static GBytes *
lk_siren_tone (void)
{
  const guint32 rate = 44100;
  const guint on_frames = (guint) (0.12 * rate);
  const guint gap_frames = (guint) (0.08 * rate);
  const guint envelope_frames = (guint) (0.005 * rate);
  const guint pulses = 6;
  const double pitch[2] = { 880.0, 1245.0 }; /* A5 and D#6: a minor third */

  guint frames = pulses * (on_frames + gap_frames);
  gsize samples_bytes = (gsize) frames * 2;
  gsize length = 44 + samples_bytes;
  guint8 *wav = g_malloc0 (length);

  /* A canonical 44-byte PCM header. Everything little-endian. */
  memcpy (wav, "RIFF", 4);
  *(guint32 *) (wav + 4) = GUINT32_TO_LE ((guint32) (length - 8));
  memcpy (wav + 8, "WAVEfmt ", 8);
  *(guint32 *) (wav + 16) = GUINT32_TO_LE (16);          /* fmt chunk size */
  *(guint16 *) (wav + 20) = GUINT16_TO_LE (1);           /* PCM */
  *(guint16 *) (wav + 22) = GUINT16_TO_LE (1);           /* one channel */
  *(guint32 *) (wav + 24) = GUINT32_TO_LE (rate);
  *(guint32 *) (wav + 28) = GUINT32_TO_LE (rate * 2);    /* bytes per second */
  *(guint16 *) (wav + 32) = GUINT16_TO_LE (2);           /* block align */
  *(guint16 *) (wav + 34) = GUINT16_TO_LE (16);          /* bits per sample */
  memcpy (wav + 36, "data", 4);
  *(guint32 *) (wav + 40) = GUINT32_TO_LE ((guint32) samples_bytes);

  gint16 *out = (gint16 *) (wav + 44);
  guint i = 0;
  for (guint p = 0; p < pulses; p++)
    {
      double f = pitch[p % 2];

      for (guint n = 0; n < on_frames; n++)
        {
          double a = sin (2 * G_PI * f * n / rate) * 0.6;

          if (n < envelope_frames)
            a *= (double) n / envelope_frames;
          else if (n >= on_frames - envelope_frames)
            a *= (double) (on_frames - n) / envelope_frames;

          out[i++] = GINT16_TO_LE ((gint16) (a * 32000));
        }
      for (guint n = 0; n < gap_frames; n++)
        out[i++] = 0;
    }

  return g_bytes_new_take (wav, length);
}

/* One sounding. GTK plays it when the build has a media backend; when it has
 * none the stream reports an error and the window's own bell stands in, which
 * is quieter than the tone and still better than silence. A silent alarm is
 * dangerous, so a failure is said once rather than swallowed. */
static void
lk_siren_strike (LkAlerts *self)
{
  if (self->stream == NULL)
    {
      g_autoptr (GBytes) tone = lk_siren_tone ();
      g_autoptr (GInputStream) source = g_memory_input_stream_new_from_bytes (tone);

      /* A memory stream, so nothing is written to the disk and no asset has to
       * ship. It is seekable, which is what lets one stream ring again. */
      self->stream = gtk_media_file_new_for_input_stream (source);
      gtk_media_stream_set_volume (self->stream, 1.0);
    }

  const GError *error = gtk_media_stream_get_error (self->stream);
  if (error == NULL)
    {
      /* Rewound, never overlapped: a second play over the first goes silent. */
      gtk_media_stream_seek (self->stream, 0);
      gtk_media_stream_play (self->stream);
      return;
    }

  if (!g_object_get_data (G_OBJECT (self->panel), "lk-siren-warned"))
    {
      g_object_set_data (G_OBJECT (self->panel), "lk-siren-warned", GINT_TO_POINTER (1));
      g_warning ("the alarm tone will not play (%s); alarms ring the bell instead",
                 error->message);
    }
  gtk_widget_error_bell (self->panel);
}

static gboolean
lk_siren_tick (gpointer user_data)
{
  lk_siren_strike (user_data);
  return G_SOURCE_CONTINUE;
}

/* Strike at once, then every ten seconds until nothing is unanswered. The first
 * alarm is never held back for a timer. */
static void
lk_siren_set_sounding (LkAlerts *self, gboolean on)
{
  if (on == self->siren_on)
    return;
  self->siren_on = on;

  if (!on)
    {
      g_clear_handle_id (&self->siren_id, g_source_remove);
      if (self->stream != NULL)
        gtk_media_stream_pause (self->stream);
      return;
    }

  lk_siren_strike (self);
  self->siren_id = g_timeout_add (LK_SIREN_REPEAT_MS, lk_siren_tick, self);
}

/* ---- reading the core ---------------------------------------------------- */

/* A severity this build does not know is an alarm, the way the core treats one
 * it cannot read. Silence is never the fallback. */
static LkAlertSeverity
lk_alert_severity_parse (const char *word)
{
  if (g_strcmp0 (word, "notice") == 0)
    return LK_ALERT_NOTICE;
  if (g_strcmp0 (word, "warning") == 0)
    return LK_ALERT_WARNING;
  return LK_ALERT_ALARM;
}

static const char *
lk_alert_icon (LkAlertSeverity severity)
{
  switch (severity)
    {
    case LK_ALERT_ALARM:   return "lk-alarm-symbolic";
    case LK_ALERT_WARNING: return "dialog-warning-symbolic";
    default:               return "dialog-information-symbolic";
    }
}

/* The strip wears the chrome's own tokens, so it stays readable at night
 * without a hardcoded red burning the mariner's dark adaptation. */
static const char *
lk_alert_css_class (LkAlertSeverity severity)
{
  switch (severity)
    {
    case LK_ALERT_ALARM:   return "lk-alarm";
    case LK_ALERT_WARNING: return "lk-warning";
    default:               return "lk-notice";
    }
}

static void
lk_alerts_acknowledge (GtkButton *button, gpointer user_data)
{
  LkAlerts *self = user_data;
  guint64 id = (guint64) GPOINTER_TO_SIZE (g_object_get_data (G_OBJECT (button), "lk-alert-id"));

  lk_chart_controller_alert_ack (lk_app_model_get_controller (self->model), id);

  /* Answer now, not on the next poll. Without this the row stays and the siren
     keeps sounding for up to a second after the mariner silences the alarm.
     seq = -1 forces the read to rebuild the strip. */
  self->seq = -1;
  lk_alerts_poll (self);
}

/* One alert: the severity bar, the words, and the control that silences it. */
static GtkWidget *
lk_alerts_build_row (LkAlerts *self, const LkAlert *alert)
{
  GtkWidget *row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 0);
  GtkWidget *bar = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);
  GtkWidget *line = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 8);
  GtkWidget *icon = gtk_image_new_from_icon_name (lk_alert_icon (alert->severity));
  GtkWidget *title = gtk_label_new (alert->title);
  GtkWidget *button = gtk_button_new_with_label ("Acknowledge");
  const char *tint = lk_alert_css_class (alert->severity);

  gtk_widget_set_size_request (bar, 4, -1);
  gtk_widget_add_css_class (bar, "lk-alert-bar");
  gtk_widget_add_css_class (bar, tint);

  gtk_image_set_pixel_size (GTK_IMAGE (icon), 14);
  gtk_widget_add_css_class (icon, tint);
  gtk_widget_add_css_class (title, "heading");

  gtk_box_append (GTK_BOX (line), icon);
  gtk_box_append (GTK_BOX (line), title);

  /* One line always. The words say which danger and which vessel; the water
   * under them is what the mariner is reading, so a long body is cut rather
   * than wrapped into a second line. */
  if (alert->body != NULL && alert->body[0] != '\0')
    {
      GtkWidget *body = gtk_label_new (alert->body);

      gtk_label_set_ellipsize (GTK_LABEL (body), PANGO_ELLIPSIZE_END);
      gtk_label_set_xalign (GTK_LABEL (body), 0.0);
      /* This is what caps the strip's width. It is wide enough to read a
       * vessel name and a CPA, and no wider: the strip stands over the water
       * the alarm is about. */
      gtk_label_set_max_width_chars (GTK_LABEL (body), LK_ALERT_MAX_CHARS);
      gtk_widget_set_hexpand (body, TRUE);
      gtk_widget_add_css_class (body, "dim-label");
      gtk_box_append (GTK_BOX (line), body);
    }
  else
    {
      GtkWidget *filler = gtk_label_new ("");

      gtk_widget_set_hexpand (filler, TRUE);
      gtk_box_append (GTK_BOX (line), filler);
    }

  gtk_widget_add_css_class (button, "lk-alert-ack");
  gtk_widget_set_valign (button, GTK_ALIGN_CENTER);
  gtk_widget_set_tooltip_text (button, "Silence this alert and take it off the chart");
  g_object_set_data (G_OBJECT (button), "lk-alert-id", GSIZE_TO_POINTER ((gsize) alert->id));
  g_signal_connect (button, "clicked", G_CALLBACK (lk_alerts_acknowledge), self);
  gtk_box_append (GTK_BOX (line), button);

  gtk_widget_set_margin_start (line, 10);
  gtk_widget_set_margin_end (line, 10);
  gtk_widget_set_margin_top (line, 8);
  gtk_widget_set_margin_bottom (line, 8);

  gtk_widget_set_hexpand (line, TRUE);
  gtk_box_append (GTK_BOX (row), bar);
  gtk_box_append (GTK_BOX (row), line);
  return row;
}

/* Only unacknowledged alerts show. Acknowledging takes the row off the chart:
 * the strip covers water, and its job is to say something needs attention NOW.
 * What is still dangerous after that is the chart's to show, and the plugin's
 * table holds it at the top of the list with its state. */
static void
lk_alerts_rebuild (LkAlerts *self)
{
  GtkWidget *child;

  while ((child = gtk_widget_get_first_child (self->panel)) != NULL)
    gtk_box_remove (GTK_BOX (self->panel), child);

  guint shown = 0, hidden = 0;
  for (guint i = 0; i < self->alerts->len; i++)
    {
      const LkAlert *alert = g_ptr_array_index (self->alerts, i);

      if (alert->acknowledged)
        continue;
      if (shown >= LK_ALERT_MAX_VISIBLE)
        {
          hidden++;
          continue;
        }

      if (shown > 0)
        gtk_box_append (GTK_BOX (self->panel),
                        gtk_separator_new (GTK_ORIENTATION_HORIZONTAL));
      gtk_box_append (GTK_BOX (self->panel), lk_alerts_build_row (self, alert));
      shown++;
    }

  if (hidden > 0)
    {
      g_autofree char *text = g_strdup_printf ("%u more", hidden);
      GtkWidget *label = gtk_label_new (text);

      gtk_widget_add_css_class (label, "dim-label");
      gtk_widget_add_css_class (label, "caption");
      gtk_widget_set_margin_top (label, 6);
      gtk_widget_set_margin_bottom (label, 6);
      gtk_box_append (GTK_BOX (self->panel),
                      gtk_separator_new (GTK_ORIENTATION_HORIZONTAL));
      gtk_box_append (GTK_BOX (self->panel), label);
    }

  gtk_widget_set_visible (self->panel, shown > 0);
}

static gboolean
lk_alerts_poll (gpointer user_data)
{
  LkAlerts *self = user_data;
  LkChartController *controller = lk_app_model_get_controller (self->model);
  g_autofree char *json = lk_chart_controller_alerts_json (controller);

  if (json == NULL)
    {
      /* Unreadable is not "no alerts", but nothing readable is nothing
       * showable: clear the strip, silence the siren, and KEEP WATCHING.
       * Stopping here would leave the boat deaf for the rest of the session
       * over one unanswered read. */
      if (self->alerts->len > 0)
        {
          g_ptr_array_set_size (self->alerts, 0);
          self->seq = -1;
          lk_alerts_rebuild (self);
        }
      lk_siren_set_sounding (self, FALSE);
      return G_SOURCE_CONTINUE;
    }

  g_autoptr (LkJson) root = lk_json_parse (json);
  if (root == NULL)
    return G_SOURCE_CONTINUE; /* a malformed read changes nothing */

  /* seq bumps on every change to the set. The rows are rebuilt only when it
   * moves, so a strip nobody is feeding does not flicker once a second. */
  gint64 seq = (gint64) lk_json_number (lk_json_member (root, "seq"), 0);
  if (seq != self->seq)
    {
      const LkJson *list = lk_json_member (root, "alerts");

      self->seq = seq;
      g_ptr_array_set_size (self->alerts, 0);

      for (guint i = 0; i < lk_json_length (list); i++)
        {
          const LkJson *node = lk_json_at (list, i);
          const char *title = lk_json_member_string (node, "title");

          if (title == NULL)
            continue;

          LkAlert *alert = g_new0 (LkAlert, 1);
          alert->id = (guint64) lk_json_number (lk_json_member (node, "id"), 0);
          alert->severity = lk_alert_severity_parse (lk_json_member_string (node, "severity"));
          alert->title = g_strdup (title);
          alert->body = g_strdup (lk_json_member_string (node, "body"));
          alert->acknowledged = lk_json_member_bool (node, "acknowledged", FALSE);
          g_ptr_array_add (self->alerts, alert);
        }

      lk_alerts_rebuild (self);
    }

  /* The siren follows the state every poll, rebuilt or not: an alarm is audible
   * until it is acknowledged, and a warning is never counted. */
  gboolean audible = FALSE;
  for (guint i = 0; i < self->alerts->len && !audible; i++)
    {
      const LkAlert *alert = g_ptr_array_index (self->alerts, i);

      audible = alert->severity == LK_ALERT_ALARM && !alert->acknowledged;
    }
  lk_siren_set_sounding (self, audible);

  return G_SOURCE_CONTINUE;
}

/* The watch runs while a plugin layer is up. Nothing else can raise an alert,
 * so a chart with no plugins costs nothing, and a collision alarm never waits
 * for a pane to be open. */
static void
lk_alerts_sync_watch (LkAlerts *self)
{
  gboolean wanted =
      lk_chart_controller_plugins_active (lk_app_model_get_controller (self->model));

  if (wanted == (self->poll_id != 0))
    return;

  if (wanted)
    {
      self->seq = -1;
      lk_alerts_poll (self);
      self->poll_id = g_timeout_add (LK_ALERT_POLL_MS, lk_alerts_poll, self);
      return;
    }

  g_clear_handle_id (&self->poll_id, g_source_remove);
  g_ptr_array_set_size (self->alerts, 0);
  self->seq = -1;
  lk_alerts_rebuild (self);
  lk_siren_set_sounding (self, FALSE);
}

/* The panel carries the state, so the handlers die with the panel rather than
 * outliving it on a model that lives for the whole session. A notify can still
 * arrive while the panel tears down, so both handlers stop at that. */
static void
lk_alerts_notify (GObject *object, GParamSpec *pspec, gpointer user_data)
{
  if (gtk_widget_in_destruction (GTK_WIDGET (user_data)))
    return;
  if (g_str_equal (g_param_spec_get_name (pspec), "has-chart"))
    lk_alerts_sync_watch (g_object_get_data (G_OBJECT (user_data), "lk-alerts"));
}

/* The plugin layer changed: a chart open loaded one, or the mariner installed
 * or removed one. A hot install must start the poll, and removing the last
 * plugin must stop it, neither of which changes has-chart. */
static void
lk_alerts_plugins_changed (LkAppModel *model, gpointer user_data)
{
  if (gtk_widget_in_destruction (GTK_WIDGET (user_data)))
    return;
  lk_alerts_sync_watch (g_object_get_data (G_OBJECT (user_data), "lk-alerts"));
}

static void
lk_alerts_free (gpointer data)
{
  LkAlerts *self = data;

  g_clear_handle_id (&self->poll_id, g_source_remove);
  g_clear_handle_id (&self->siren_id, g_source_remove);
  g_clear_object (&self->stream);
  g_ptr_array_unref (self->alerts);
  g_free (self);
}

GtkWidget *
lk_alerts_new (LkAppModel *model)
{
  g_return_val_if_fail (LK_IS_APP_MODEL (model), NULL);

  LkAlerts *self = g_new0 (LkAlerts, 1);
  self->model = model;
  self->alerts = g_ptr_array_new_with_free_func ((GDestroyNotify) lk_alert_free);
  self->seq = -1;
  self->panel = gtk_box_new (GTK_ORIENTATION_VERTICAL, 0);

  gtk_widget_add_css_class (self->panel, "lk-alert-strip");
  gtk_widget_set_halign (self->panel, GTK_ALIGN_CENTER);
  gtk_widget_set_valign (self->panel, GTK_ALIGN_START);
  gtk_widget_set_margin_top (self->panel, LK_CHROME_MARGIN);
  gtk_widget_set_visible (self->panel, FALSE);
  /* The strip takes the pointer, because the mariner has to reach Acknowledge. */
  gtk_widget_set_can_target (self->panel, TRUE);

  g_object_set_data_full (G_OBJECT (self->panel), "lk-alerts", self, lk_alerts_free);
  g_signal_connect_object (model, "notify", G_CALLBACK (lk_alerts_notify),
                           self->panel, 0);
  g_signal_connect_object (model, "plugins-changed", G_CALLBACK (lk_alerts_plugins_changed),
                           self->panel, 0);
  lk_alerts_sync_watch (self);

  return self->panel;
}
