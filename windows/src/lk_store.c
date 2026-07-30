#include "lk_store.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shlobj.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define LK_GROUP_VIEW    "view"
#define LK_GROUP_RECENTS "recents"
#define LK_GROUP_MARINER "mariner.v1"

#define LK_MAX_RECENTS 10

/* %APPDATA%\lookout-marine\settings.ini (created on first write). One static
 * buffer: the store is only touched from the UI thread. */
static const char *
store_path(void)
{
    static char path[MAX_PATH];
    if (path[0] != '\0')
        return path;

    char base[MAX_PATH];
    if (SUCCEEDED(SHGetFolderPathA(NULL, CSIDL_APPDATA, NULL, 0, base))) {
        snprintf(path, sizeof path, "%s\\lookout-marine", base);
        CreateDirectoryA(path, NULL);
        strncat(path, "\\settings.ini", sizeof path - strlen(path) - 1);
    } else {
        strcpy(path, ".\\lookout-settings.ini");
    }
    return path;
}

/* ---- small profile-API helpers ------------------------------------------ */

static void
set_str(const char *group, const char *key, const char *value)
{
    WritePrivateProfileStringA(group, key, value, store_path());
}

static void
set_double(const char *group, const char *key, double value)
{
    char buf[64];
    snprintf(buf, sizeof buf, "%.10g", value);
    WritePrivateProfileStringA(group, key, buf, store_path());
}

static void
set_int(const char *group, const char *key, int value)
{
    char buf[32];
    snprintf(buf, sizeof buf, "%d", value);
    WritePrivateProfileStringA(group, key, buf, store_path());
}

/* A sentinel default distinguishes "missing" from any real value, so the
 * mariner overlay can leave absent keys untouched (as the GKeyFile "has-key"
 * check does on Linux). Returns 1 if the key exists (writes *out). */
static int
get_str(const char *group, const char *key, char *out, int out_len)
{
    static const char *MISSING = "\x01\x02_lk_missing_";
    GetPrivateProfileStringA(group, key, MISSING, out, (DWORD)out_len, store_path());
    return strcmp(out, MISSING) != 0;
}

static int
get_double(const char *group, const char *key, double *out)
{
    char buf[64];
    if (!get_str(group, key, buf, sizeof buf))
        return 0;
    char *end = NULL;
    double v = strtod(buf, &end);
    if (end == buf)
        return 0;
    *out = v;
    return 1;
}

static int
get_int(const char *group, const char *key, int *out)
{
    char buf[32];
    if (!get_str(group, key, buf, sizeof buf))
        return 0;
    *out = atoi(buf);
    return 1;
}

/* ---- camera pose --------------------------------------------------------- */

int
lk_store_load_view(lookout_view *out)
{
    if (out == NULL)
        return 0;
    if (!get_double(LK_GROUP_VIEW, "lon", &out->lon))
        return 0;
    get_double(LK_GROUP_VIEW, "lat", &out->lat);
    get_double(LK_GROUP_VIEW, "zoom", &out->zoom);
    get_double(LK_GROUP_VIEW, "rotation_deg", &out->rotation_deg);
    return 1;
}

void
lk_store_save_view(const lookout_view *view)
{
    if (view == NULL)
        return;
    set_double(LK_GROUP_VIEW, "lon", view->lon);
    set_double(LK_GROUP_VIEW, "lat", view->lat);
    set_double(LK_GROUP_VIEW, "zoom", view->zoom);
    set_double(LK_GROUP_VIEW, "rotation_deg", view->rotation_deg);
}

/* ---- recents ------------------------------------------------------------- */

