#include "lk-json.h"

#include <math.h>
#include <string.h>

/* A cap on nesting, so a document of nothing but opening brackets cannot run
   the parser off the stack. Deeper than any message this shell reads. */
#define LK_JSON_MAX_DEPTH 64

struct _LkJson {
  LkJsonKind kind;

  /* Scalars. `text` is what the document wrote, so a number keeps its own
   * digits; `number` is that text as a double, for the few numeric members. */
  char    *text;
  double   number;
  gboolean boolean;

  /* Containers. `keys` is parallel to `items` for an object, NULL otherwise. */
  GPtrArray *items; /* LkJson * */
  GPtrArray *keys;  /* char * */
};

typedef struct {
  const char *p;
  int         depth; /* open containers above this point */
} LkJsonReader;

static LkJson *lk_json_read_value (LkJsonReader *r);

static LkJson *
lk_json_new (LkJsonKind kind)
{
  LkJson *node = g_new0 (LkJson, 1);
  node->kind = kind;
  return node;
}

void
lk_json_free (LkJson *node)
{
  if (node == NULL)
    return;

  g_free (node->text);
  g_clear_pointer (&node->items, g_ptr_array_unref);
  g_clear_pointer (&node->keys, g_ptr_array_unref);
  g_free (node);
}

/* ---- reading ------------------------------------------------------------ */

static void
lk_json_skip_space (LkJsonReader *r)
{
  while (*r->p == ' ' || *r->p == '\t' || *r->p == '\n' || *r->p == '\r')
    r->p++;
}

/* One \uXXXX escape, appended as UTF-8. A high surrogate takes its low half
 * with it, because a cell name outside the BMP arrives as a pair. */
static gboolean
lk_json_read_escape_unicode (LkJsonReader *r, GString *out)
{
  char hex[5] = { 0 };
  gunichar code;

  for (int i = 0; i < 4; i++)
    {
      if (!g_ascii_isxdigit (r->p[i]))
        return FALSE;
      hex[i] = r->p[i];
    }
  r->p += 4;
  code = (gunichar) g_ascii_strtoull (hex, NULL, 16);

  if (code >= 0xD800 && code <= 0xDBFF && r->p[0] == '\\' && r->p[1] == 'u')
    {
      char low_hex[5] = { 0 };
      for (int i = 0; i < 4; i++)
        {
          if (!g_ascii_isxdigit (r->p[2 + i]))
            return FALSE;
          low_hex[i] = r->p[2 + i];
        }
      gunichar low = (gunichar) g_ascii_strtoull (low_hex, NULL, 16);
      if (low >= 0xDC00 && low <= 0xDFFF)
        {
          r->p += 6;
          code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
        }
    }

  /* A lone surrogate is not a character, and a NUL would truncate the C string
   * the label is built from. Keep the string readable and whole rather than
   * writing invalid UTF-8 or a cut a reader downstream would never see past. */
  if ((code >= 0xD800 && code <= 0xDFFF) || code == 0)
    code = 0xFFFD;

  g_string_append_unichar (out, code);
  return TRUE;
}

/* The text between the quotes, unescaped. r->p is on the opening quote. */
static char *
lk_json_read_string (LkJsonReader *r)
{
  g_autoptr (GString) out = g_string_new (NULL);

  if (*r->p != '"')
    return NULL;
  r->p++;

  while (*r->p != '"')
    {
      if (*r->p == '\0')
        return NULL;

      if (*r->p != '\\')
        {
          g_string_append_c (out, *r->p++);
          continue;
        }

      r->p++;
      switch (*r->p)
        {
        case '"':  g_string_append_c (out, '"');  r->p++; break;
        case '\\': g_string_append_c (out, '\\'); r->p++; break;
        case '/':  g_string_append_c (out, '/');  r->p++; break;
        case 'b':  g_string_append_c (out, '\b'); r->p++; break;
        case 'f':  g_string_append_c (out, '\f'); r->p++; break;
        case 'n':  g_string_append_c (out, '\n'); r->p++; break;
        case 'r':  g_string_append_c (out, '\r'); r->p++; break;
        case 't':  g_string_append_c (out, '\t'); r->p++; break;
        case 'u':
          r->p++;
          if (!lk_json_read_escape_unicode (r, out))
            return NULL;
          break;
        default:
          return NULL;
        }
    }

  r->p++; /* the closing quote */
  return g_string_free (g_steal_pointer (&out), FALSE);
}

