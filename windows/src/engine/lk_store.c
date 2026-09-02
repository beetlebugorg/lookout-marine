/* lk_store — see lk_store.h. */
#include "lk_store.h"

#include <windows.h>

#include <shlobj.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The groups. Six are the core's, named in lookout-shell.h so a setting means
 * the same thing on every shell. `window` is this shell's own: where a window
 * was left is the platform's business and no other shell keeps one. */
#define LK_GROUP_WINDOW "window"

/* How many recents the File menu offers. */
#define LK_MAX_RECENTS 10

static lookout_store *store;
static char store_dir[MAX_PATH];

static void import_legacy(void);

/* The store, opened on the first call and kept for the process. NULL only
 * when it cannot be allocated, which every caller below tolerates. */
static lookout_store *
handle(void)
{
    if (store != NULL)
        return store;

    if (store_dir[0] == '\0') {
        PWSTR roaming = NULL;
        if (SHGetKnownFolderPath(&FOLDERID_RoamingAppData, 0, NULL, &roaming) != S_OK)
            return NULL;
        int n = WideCharToMultiByte(CP_UTF8, 0, roaming, -1, store_dir,
                                    (int)sizeof store_dir, NULL, NULL);
        CoTaskMemFree(roaming);
        if (n <= 0)
            return NULL;
        strncat_s(store_dir, sizeof store_dir, "\\lookout-marine", _TRUNCATE);
    }

    store = lookout_store_open(store_dir);
    if (store != NULL)
        import_legacy();
    return store;
}

lookout_store *
lk_store_handle(void)
{
    return handle();
}

void
lk_store_set_dir(const char *dir)
{
    if (dir == NULL || dir[0] == '\0')
        return;
    strncpy_s(store_dir, sizeof store_dir, dir, _TRUNCATE);
}

void
lk_store_shutdown(void)
{
    if (store != NULL)
        lookout_store_close(store);
    store = NULL;
}

/* A choice the mariner made by hand reaches the disk at once, which is what
 * the profile API did. The engine's own writes ride the coalesce window. */
static void
wrote(void)
{
    if (store != NULL)
        lookout_store_flush(store);
}

/* ---- lists --------------------------------------------------------------- */

/* A borrowed list as the NULL-terminated array the callers own. Never NULL
 * unless the allocation fails. */
static char **
load_list(const char *group, const char *key)
{
    size_t count = 0;
    const char *const *items = lookout_store_list(handle(), group, key, &count);
    char **out = (char **)calloc(count + 1, sizeof *out);
    if (out == NULL)
        return NULL;
    size_t n = 0;
    for (size_t i = 0; i < count; i++) {
        if (items[i] == NULL)
            continue;
        out[n] = _strdup(items[i]);
        if (out[n] != NULL)
            n++;
    }
    out[n] = NULL;
    return out;
}

static void
save_list(const char *group, const char *key, const char *const *items, int n)
{
    lookout_store_set_list(handle(), group, key, items, n < 0 ? 0 : (size_t)n);
}

static int
in_list(const char *const *list, int n, const char *path)
{
    for (int i = 0; i < n; i++)
        if (list[i] != NULL && _stricmp(list[i], path) == 0)
            return 1;
    return 0;
}

static int
count_list(char **list)
{
    int n = 0;
    while (list != NULL && list[n] != NULL)
        n++;
    return n;
}

/* ---- the camera pose ------------------------------------------------------ */

int
lk_store_has_saved_view(void)
{
    return lookout_store_has(handle(), LOOKOUT_STORE_VIEW, "lon");
}

/* ---- recents -------------------------------------------------------------- */

char **
lk_store_load_recents(void)
{
    return load_list(LOOKOUT_STORE_RECENTS, "paths");
}