char **
lk_store_load_recents(void)
{
    int count = 0;
    get_int(LK_GROUP_RECENTS, "count", &count);
    if (count < 0) count = 0;
    if (count > LK_MAX_RECENTS) count = LK_MAX_RECENTS;

    char **out = (char **)calloc((size_t)count + 1, sizeof(char *));
    if (out == NULL)
        return NULL;

    int n = 0;
    for (int i = 0; i < count; i++) {
        char key[32], buf[MAX_PATH * 2];
        snprintf(key, sizeof key, "item%d", i);
        if (get_str(LK_GROUP_RECENTS, key, buf, sizeof buf) && buf[0] != '\0')
            out[n++] = _strdup(buf);
    }
    out[n] = NULL;
    return out;
}

void
lk_store_note_recent(const char *path)
{
    if (path == NULL || path[0] == '\0')
        return;

    char **existing = lk_store_load_recents();

    /* New entry first, then the previous ones minus any duplicate, capped. */
    const char *merged[LK_MAX_RECENTS];
    int n = 0;
    merged[n++] = path;
    for (int i = 0; existing && existing[i] != NULL && n < LK_MAX_RECENTS; i++) {
        if (strcmp(existing[i], path) != 0)
            merged[n++] = existing[i];
    }

    set_int(LK_GROUP_RECENTS, "count", n);
    for (int i = 0; i < n; i++) {
        char key[32];
        snprintf(key, sizeof key, "item%d", i);
        set_str(LK_GROUP_RECENTS, key, merged[i]);
    }

    lk_store_free_recents(existing);
}

void
lk_store_free_recents(char **recents)
{
    if (recents == NULL)
        return;
    for (int i = 0; recents[i] != NULL; i++)
        free(recents[i]);
    free(recents);
}

/* ---- mariner ------------------------------------------------------------- */

void
lk_store_save_mariner(const tile57_mariner *m)
{
    if (m == NULL)
        return;

    set_int(LK_GROUP_MARINER, "scheme", (int)m->scheme);
    set_int(LK_GROUP_MARINER, "depth_unit", (int)m->depth_unit);
    set_double(LK_GROUP_MARINER, "shallow_contour", m->shallow_contour);
    set_double(LK_GROUP_MARINER, "safety_contour", m->safety_contour);
    set_double(LK_GROUP_MARINER, "deep_contour", m->deep_contour);
    set_double(LK_GROUP_MARINER, "safety_depth", m->safety_depth);
    set_int(LK_GROUP_MARINER, "four_shade_water", m->four_shade_water ? 1 : 0);
    set_int(LK_GROUP_MARINER, "display_base", m->display_base ? 1 : 0);
    set_int(LK_GROUP_MARINER, "display_standard", m->display_standard ? 1 : 0);
    set_int(LK_GROUP_MARINER, "display_other", m->display_other ? 1 : 0);
    set_int(LK_GROUP_MARINER, "soundings", (int)m->soundings);
    set_int(LK_GROUP_MARINER, "text_names", m->text_names ? 1 : 0);
    set_int(LK_GROUP_MARINER, "show_light_descriptions", m->show_light_descriptions ? 1 : 0);
    set_int(LK_GROUP_MARINER, "text_other", m->text_other ? 1 : 0);
    set_int(LK_GROUP_MARINER, "simplified_points", m->simplified_points ? 1 : 0);
    set_int(LK_GROUP_MARINER, "boundary_style", (int)m->boundary_style);
    set_int(LK_GROUP_MARINER, "show_full_sector_lines", m->show_full_sector_lines ? 1 : 0);
    set_int(LK_GROUP_MARINER, "data_quality", m->data_quality ? 1 : 0);
    set_int(LK_GROUP_MARINER, "show_isolated_dangers_shallow", m->show_isolated_dangers_shallow ? 1 : 0);
    set_int(LK_GROUP_MARINER, "show_inform_callouts", m->show_inform_callouts ? 1 : 0);
    set_int(LK_GROUP_MARINER, "show_meta_bounds", m->show_meta_bounds ? 1 : 0);
    set_int(LK_GROUP_MARINER, "show_overscale", m->show_overscale ? 1 : 0);
    set_double(LK_GROUP_MARINER, "size_scale", m->size_scale);
    set_double(LK_GROUP_MARINER, "text_size_scale", m->text_size_scale);
    set_double(LK_GROUP_MARINER, "sounding_size_scale", m->sounding_size_scale);
    set_int(LK_GROUP_MARINER, "date_dependent", m->date_dependent ? 1 : 0);
    set_int(LK_GROUP_MARINER, "highlight_date_dependent", m->highlight_date_dependent ? 1 : 0);
    set_str(LK_GROUP_MARINER, "date_view", m->date_view);
}