static LkJson *
lk_json_read_number (LkJsonReader *r)
{
  const char *start = r->p;
  char *end = NULL;

  /* A JSON number starts with a digit or a minus. g_ascii_strtod also takes
     forms JSON forbids — a leading plus or dot, hexadecimal floats, inf, nan —
     so both the first character and the whole consumed span are checked. */
  if (*start != '-' && !g_ascii_isdigit (*start))
    return NULL;

  double value = g_ascii_strtod (start, &end);
  if (end == start || !isfinite (value))
    return NULL;

  for (const char *c = start; c < end; c++)
    {
      if (!g_ascii_isdigit (*c) && *c != '.' && *c != '-' && *c != '+' &&
          *c != 'e' && *c != 'E')
        return NULL; /* a hex digit or an 'x' — a form strtod took, JSON forbids */
    }

  LkJson *node = lk_json_new (LK_JSON_NUMBER);
  node->number = value;
  node->text = g_strndup (start, (gsize) (end - start));
  r->p = end;
  return node;
}

static LkJson *
lk_json_read_array (LkJsonReader *r)
{
  LkJson *node = lk_json_new (LK_JSON_ARRAY);

  node->items = g_ptr_array_new_with_free_func ((GDestroyNotify) lk_json_free);
  r->p++; /* [ */
  lk_json_skip_space (r);

  if (*r->p == ']')
    {
      r->p++;
      return node;
    }

  for (;;)
    {
      LkJson *item = lk_json_read_value (r);
      if (item == NULL)
        {
          lk_json_free (node);
          return NULL;
        }
      g_ptr_array_add (node->items, item);

      lk_json_skip_space (r);
      if (*r->p == ',')
        {
          r->p++;
          lk_json_skip_space (r);
          continue;
        }
      if (*r->p == ']')
        {
          r->p++;
          return node;
        }

      lk_json_free (node);
      return NULL;
    }
}

static LkJson *
lk_json_read_object (LkJsonReader *r)
{
  LkJson *node = lk_json_new (LK_JSON_OBJECT);

  node->items = g_ptr_array_new_with_free_func ((GDestroyNotify) lk_json_free);
  node->keys = g_ptr_array_new_with_free_func (g_free);
  r->p++; /* { */
  lk_json_skip_space (r);

  if (*r->p == '}')
    {
      r->p++;
      return node;
    }

  for (;;)
    {
      char *key = lk_json_read_string (r);
      if (key == NULL)
        {
          lk_json_free (node);
          return NULL;
        }

      lk_json_skip_space (r);
      if (*r->p != ':')
        {
          g_free (key);
          lk_json_free (node);
          return NULL;
        }
      r->p++;
      lk_json_skip_space (r);

      LkJson *value = lk_json_read_value (r);
      if (value == NULL)
        {
          g_free (key);
          lk_json_free (node);
          return NULL;
        }
      g_ptr_array_add (node->keys, key);
      g_ptr_array_add (node->items, value);

      lk_json_skip_space (r);
      if (*r->p == ',')
        {
          r->p++;
          lk_json_skip_space (r);
          continue;
        }
      if (*r->p == '}')
        {
          r->p++;
          return node;
        }

      lk_json_free (node);
      return NULL;
    }
}