void
lk_store_note_recent(const char *path)
{
    if (path == NULL || path[0] == '\0')
        return;

    char **existing = lk_store_load_recents();
    const char **merged = (const char **)malloc(LK_MAX_RECENTS * sizeof *merged);
    if (merged == NULL) {
        lk_store_free_recents(existing);
        return;
    }

    int n = 0;
    merged[n++] = path;
    for (int i = 0; existing != NULL && existing[i] != NULL && n < LK_MAX_RECENTS; i++)
        if (_stricmp(existing[i], path) != 0)
            merged[n++] = existing[i];

    save_list(LOOKOUT_STORE_RECENTS, "paths", merged, n);
    wrote();
    free(merged);
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

/* ---- the settings window --------------------------------------------------- */

int
lk_store_load_settings_size(int *width, int *height)
{
    return lk_store_load_frame("settings", width, height);
}

void
lk_store_save_settings_size(int width, int height)
{
    lk_store_save_frame("settings", width, height);
}

int
lk_store_load_frame(const char *name, int *width, int *height)
{
    if (name == NULL || width == NULL || height == NULL)
        return 0;
    char kw[160], kh[160];
    snprintf(kw, sizeof kw, "%s_w", name);
    snprintf(kh, sizeof kh, "%s_h", name);
    lookout_store *s = handle();
    if (!lookout_store_has(s, LK_GROUP_WINDOW, kw) ||
        !lookout_store_has(s, LK_GROUP_WINDOW, kh))
        return 0;
    int w = (int)lookout_store_number(s, LK_GROUP_WINDOW, kw, 0);
    int h = (int)lookout_store_number(s, LK_GROUP_WINDOW, kh, 0);
    if (w <= 0 || h <= 0)
        return 0;
    *width = w;
    *height = h;
    return 1;
}

void
lk_store_save_frame(const char *name, int width, int height)
{
    if (name == NULL || width <= 0 || height <= 0)
        return;
    char kw[160], kh[160];
    snprintf(kw, sizeof kw, "%s_w", name);
    snprintf(kh, sizeof kh, "%s_h", name);
    lookout_store_set_number(handle(), LK_GROUP_WINDOW, kw, width);
    lookout_store_set_number(handle(), LK_GROUP_WINDOW, kh, height);
    wrote();
}

/* ---- raster charts --------------------------------------------------------- */

/* The library is two lists: every path the mariner installed, in the order
 * added, and the ones switched off. Off means installed and quiet: a
 * half-gigabyte download is switched off rather than deleted. */

char **
lk_store_load_rasters(int **enabled_out)
{
    if (enabled_out != NULL)
        *enabled_out = NULL;

    char **paths = load_list(LOOKOUT_STORE_RASTER, "paths");
    if (paths == NULL || enabled_out == NULL)
        return paths;

    char **off = load_list(LOOKOUT_STORE_RASTER, "off");
    int n_off = count_list(off);
    int n = count_list(paths);
    int *enabled = (int *)calloc((size_t)n + 1, sizeof *enabled);
    if (enabled != NULL)
        for (int i = 0; i < n; i++)
            enabled[i] = !in_list((const char *const *)off, n_off, paths[i]);
    lk_store_free_recents(off);
    *enabled_out = enabled;
    return paths;
}

/* Rebuild the library around one edit of `n_edit` paths. op: 0 = append
 * (enabled, deduped, moved to the tail), 1 = remove, 2 = set the enabled flag
 * to `arg`. One load and one save whatever the batch size, because a baked
 * BSB bundle adds hundreds of sheets at once. */
static void
edit_rasters(const char *const *edit, int n_edit, int op, int arg)
{
    if (edit == NULL || n_edit <= 0)
        return;

    int *enabled = NULL;
    char **existing = lk_store_load_rasters(&enabled);
    if (existing == NULL || enabled == NULL) {
        lk_store_free_rasters(existing, enabled);
        return;
    }
    int have = count_list(existing);

    const char **paths = (const char **)malloc((size_t)(have + n_edit) * sizeof *paths);
    const char **off = (const char **)malloc((size_t)(have + n_edit) * sizeof *off);
    if (paths == NULL || off == NULL) {
        free(paths);
        free(off);
        lk_store_free_rasters(existing, enabled);
        return;
    }

    int n = 0, n_off = 0;
    for (int i = 0; i < have; i++) {
        int hit = in_list(edit, n_edit, existing[i]);
        if (hit && (op == 0 || op == 1))
            continue; /* re-added at the tail, or removed */
        int on = (hit && op == 2) ? (arg != 0) : enabled[i];
        paths[n++] = existing[i];
        if (!on)
            off[n_off++] = existing[i];
    }
    if (op == 0) {
        for (int j = 0; j < n_edit; j++) {
            if (edit[j] == NULL || edit[j][0] == '\0')
                continue;
            if (in_list(edit, j, edit[j]))
                continue; /* a duplicate inside the batch itself */
            paths[n++] = edit[j];
        }
    }

    save_list(LOOKOUT_STORE_RASTER, "paths", paths, n);
    save_list(LOOKOUT_STORE_RASTER, "off", off, n_off);
    wrote();
    free(paths);
    free(off);
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
lk_store_clear_rasters(void)
{
    save_list(LOOKOUT_STORE_RASTER, "paths", NULL, 0);
    save_list(LOOKOUT_STORE_RASTER, "off", NULL, 0);
    /* The hidden-set list goes with the library it described: entries are
     * keyed by set name, and a stale one makes the same file added again
     * months later come back not drawn. */
    save_list(LOOKOUT_STORE_RASTER, "hidden", NULL, 0);
    wrote();
}

void
lk_store_free_rasters(char **paths, int *enabled)
{
    lk_store_free_recents(paths);
    free(enabled);
}

/* ---- raster shown state ---------------------------------------------------- */

char **
lk_store_load_hidden_sets(void)
{
    return load_list(LOOKOUT_STORE_RASTER, "hidden");
}

void
lk_store_save_hidden_sets(const char *const *names, int n)
{
    save_list(LOOKOUT_STORE_RASTER, "hidden", names, n);
    wrote();
}

int
lk_store_chart_hidden(void)
{
    return lookout_store_flag(handle(), LOOKOUT_STORE_RASTER, "chart_hidden", 0) != 0;
}

void
lk_store_set_chart_hidden(int hidden)
{
    lookout_store_set_flag(handle(), LOOKOUT_STORE_RASTER, "chart_hidden", hidden != 0);
    wrote();
}

/* ---- chart links ------------------------------------------------------------ */

static char *
load_text(const char *group, const char *key)
{
    const char *value = lookout_store_text(handle(), group, key);
    return value != NULL && value[0] != '\0' ? _strdup(value) : NULL;
}

static void
save_text(const char *group, const char *key, const char *value)
{
    if (value == NULL || value[0] == '\0')
        lookout_store_remove(handle(), group, key);
    else
        lookout_store_set_text(handle(), group, key, value);
    wrote();
}

char *
lk_store_load_chartlinks(void)
{
    return load_text(LOOKOUT_STORE_CHARTLINKS, "links");
}

void
lk_store_save_chartlinks(const char *json)
{
    save_text(LOOKOUT_STORE_CHARTLINKS, "links", json);
}

int
lk_store_load_chartlink_active(char *out, int out_len)
{
    if (out == NULL || out_len <= 0)
        return 0;
    out[0] = '\0';
    const char *url = lookout_store_text(handle(), LOOKOUT_STORE_CHARTLINKS, "active");
    if (url == NULL)
        return 0;
    strncpy_s(out, (size_t)out_len, url, _TRUNCATE);
    return 1;
}

void
lk_store_save_chartlink_active(const char *url)
{
    save_text(LOOKOUT_STORE_CHARTLINKS, "active", url);
}

/* ---- plugin settings --------------------------------------------------------- */

void
lk_store_save_plugin_config(const char *plugin_id, const char *json)
{
    if (plugin_id == NULL || plugin_id[0] == '\0' || json == NULL)
        return;
    lookout_store_set_text(handle(), LOOKOUT_STORE_PLUGINS, plugin_id, json);
    wrote();
}

void
lk_store_each_plugin_config(void (*fn)(void *user, const char *id, const char *json),
                            void *user)
{
    if (fn == NULL)
        return;

    /* The screenshot protocol's clean slate: every plugin stays on its
     * manifest defaults. Without this a capture instance dials the
     * developer's own instruments and publishes real vessel names and
     * MMSIs. */
    if (GetEnvironmentVariableA("LOOKOUT_CLEAN", NULL, 0) > 0)
        return;

    lookout_store *s = handle();
    size_t count = 0;
    const char *const *ids = lookout_store_keys(s, LOOKOUT_STORE_PLUGINS, &count);
    /* A read is borrowed until the next write, and `fn` may write: the ids are
     * copied out before any of them is handed over. */
    char **owned = (char **)calloc(count + 1, sizeof *owned);
    if (owned == NULL)
        return;
    size_t n = 0;
    for (size_t i = 0; i < count; i++) {
        if (ids[i] == NULL)
            continue;
        owned[n] = _strdup(ids[i]);
        if (owned[n] != NULL)
            n++;
    }
    for (size_t i = 0; i < n; i++) {
        const char *borrowed = lookout_store_text(s, LOOKOUT_STORE_PLUGINS, owned[i]);
        if (borrowed == NULL || borrowed[0] == '\0')
            continue;
        /* `fn` applies the config, and applying one may write: the object is
         * copied out of the read arena before it is handed over. */
        char *json = _strdup(borrowed);
        if (json == NULL)
            continue;
        fn(user, owned[i], json);
        free(json);
    }
    lk_store_free_recents(owned);
}

/* ---- the one-time read of what an older build wrote -------------------------
 *
 * Builds before the core owned the file kept the settings as an INI at
 * settings.ini through the Win32 profile API, with four lists beside it:
 * rasters.list and chartsets.list ("1|path" a line, the flag first),
 * rasters.hidden (a set name a line) and chartlinks.json. They are read once,
 * into the same groups and under the same key names, and left on disk, so a
 * mariner keeps their library, their connections and their display settings
 * across the update.
 *
 * `view/imported` marks it done, which is the same stamp the linux and apple
 * shells use for their own one-time copy. */

static const char *
legacy_path(const char *name, char *out, size_t out_len)
{
    snprintf(out, out_len, "%s\\%s", store_dir, name);
    return out;
}

static const char *
ini_path(void)
{
    static char path[MAX_PATH];
    return legacy_path("settings.ini", path, sizeof path);
}

#define LK_INI_MISSING "\x01"

static int
ini_text(const char *group, const char *key, char *out, int out_len)
{
    GetPrivateProfileStringA(group, key, LK_INI_MISSING, out, (DWORD)out_len, ini_path());
    return strcmp(out, LK_INI_MISSING) != 0;
}

static void
import_text(const char *group, const char *key)
{
    char value[8192];
    if (ini_text(group, key, value, (int)sizeof value) && value[0] != '\0')
        lookout_store_set_text(store, group, key, value);
}

static void
import_number(const char *group, const char *key)
{
    char value[64];
    if (!ini_text(group, key, value, (int)sizeof value) || value[0] == '\0')
        return;
    char *end = NULL;
    double d = strtod(value, &end);
    if (end != value && *end == '\0')
        lookout_store_set_number(store, group, key, d);
}

static void
import_flag(const char *group, const char *key)
{
    char value[64];
    if (!ini_text(group, key, value, (int)sizeof value) || value[0] == '\0')
        return;
    lookout_store_set_flag(store, group, key, strcmp(value, "0") != 0);
}

/* Every key of a group, as text. This is how the plugin configs cross: one
 * config object per plugin id, under whatever ids that build had saved. */
static void
import_group_text(const char *group)
{
    char names[8192];
    DWORD n = GetPrivateProfileStringA(group, NULL, "", names, (DWORD)sizeof names,
                                       ini_path());
    if (n == 0)
        return;
    for (const char *key = names; *key != '\0'; key += strlen(key) + 1)
        import_text(group, key);
}

/* The recents were a count and one item%d key each. */
static void
import_recents(void)
{
    int count = 0;
    char value[64];
    if (ini_text(LOOKOUT_STORE_RECENTS, "count", value, (int)sizeof value))
        count = atoi(value);
    if (count <= 0)
        return;
    if (count > LK_MAX_RECENTS)
        count = LK_MAX_RECENTS;

    char **paths = (char **)calloc((size_t)count + 1, sizeof *paths);
    if (paths == NULL)
        return;
    int n = 0;
    for (int i = 0; i < count; i++) {
        char key[32], path[MAX_PATH];
        snprintf(key, sizeof key, "item%d", i);
        if (!ini_text(LOOKOUT_STORE_RECENTS, key, path, (int)sizeof path) || path[0] == '\0')
            continue;
        paths[n] = _strdup(path);
        if (paths[n] != NULL)
            n++;
    }
    if (n > 0)
        save_list(LOOKOUT_STORE_RECENTS, "paths", (const char *const *)paths, n);
    lk_store_free_recents(paths);
}

/* One "1|path" per line into a paths list and an off list. */
static void
import_flagged_lines(const char *name, const char *group)
{
    char path[MAX_PATH];
    FILE *f = NULL;
    if (fopen_s(&f, legacy_path(name, path, sizeof path), "rb") != 0 || f == NULL)
        return;

    char **paths = NULL;
    char **off = NULL;
    int n = 0, n_off = 0, cap = 0;
    char line[MAX_PATH * 2];
    while (fgets(line, (int)sizeof line, f) != NULL) {
        size_t len = strlen(line);
        while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r'))
            line[--len] = '\0';
        if (len < 3 || (line[0] != '0' && line[0] != '1') || line[1] != '|')
            continue;
        if (n == cap) {
            int grown = cap == 0 ? 32 : cap * 2;
            char **p = (char **)realloc(paths, (size_t)(grown + 1) * sizeof *p);
            char **o = (char **)realloc(off, (size_t)(grown + 1) * sizeof *o);
            if (p != NULL)
                paths = p;
            if (o != NULL)
                off = o;
            if (p == NULL || o == NULL)
                break;
            cap = grown;
        }
        paths[n] = _strdup(line + 2);
        if (paths[n] == NULL)
            continue;
        if (line[0] == '0')
            off[n_off++] = paths[n];
        n++;
    }
    fclose(f);

    if (n > 0) {
        save_list(group, "paths", (const char *const *)paths, n);
        save_list(group, "off", (const char *const *)off, n_off);
    }
    if (paths != NULL) {
        for (int i = 0; i < n; i++)
            free(paths[i]);
        free(paths);
    }
    free(off);
}

/* One name per line, into a list. */
static void
import_lines(const char *name, const char *group, const char *key)
{
    char path[MAX_PATH];
    FILE *f = NULL;
    if (fopen_s(&f, legacy_path(name, path, sizeof path), "rb") != 0 || f == NULL)
        return;

    char **names = NULL;
    int n = 0, cap = 0;
    char line[512];
    while (fgets(line, (int)sizeof line, f) != NULL) {
        size_t len = strlen(line);
        while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r'))
            line[--len] = '\0';
        if (len == 0)
            continue;
        if (n == cap) {
            int grown = cap == 0 ? 32 : cap * 2;
            char **p = (char **)realloc(names, (size_t)(grown + 1) * sizeof *p);
            if (p == NULL)
                break;
            names = p;
            cap = grown;
        }
        names[n] = _strdup(line);
        if (names[n] != NULL)
            n++;
    }
    fclose(f);

    if (n > 0)
        save_list(group, key, (const char *const *)names, n);
    if (names != NULL) {
        for (int i = 0; i < n; i++)
            free(names[i]);
        free(names);
    }
}

/* The whole links document, which was a file of its own. */
static void
import_file_text(const char *name, const char *group, const char *key)
{
    char path[MAX_PATH];
    FILE *f = NULL;
    if (fopen_s(&f, legacy_path(name, path, sizeof path), "rb") != 0 || f == NULL)
        return;
    if (fseek(f, 0, SEEK_END) == 0) {
        long size = ftell(f);
        if (size > 0 && fseek(f, 0, SEEK_SET) == 0) {
            char *text = (char *)malloc((size_t)size + 1);
            if (text != NULL) {
                size_t got = fread(text, 1, (size_t)size, f);
                text[got] = '\0';
                if (got > 0)
                    lookout_store_set_text(store, group, key, text);
                free(text);
            }
        }
    }
    fclose(f);
}

static void
import_legacy(void)
{
    if (lookout_store_flag(store, LOOKOUT_STORE_VIEW, "imported", 0))
        return;

    /* The pose. The engine writes these from here on. */
    static const char *const view_keys[] = { "lon", "lat", "zoom", "rotation_deg" };
    for (int i = 0; i < 4; i++)
        import_number(LOOKOUT_STORE_VIEW, view_keys[i]);

    import_recents();

    /* The raster library and the chart sets were files beside the ini. */
    import_flagged_lines("rasters.list", LOOKOUT_STORE_RASTER);
    import_lines("rasters.hidden", LOOKOUT_STORE_RASTER, "hidden");
    import_flag(LOOKOUT_STORE_RASTER, "chart_hidden");
    import_flagged_lines("chartsets.list", LOOKOUT_STORE_CHARTSETS);

    import_file_text("chartlinks.json", LOOKOUT_STORE_CHARTLINKS, "links");
    /* The picked link was filed under the pose, and belongs with its list. */
    char active[8192];
    if (ini_text(LOOKOUT_STORE_VIEW, "chartlink_active", active, (int)sizeof active) &&
        active[0] != '\0')
        lookout_store_set_text(store, LOOKOUT_STORE_CHARTLINKS, "active", active);

    /* The mariner's own display settings, field by field, as they were
     * written. A field an older build never wrote is left at its default. */
    static const char *const mariner_flags[] = {
        "four_shade_water", "display_base", "display_standard", "display_other",
        "text_names", "show_light_descriptions", "text_other", "simplified_points",
        "show_full_sector_lines", "data_quality", "show_isolated_dangers_shallow",
        "show_inform_callouts", "show_meta_bounds", "show_overscale",
        "date_dependent", "highlight_date_dependent",
    };
    static const char *const mariner_numbers[] = {
        "scheme", "depth_unit", "shallow_contour", "safety_contour", "deep_contour",
        "safety_depth", "soundings", "boundary_style", "size_scale",
        "text_size_scale", "sounding_size_scale",
    };
    for (size_t i = 0; i < sizeof mariner_flags / sizeof *mariner_flags; i++)
        import_flag(LOOKOUT_STORE_MARINER, mariner_flags[i]);
    for (size_t i = 0; i < sizeof mariner_numbers / sizeof *mariner_numbers; i++)
        import_number(LOOKOUT_STORE_MARINER, mariner_numbers[i]);
    import_text(LOOKOUT_STORE_MARINER, "date_view");

    /* One config object per plugin id, under whatever ids were saved. */
    import_group_text(LOOKOUT_STORE_PLUGINS);

    /* Where the settings window and the table windows were left. */
    import_group_text(LK_GROUP_WINDOW);

    lookout_store_set_flag(store, LOOKOUT_STORE_VIEW, "imported", 1);
    lookout_store_flush(store);
}
