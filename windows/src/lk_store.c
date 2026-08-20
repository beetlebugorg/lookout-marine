#include "lk_store.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shlobj.h>
#include <math.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define LK_GROUP_VIEW    "view"
#define LK_GROUP_RECENTS "recents"
#define LK_GROUP_MARINER "mariner.v1"
#define LK_GROUP_RASTER  "raster"

#define LK_MAX_RECENTS 10
/* A baked BSB/KAP bundle is one chart per sheet — the OpenSeaMap West Coast
 * set alone is 968 files. */
#define LK_MAX_RASTERS 2048

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
    out->lat = 0;
    out->zoom = 0;
    out->rotation_deg = 0;
    if (!get_double(LK_GROUP_VIEW, "lon", &out->lon))
        return 0;
    get_double(LK_GROUP_VIEW, "lat", &out->lat);
    get_double(LK_GROUP_VIEW, "zoom", &out->zoom);
    get_double(LK_GROUP_VIEW, "rotation_deg", &out->rotation_deg);
    /* The envelope is what a marine chart can CONTAIN, not what the
     * projection can express: no chart lies above ~84° and chart detail ends
     * well before z16. The projection's own limits (lat ±85.05, zoom 22) are
     * not safe to accept — a zoom past ~20 overruns f32 world coordinates and
     * collapses the camera to the world corner, and that corner pose (lat
     * 85.0509, z<19) then saves itself back inside the projection envelope.
     * Anything outside is rejected and the open fits the chart instead. Lon
     * keeps the full ±180: the Aleutians cross the dateline. */
    if (!isfinite(out->lon) || out->lon < -180.0 || out->lon > 180.0 ||
        !isfinite(out->lat) || out->lat < -84.0 || out->lat > 84.0 ||
        !isfinite(out->zoom) || out->zoom < 0.0 || out->zoom > 16.0 ||
        !isfinite(out->rotation_deg))
        return 0;
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

/* ---- the settings window -------------------------------------------------- */

#define LK_GROUP_WINDOW "window"

int
lk_store_load_settings_size(int *width, int *height)
{
    if (width == NULL || height == NULL)
        return 0;
    int w = 0, h = 0;
    if (!get_int(LK_GROUP_WINDOW, "settings_w", &w) ||
        !get_int(LK_GROUP_WINDOW, "settings_h", &h))
        return 0;
    *width = w;
    *height = h;
    return 1;
}

void
lk_store_save_settings_size(int width, int height)
{
    if (width <= 0 || height <= 0)
        return;
    set_int(LK_GROUP_WINDOW, "settings_w", width);
    set_int(LK_GROUP_WINDOW, "settings_h", height);
}

/* ---- raster charts ------------------------------------------------------- */

/* The whole group is read and written as ONE section (GetPrivateProfileSection
 * / WritePrivateProfileSection): a baked sheet bundle holds hundreds of paths,
 * and per-key profile calls re-parse the file every time. */

char **
lk_store_load_rasters(int **enabled_out)
{
    if (enabled_out != NULL)
        *enabled_out = NULL;

    static const DWORD SEC_BYTES = 1u << 20;
    char *sec = (char *)malloc(SEC_BYTES);
    char **by_idx = (char **)calloc(LK_MAX_RASTERS, sizeof(char *));
    int *en_by_idx = (int *)malloc(LK_MAX_RASTERS * sizeof(int));
    char **out = (char **)calloc(LK_MAX_RASTERS + 1, sizeof(char *));
    int *en = (int *)calloc(LK_MAX_RASTERS + 1, sizeof(int));
    if (sec == NULL || by_idx == NULL || en_by_idx == NULL || out == NULL || en == NULL) {
        free(sec); free(by_idx); free(en_by_idx); free(out); free(en);
        return NULL;
    }
    for (int i = 0; i < LK_MAX_RASTERS; i++)
        en_by_idx[i] = 1;

    GetPrivateProfileSectionA(LK_GROUP_RASTER, sec, SEC_BYTES, store_path());

    /* "key=value" entries, NUL-separated; addressed by index so a reordered
     * file still loads. "count" is written for a human reader and ignored. */
    for (char *p = sec; *p != '\0'; p += strlen(p) + 1) {
        char *eq = strchr(p, '=');
        if (eq == NULL)
            continue;
        *eq = '\0';
        const char *val = eq + 1;
        int idx;
        if (sscanf(p, "item%d", &idx) == 1 && idx >= 0 && idx < LK_MAX_RASTERS) {
            if (by_idx[idx] == NULL && val[0] != '\0')
                by_idx[idx] = _strdup(val);
        } else if (sscanf(p, "enabled%d", &idx) == 1 && idx >= 0 && idx < LK_MAX_RASTERS) {
            en_by_idx[idx] = atoi(val) ? 1 : 0;
        }
    }
    free(sec);

    int n = 0;
    for (int i = 0; i < LK_MAX_RASTERS; i++) {
        if (by_idx[i] == NULL)
            continue;
        out[n] = by_idx[i];
        en[n] = en_by_idx[i];
        n++;
    }
    out[n] = NULL;
    free(by_idx);
    free(en_by_idx);

    if (enabled_out != NULL)
        *enabled_out = en;
    else
        free(en);
    return out;
}