/* Apply each key only when present, so older settings files leave newer fields
 * at engine defaults instead of zeroing them. */
#define APPLY_INT(key, field)                       \
    do {                                            \
        int v;                                      \
        if (get_int(LK_GROUP_MARINER, key, &v))     \
            (field) = v;                            \
    } while (0)
#define APPLY_BOOL(key, field)                      \
    do {                                            \
        int v;                                      \
        if (get_int(LK_GROUP_MARINER, key, &v))     \
            (field) = v ? true : false;             \
    } while (0)
#define APPLY_DBL(key, field)                       \
    do {                                            \
        double v;                                   \
        if (get_double(LK_GROUP_MARINER, key, &v))  \
            (field) = v;                            \
    } while (0)
/* Positive-only: a stored 0 for a size scale would black out every symbol. */
#define APPLY_SCALE(key, field)                     \
    do {                                            \
        double v;                                   \
        if (get_double(LK_GROUP_MARINER, key, &v) && v > 0.0) \
            (field) = v;                            \
    } while (0)

void
lk_store_apply_saved_mariner(tile57_mariner *m)
{
    if (m == NULL)
        return;

    APPLY_INT("scheme", m->scheme);
    APPLY_INT("depth_unit", m->depth_unit);
    APPLY_DBL("shallow_contour", m->shallow_contour);
    APPLY_DBL("safety_contour", m->safety_contour);
    APPLY_DBL("deep_contour", m->deep_contour);
    APPLY_DBL("safety_depth", m->safety_depth);
    APPLY_BOOL("four_shade_water", m->four_shade_water);
    APPLY_BOOL("display_base", m->display_base);
    APPLY_BOOL("display_standard", m->display_standard);
    APPLY_BOOL("display_other", m->display_other);
    APPLY_INT("soundings", m->soundings);
    APPLY_BOOL("text_names", m->text_names);
    APPLY_BOOL("show_light_descriptions", m->show_light_descriptions);
    APPLY_BOOL("text_other", m->text_other);
    APPLY_BOOL("simplified_points", m->simplified_points);
    APPLY_INT("boundary_style", m->boundary_style);
    APPLY_BOOL("show_full_sector_lines", m->show_full_sector_lines);
    APPLY_BOOL("data_quality", m->data_quality);
    APPLY_BOOL("show_isolated_dangers_shallow", m->show_isolated_dangers_shallow);
    APPLY_BOOL("show_inform_callouts", m->show_inform_callouts);
    APPLY_BOOL("show_meta_bounds", m->show_meta_bounds);
    APPLY_BOOL("show_overscale", m->show_overscale);
    APPLY_SCALE("size_scale", m->size_scale);
    APPLY_SCALE("text_size_scale", m->text_size_scale);
    APPLY_SCALE("sounding_size_scale", m->sounding_size_scale);
    APPLY_BOOL("date_dependent", m->date_dependent);
    APPLY_BOOL("highlight_date_dependent", m->highlight_date_dependent);

    char date[16];
    if (get_str(LK_GROUP_MARINER, "date_view", date, sizeof date)) {
        memset(m->date_view, 0, sizeof m->date_view);
        strncpy(m->date_view, date, sizeof m->date_view - 1);
    }
}

#undef APPLY_INT
#undef APPLY_BOOL
#undef APPLY_DBL
#undef APPLY_SCALE