static LkJson *
lk_json_read_value (LkJsonReader *r)
{
  lk_json_skip_space (r);

  switch (*r->p)
    {
    case '{':
      {
        if (++r->depth > LK_JSON_MAX_DEPTH)
          return NULL;
        LkJson *node = lk_json_read_object (r);
        r->depth--;
        return node;
      }

    case '[':
      {
        if (++r->depth > LK_JSON_MAX_DEPTH)
          return NULL;
        LkJson *node = lk_json_read_array (r);
        r->depth--;
        return node;
      }

    case '"':
      {
        char *text = lk_json_read_string (r);
        if (text == NULL)
          return NULL;
        LkJson *node = lk_json_new (LK_JSON_STRING);
        node->text = text;
        return node;
      }

    case 't':
      if (strncmp (r->p, "true", 4) != 0)
        return NULL;
      r->p += 4;
      {
        LkJson *node = lk_json_new (LK_JSON_BOOL);
        node->boolean = TRUE;
        node->text = g_strdup ("true");
        return node;
      }

    case 'f':
      if (strncmp (r->p, "false", 5) != 0)
        return NULL;
      r->p += 5;
      {
        LkJson *node = lk_json_new (LK_JSON_BOOL);
        node->boolean = FALSE;
        node->text = g_strdup ("false");
        return node;
      }

    case 'n':
      if (strncmp (r->p, "null", 4) != 0)
        return NULL;
      r->p += 4;
      return lk_json_new (LK_JSON_NULL);

    default:
      return lk_json_read_number (r);
    }
}

LkJson *
lk_json_parse (const char *text)
{
  if (text == NULL || text[0] == '\0')
    return NULL;

  LkJsonReader reader = { .p = text };
  LkJson *root = lk_json_read_value (&reader);

  if (root == NULL)
    return NULL;

  lk_json_skip_space (&reader);
  if (*reader.p != '\0')
    {
      lk_json_free (root);
      return NULL;
    }

  return root;
}

/* ---- reading the tree --------------------------------------------------- */

LkJsonKind
lk_json_kind (const LkJson *node)
{
  return node != NULL ? node->kind : LK_JSON_NULL;
}

const LkJson *
lk_json_member (const LkJson *node, const char *name)
{
  if (node == NULL || node->kind != LK_JSON_OBJECT || name == NULL)
    return NULL;

  /* A duplicate key answers with the LAST value, as the other shells' parsers
     do, so search from the end and take the first hit. */
  for (guint i = node->keys->len; i > 0; i--)
    {
      if (g_str_equal (g_ptr_array_index (node->keys, i - 1), name))
        return g_ptr_array_index (node->items, i - 1);
    }
  return NULL;
}

/* g_ptr_array_sort_values hands the elements themselves, not slots holding
 * them — unlike the older g_ptr_array_sort. */
static int
lk_json_compare_keys (gconstpointer a, gconstpointer b)
{
  return g_strcmp0 (a, b);
}

GPtrArray *
lk_json_member_names (const LkJson *node)
{
  GPtrArray *names = g_ptr_array_new ();

  if (node == NULL || node->kind != LK_JSON_OBJECT)
    return names;

  for (guint i = 0; i < node->keys->len; i++)
    g_ptr_array_add (names, g_ptr_array_index (node->keys, i));

  g_ptr_array_sort_values (names, lk_json_compare_keys);
  return names;
}

guint
lk_json_length (const LkJson *node)
{
  if (node == NULL || node->items == NULL)
    return 0;
  return node->items->len;
}

const LkJson *
lk_json_at (const LkJson *node, guint index)
{
  if (node == NULL || node->items == NULL || index >= node->items->len)
    return NULL;
  return g_ptr_array_index (node->items, index);
}

const char *
lk_json_string (const LkJson *node)
{
  if (node == NULL || node->kind != LK_JSON_STRING)
    return NULL;
  return node->text;
}

const char *
lk_json_text (const LkJson *node)
{
  if (node == NULL || node->text == NULL)
    return "";
  return node->text;
}

double
lk_json_number (const LkJson *node, double fallback)
{
  if (node == NULL || node->kind != LK_JSON_NUMBER)
    return fallback;
  return node->number;
}

gboolean
lk_json_bool (const LkJson *node, gboolean fallback)
{
  if (node == NULL || node->kind != LK_JSON_BOOL)
    return fallback;
  return node->boolean;
}

const char *
lk_json_member_string (const LkJson *node, const char *name)
{
  const char *text = lk_json_string (lk_json_member (node, name));

  return (text != NULL && text[0] != '\0') ? text : NULL;
}

int
lk_json_member_int (const LkJson *node, const char *name, int fallback)
{
  return (int) lk_json_number (lk_json_member (node, name), fallback);
}

gboolean
lk_json_member_bool (const LkJson *node, const char *name, gboolean fallback)
{
  return lk_json_bool (lk_json_member (node, name), fallback);
}