static void
save_rasters(const char *const *paths, const int *enabled, int n)
{
    size_t cap = 64;
    for (int i = 0; i < n; i++)
        cap += strlen(paths[i]) + 48;
    char *buf = (char *)malloc(cap);
    if (buf == NULL)
        return;

    size_t off = 0;
    off += (size_t)snprintf(buf + off, cap - off, "count=%d", n) + 1;
    for (int i = 0; i < n; i++) {
        off += (size_t)snprintf(buf + off, cap - off, "item%d=%s", i, paths[i]) + 1;
        off += (size_t)snprintf(buf + off, cap - off, "enabled%d=%d", i, enabled[i] ? 1 : 0) + 1;
    }
    buf[off] = '\0'; /* double NUL ends the section */

    /* Replaces the whole section, so a removal never leaves a stale tail. */
    WritePrivateProfileSectionA(LK_GROUP_RASTER, buf, store_path());
    free(buf);
}

static int
in_list(const char *const *list, int n, const char *path)
{
    for (int i = 0; i < n; i++)
        if (list[i] != NULL && _stricmp(list[i], path) == 0)
            return 1;
    return 0;
}

/* Rebuild the list around one edit of `n_edit` paths. op: 0 = append
 * (enabled, deduped, moved to the tail), 1 = remove, 2 = set the enabled
 * flag to `arg`. One load + one save, whatever the batch size. */
static void
edit_rasters(const char *const *edit, int n_edit, int op, int arg)
{
    if (edit == NULL || n_edit <= 0)
        return;

    int *enabled = NULL;
    char **existing = lk_store_load_rasters(&enabled);

    const char **paths = (const char **)malloc(LK_MAX_RASTERS * sizeof *paths);
    int *flags = (int *)malloc(LK_MAX_RASTERS * sizeof *flags);
    if (paths == NULL || flags == NULL) {
        free(paths);
        free(flags);
        lk_store_free_rasters(existing, enabled);
        return;
    }

    int n = 0;
    for (int i = 0; existing && existing[i] != NULL && n < LK_MAX_RASTERS; i++) {
        int hit = in_list(edit, n_edit, existing[i]);
        if (hit && (op == 0 || op == 1))
            continue; /* re-added at the tail / removed */
        paths[n] = existing[i];
        flags[n] = (hit && op == 2) ? (arg ? 1 : 0) : enabled[i];
        n++;
    }
    if (op == 0) {
        for (int j = 0; j < n_edit && n < LK_MAX_RASTERS; j++) {
            if (edit[j] == NULL || edit[j][0] == '\0')
                continue;
            if (in_list(edit, j, edit[j]))
                continue; /* duplicate within the batch itself */
            paths[n] = edit[j];
            flags[n] = 1;
            n++;
        }
    }

    save_rasters(paths, flags, n);
    free(paths);
    free(flags);
    lk_store_free_rasters(existing, enabled);
}

void
lk_store_note_raster(const char *path)
{
    edit_rasters(&path, 1, 0, 0);
}

void
lk_store_forget_raster(const char *path)
{
    edit_rasters(&path, 1, 1, 0);
}

void
lk_store_set_raster_enabled(const char *path, int enabled)
{
    edit_rasters(&path, 1, 2, enabled);
}

void
lk_store_note_rasters(const char *const *paths, int n)
{
    edit_rasters(paths, n, 0, 0);
}

void
lk_store_forget_rasters(const char *const *paths, int n)
{
    edit_rasters(paths, n, 1, 0);
}

void
lk_store_set_rasters_enabled(const char *const *paths, int n, int enabled)
{
    edit_rasters(paths, n, 2, enabled);
}

void
lk_store_free_rasters(char **paths, int *enabled)
{
    if (paths != NULL) {
        for (int i = 0; paths[i] != NULL; i++)
            free(paths[i]);
        free(paths);
    }
    free(enabled);
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

/* ---- plugin settings ----------------------------------------------------- */

#define LK_GROUP_PLUGINS "plugins.v1"

void
lk_store_save_plugin_config(const char *plugin_id, const char *json)
{
    if (plugin_id == NULL)
        return;
    set_str(LK_GROUP_PLUGINS, plugin_id, json);
}

void
lk_store_apply_saved_plugins(lookout *h)
{
    if (h == NULL)
        return;

    /* The screenshot protocol's clean slate: every plugin stays on its
     * manifest defaults. Without this a capture instance dials the
     * developer's own instruments and publishes real vessel names and
     * MMSIs (see macos PluginSettings.applySaved). */
    if (GetEnvironmentVariableA("LOOKOUT_CLEAN", NULL, 0) > 0)
        return;

    /* A NULL key name asks the profile API for the section's key names, packed
     * as a run of NUL-terminated strings ended by an empty one. */
    char names[8192];
    DWORD n = GetPrivateProfileStringA(LK_GROUP_PLUGINS, NULL, "", names,
                                       (DWORD)sizeof names, store_path());
    if (n == 0)
        return;

    /* One plugin's object. Far past any real list of connections (8 rows is
     * the cap); a value at the buffer edge was truncated by the profile API
     * and would not parse, so it is skipped rather than pushed as half an
     * object — and it is SAID, because a silently dropped list is a mariner's
     * lost connections. */
    static const size_t VALUE_MAX = 65536;
    char *value = (char *)malloc(VALUE_MAX);
    if (value == NULL)
        return;

    for (const char *id = names; *id != '\0'; id += strlen(id) + 1) {
        DWORD len = GetPrivateProfileStringA(LK_GROUP_PLUGINS, id, "", value,
                                             (DWORD)VALUE_MAX, store_path());
        if (len == 0)
            continue;
        if (len >= VALUE_MAX - 2) {
            fprintf(stderr, "store: %s: saved plugin settings truncated; not applied\n", id);
            continue;
        }
        lookout_plugin_config_set(h, id, value);
    }
    free(value);
}
