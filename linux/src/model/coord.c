#include "model/coord.h"

#include <math.h>
#include <string.h>

static gboolean
lk_parse_hemispheres (const char *text, double *out_lat, double *out_lon)
{
  /* deg [min [sec]] hemisphere — minutes and seconds both optional. */
  static const char *pattern =
      "(\\d+(?:\\.\\d+)?)\\s*[°\\s]\\s*"
      "(?:(\\d+(?:\\.\\d+)?)\\s*['′\\s]\\s*)?"
      "(?:(\\d+(?:\\.\\d+)?)\\s*[\"″\\s]\\s*)?"
      "([NSEWnsew])";

  g_autoptr (GRegex) regex = g_regex_new (pattern, G_REGEX_CASELESS, 0, NULL);
  if (regex == NULL)
    return FALSE;

  g_autoptr (GMatchInfo) match = NULL;
  if (!g_regex_match (regex, text, 0, &match))
    return FALSE;

  gboolean have_lat = FALSE, have_lon = FALSE;

  while (g_match_info_matches (match))
    {
      g_autofree char *deg_s = g_match_info_fetch (match, 1);
      g_autofree char *min_s = g_match_info_fetch (match, 2);
      g_autofree char *sec_s = g_match_info_fetch (match, 3);
      g_autofree char *hemi_s = g_match_info_fetch (match, 4);

      if (deg_s != NULL && deg_s[0] != '\0' && hemi_s != NULL && hemi_s[0] != '\0')
        {
          double value = g_ascii_strtod (deg_s, NULL);
          if (min_s != NULL && min_s[0] != '\0')
            value += g_ascii_strtod (min_s, NULL) / 60.0;
          if (sec_s != NULL && sec_s[0] != '\0')
            value += g_ascii_strtod (sec_s, NULL) / 3600.0;

          char hemi = g_ascii_toupper (hemi_s[0]);
          if (hemi == 'S' || hemi == 'W')
            value = -value;

          if (hemi == 'N' || hemi == 'S')
            {
              *out_lat = value;
              have_lat = TRUE;
            }
          else
            {
              *out_lon = value;
              have_lon = TRUE;
            }
        }

      g_match_info_next (match, NULL);
    }

  /* The same fences as the decimal path: 91°N is a typo, not a place. */
  if (!have_lat || !have_lon)
    return FALSE;
  return *out_lat >= -90 && *out_lat <= 90 && *out_lon >= -180 && *out_lon <= 180;
}

gboolean
lk_coordinate_parse (const char *text, double *out_lat, double *out_lon)
{
  g_return_val_if_fail (out_lat != NULL && out_lon != NULL, FALSE);

  if (text == NULL)
    return FALSE;

  g_autofree char *trimmed = g_strstrip (g_strdup (text));
  if (trimmed[0] == '\0')
    return FALSE;

  if (strpbrk (trimmed, "NSEWnsew") != NULL)
    return lk_parse_hemispheres (trimmed, out_lat, out_lon);

  /* A decimal pair, comma- or whitespace-separated, latitude first. */
  g_auto (GStrv) parts = g_strsplit_set (trimmed, ", \t", -1);
  g_autoptr (GPtrArray) numbers = g_ptr_array_new ();
  for (guint i = 0; parts[i] != NULL; i++)
    {
      if (parts[i][0] != '\0')
        g_ptr_array_add (numbers, parts[i]);
    }

  if (numbers->len < 2)
    return FALSE;

  char *end_lat = NULL, *end_lon = NULL;
  double lat = g_ascii_strtod (g_ptr_array_index (numbers, 0), &end_lat);
  double lon = g_ascii_strtod (g_ptr_array_index (numbers, 1), &end_lon);

  if (end_lat == g_ptr_array_index (numbers, 0) || *end_lat != '\0')
    return FALSE;
  if (end_lon == g_ptr_array_index (numbers, 1) || *end_lon != '\0')
    return FALSE;
  if (lat < -90 || lat > 90 || lon < -180 || lon > 180)
    return FALSE;

  *out_lat = lat;
  *out_lon = lon;
  return TRUE;
}

/* A typed scale: "25000", "25,000", "1:25000", "25k" and "1:2.5M" all mean the
 * same thing. It accepts what ScaleParser accepts on the other shells, so a
 * scale read off one app types into another. */
gboolean
lk_scale_parse (const char *text, double *out_denominator)
{
  g_return_val_if_fail (out_denominator != NULL, FALSE);

  if (text == NULL)
    return FALSE;

  g_autofree char *lower = g_ascii_strdown (text, -1);
  const char *body = strrchr (lower, ':'); /* in "1:25k" the 1 is before it */
  body = body != NULL ? body + 1 : lower;

  /* Group separators and spaces are how a scale is written, not part of it. */
  g_autoptr (GString) digits = g_string_new (NULL);
  double multiplier = 1.0;
  for (const char *p = body; *p != '\0'; p++)
    {
      if (*p == ',' || g_ascii_isspace (*p))
        continue;
      g_string_append_c (digits, *p);
    }

  if (digits->len == 0)
    return FALSE;

  char last = digits->str[digits->len - 1];
  if (last == 'k' || last == 'm')
    {
      multiplier = last == 'k' ? 1000.0 : 1000000.0;
      g_string_truncate (digits, digits->len - 1);
    }

  char *end = NULL;
  double value = g_ascii_strtod (digits->str, &end);
  if (end == digits->str || *end != '\0')
    return FALSE;

  double denominator = value * multiplier;
  if (!isfinite (denominator) || denominator <= 0)
    return FALSE;
  /* The range ScaleParser holds on the other shells: below 1:100 no chart
   * exists, above 1:100,000,000 the number is a typo, and either way Go would
   * fire a nonsense zoom. */
  if (denominator < 100.0 || denominator > 100000000.0)
    return FALSE;

  *out_denominator = denominator;
  return TRUE;
}
