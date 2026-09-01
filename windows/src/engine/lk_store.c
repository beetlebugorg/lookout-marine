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

/* One lock over the whole store. The UI thread writes settings while the
 * render thread saves the pose every three seconds; the profile API gives no
 * atomicity across two writers of one file, and interleaved writes have
 * dropped whole sections. Every public entry takes it; internal helpers are
 * named _locked and expect it held. */
static SRWLOCK store_mu = SRWLOCK_INIT;

static void
store_lock(void)
{
    AcquireSRWLockExclusive(&store_mu);
}

static void
store_unlock(void)
{
    ReleaseSRWLockExclusive(&store_mu);
}

/* Where the store lives. Empty means %APPDATA%\lookout-marine, which is the
 * only thing the app ever uses; lk_store_set_dir points it somewhere a test
 * may write.
 *
 * Every file's path is worked out once and kept, so the five buffers live
 * here rather than inside their accessors: moving the directory has to
 * invalidate them all, and a cache one function deep could not be reached. */
static char store_dir[MAX_PATH];
static char path_settings[MAX_PATH];
static char path_rasters[MAX_PATH];
static char path_chartsets[MAX_PATH];
static char path_hidden[MAX_PATH];
static char path_chartlinks[MAX_PATH];

void
lk_store_set_dir(const char *dir)
{
    store_lock();
    if (dir == NULL || dir[0] == '\0')
        store_dir[0] = '\0';
    else
        snprintf(store_dir, sizeof store_dir, "%s", dir);
    path_settings[0] = '\0';
    path_rasters[0] = '\0';
    path_chartsets[0] = '\0';
    path_hidden[0] = '\0';
    path_chartlinks[0] = '\0';
    store_unlock();
}

/* A file beside settings.ini, created on first write. Caller holds the lock
 * (the static buffer is initialized under it). */
static const char *
store_file(const char *name, char *path, size_t path_len)
{
    if (path[0] != '\0')
        return path;

    /* The directory the store lives in, then the file inside it. */
    char dir[MAX_PATH];
    char base[MAX_PATH];
    if (store_dir[0] != '\0')
        snprintf(dir, sizeof dir, "%s", store_dir);
    else if (SUCCEEDED(SHGetFolderPathA(NULL, CSIDL_APPDATA, NULL, 0, base)))
        snprintf(dir, sizeof dir, "%s\\lookout-marine", base);
    else {
        /* Nowhere of our own to write: beside the exe, under a name that
         * cannot be mistaken for anything else there. */
        snprintf(path, path_len, ".\\lookout-%s", name);
        return path;
    }

    CreateDirectoryA(dir, NULL);
    snprintf(path, path_len, "%s\\%s", dir, name);
    return path;
}

/* %APPDATA%\lookout-marine\settings.ini */
static const char *
store_path(void)
{
    return store_file("settings.ini", path_settings, sizeof path_settings);
}

/* %APPDATA%\lookout-marine\rasters.list — the raster library, out of the INI:
 * the profile API truncates a section READ at 32,767 chars whatever buffer it
 * is given, about a fifth of the 968-sheet set this store is sized for, and a
 * truncated load re-saved is a silently shrunk library. */
static const char *
rasters_path(void)
{
    return store_file("rasters.list", path_rasters, sizeof path_rasters);
}

static int load_view_locked(lookout_view *out);
static char **load_recents_locked(void);
static char **load_rasters_locked(int **enabled_out);
static void save_rasters_locked(const char *const *paths, const int *enabled, int n);

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
    store_lock();
    int ok = load_view_locked(out);
    store_unlock();
    return ok;
}

static int
load_view_locked(lookout_view *out)
{
    out->lat = 0;
    out->zoom = 0;
    out->rotation_deg = 0;
    if (!get_double(LK_GROUP_VIEW, "lon", &out->lon))
        return 0;
    get_double(LK_GROUP_VIEW, "lat", &out->lat);
    get_double(LK_GROUP_VIEW, "zoom", &out->zoom);
    get_double(LK_GROUP_VIEW, "rotation_deg", &out->rotation_deg);
    /* The envelope is what a marine chart can CONTAIN, not what the
     * projection can express: no chart lies above ~84°, and that latitude
     * bound alone rejects the corner pose a zoom past ~20 collapses to (lat
     * 85.0509 after the f32 world overrun). Zoom stops at 19: berthing work
     * sits at z16–19 and must restore, while past 19 the f32 world overrun
     * begins. Anything outside is rejected and the open fits the chart
     * instead. Lon keeps the full ±180: the Aleutians cross the dateline. */
    if (!isfinite(out->lon) || out->lon < -180.0 || out->lon > 180.0 ||
        !isfinite(out->lat) || out->lat < -84.0 || out->lat > 84.0 ||
        !isfinite(out->zoom) || out->zoom < 0.0 || out->zoom > 19.0 ||
        !isfinite(out->rotation_deg))
        return 0;
    return 1;
}

void
lk_store_save_view(const lookout_view *view)
{
    if (view == NULL)
        return;
    store_lock();
    set_double(LK_GROUP_VIEW, "lon", view->lon);
    set_double(LK_GROUP_VIEW, "lat", view->lat);
    set_double(LK_GROUP_VIEW, "zoom", view->zoom);
    set_double(LK_GROUP_VIEW, "rotation_deg", view->rotation_deg);
    store_unlock();
}

/* ---- recents ------------------------------------------------------------- */

char **
lk_store_load_recents(void)
{
    store_lock();
    char **out = load_recents_locked();
    store_unlock();
    return out;
}

static char **
load_recents_locked(void)
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

    store_lock();
    char **existing = load_recents_locked();

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
    store_unlock();

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
    store_lock();
    int have = get_int(LK_GROUP_WINDOW, "settings_w", &w) &&
               get_int(LK_GROUP_WINDOW, "settings_h", &h);
    store_unlock();
    if (!have)
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
    store_lock();
    set_int(LK_GROUP_WINDOW, "settings_w", width);
    set_int(LK_GROUP_WINDOW, "settings_h", height);
    store_unlock();
}

int
lk_store_load_frame(const char *name, int *width, int *height)
{
    if (name == NULL || width == NULL || height == NULL)
        return 0;
    char kw[160], kh[160];
    snprintf(kw, sizeof kw, "%s_w", name);
    snprintf(kh, sizeof kh, "%s_h", name);
    int w = 0, h = 0;
    store_lock();
    int have = get_int(LK_GROUP_WINDOW, kw, &w) && get_int(LK_GROUP_WINDOW, kh, &h);
    store_unlock();
    if (!have || w <= 0 || h <= 0)
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
    store_lock();
    set_int(LK_GROUP_WINDOW, kw, width);
    set_int(LK_GROUP_WINDOW, kh, height);
    store_unlock();
}

/* ---- raster charts ------------------------------------------------------- */

/* rasters.list holds one chart per line, "1|path" or "0|path" (the enabled
 * flag first). Lines because a Windows path cannot contain a newline, so
 * nothing needs escaping, and a human can read the library back. Replaced
 * whole through a temp file + MoveFileEx: a torn write must not half-empty
 * the library. */

char **
lk_store_load_rasters(int **enabled_out)
{
    store_lock();
    char **out = load_rasters_locked(enabled_out);
    store_unlock();
    return out;
}

/* The pre-rasters.list layout: one INI section, "item%d" / "enabled%d". Read
 * once for migration, then the section is deleted — the profile API truncates
 * a section read at 32,767 chars, which is why the list moved out. */
static char **
load_rasters_ini_locked(int **enabled_out)
{
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

static char **
load_rasters_locked(int **enabled_out)
{
    if (enabled_out != NULL)
        *enabled_out = NULL;

    FILE *f = fopen(rasters_path(), "rb");
    if (f == NULL) {
        /* No list yet: migrate whatever the INI section holds, once, and
         * take the section down so the two can never disagree. */
        int *en = NULL;
        char **out = load_rasters_ini_locked(&en);
        if (out != NULL && out[0] != NULL) {
            int n = 0;
            while (out[n] != NULL)
                n++;
            save_rasters_locked((const char *const *)out, en, n);
            WritePrivateProfileStringA(LK_GROUP_RASTER, NULL, NULL, store_path());
        }
        if (enabled_out != NULL)
            *enabled_out = en;
        else
            free(en);
        return out;
    }

    char **out = (char **)calloc(LK_MAX_RASTERS + 1, sizeof(char *));
    int *en = (int *)calloc(LK_MAX_RASTERS + 1, sizeof(int));
    char *line = (char *)malloc(MAX_PATH * 2);
    if (out == NULL || en == NULL || line == NULL) {
        free(out); free(en); free(line);
        fclose(f);
        return NULL;
    }

    int n = 0;
    while (n < LK_MAX_RASTERS && fgets(line, MAX_PATH * 2, f) != NULL) {
        size_t len = strlen(line);
        while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r'))
            line[--len] = '\0';
        if (len < 3 || (line[0] != '0' && line[0] != '1') || line[1] != '|')
            continue;
        out[n] = _strdup(line + 2);
        if (out[n] == NULL)
            continue;
        en[n] = line[0] == '1';
        n++;
    }
    fclose(f);
    free(line);
    out[n] = NULL;

    if (enabled_out != NULL)
        *enabled_out = en;
    else
        free(en);
    return out;
}

static void
save_rasters_locked(const char *const *paths, const int *enabled, int n)
{
    char tmp[MAX_PATH + 8];
    snprintf(tmp, sizeof tmp, "%s.tmp", rasters_path());
    FILE *f = fopen(tmp, "wb");
    if (f == NULL)
        return;
    int ok = 1;
    for (int i = 0; i < n; i++) {
        if (fprintf(f, "%d|%s\n", enabled[i] ? 1 : 0, paths[i]) < 0)
            ok = 0;
    }
    if (fclose(f) != 0)
        ok = 0;
    if (!ok) {
        DeleteFileA(tmp);
        return;
    }
    MoveFileExA(tmp, rasters_path(), MOVEFILE_REPLACE_EXISTING);
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

    store_lock();
    int *enabled = NULL;
    char **existing = load_rasters_locked(&enabled);

    const char **paths = (const char **)malloc(LK_MAX_RASTERS * sizeof *paths);
    int *flags = (int *)malloc(LK_MAX_RASTERS * sizeof *flags);
    if (paths == NULL || flags == NULL) {
        free(paths);
        free(flags);
        store_unlock();
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

    save_rasters_locked(paths, flags, n);
    store_unlock();
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
lk_store_clear_rasters(void)
{
    store_lock();
    save_rasters_locked(NULL, NULL, 0);
    store_unlock();
    /* The hidden-set list goes with the library it described (its own lock
     * inside): entries are keyed by set name, and a stale one makes the same
     * file added again months later come back not drawn. */
    lk_store_save_hidden_sets(NULL, 0);
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

/* ---- chart sets ----------------------------------------------------------- */

/* chartsets.list: the folders of charts the mariner has installed, one per line
 * "1|path" / "0|path" — the flag is the set's on/off switch (a set is
 * switched off, not removed, when its water is not today's water). The same
 * shape and the same temp-file replace as rasters.list. */

#define LK_MAX_CHARTSETS 64

static const char *
chartsets_path(void)
{
    return store_file("chartsets.list", path_chartsets, sizeof path_chartsets);
}

static char **
load_chartsets_locked(int **on_out)
{
    if (on_out != NULL)
        *on_out = NULL;
    char **out = (char **)calloc(LK_MAX_CHARTSETS + 1, sizeof(char *));
    int *on = (int *)calloc(LK_MAX_CHARTSETS + 1, sizeof(int));
    if (out == NULL || on == NULL) {
        free(out);
        free(on);
        return NULL;
    }
    FILE *f = fopen(chartsets_path(), "rb");
    int n = 0;
    if (f != NULL) {
        char line[MAX_PATH * 2];
        while (n < LK_MAX_CHARTSETS && fgets(line, sizeof line, f) != NULL) {
            size_t len = strlen(line);
            while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r'))
                line[--len] = '\0';
            if (len < 3 || (line[0] != '0' && line[0] != '1') || line[1] != '|')
                continue;
            out[n] = _strdup(line + 2);
            if (out[n] == NULL)
                continue;
            on[n] = line[0] == '1';
            n++;
        }
        fclose(f);
    }
    out[n] = NULL;
    if (on_out != NULL)
        *on_out = on;
    else
        free(on);
    return out;
}

static void
save_chartsets_locked(const char *const *paths, const int *on, int n)
{
    char tmp[MAX_PATH + 8];
    snprintf(tmp, sizeof tmp, "%s.tmp", chartsets_path());
    FILE *f = fopen(tmp, "wb");
    if (f == NULL)
        return;
    int ok = 1;
    for (int i = 0; i < n; i++) {
        if (fprintf(f, "%d|%s\n", on[i] ? 1 : 0, paths[i]) < 0)
            ok = 0;
    }
    if (fclose(f) != 0)
        ok = 0;
    if (ok)
        MoveFileExA(tmp, chartsets_path(), MOVEFILE_REPLACE_EXISTING);
    else
        DeleteFileA(tmp);
}

char **
lk_store_load_chartsets(int **on_out)
{
    store_lock();
    char **out = load_chartsets_locked(on_out);
    store_unlock();
    return out;
}

/* op: 0 = append (on, deduped), 1 = remove, 2 = set the on flag to `arg`. */
static void
edit_chartsets(const char *path, int op, int arg)
{
    if (path == NULL || path[0] == '\0')
        return;
    store_lock();
    int *on = NULL;
    char **existing = load_chartsets_locked(&on);
    const char *paths[LK_MAX_CHARTSETS];
    int flags[LK_MAX_CHARTSETS];
    int n = 0;
    for (int i = 0; existing && existing[i] != NULL && n < LK_MAX_CHARTSETS; i++) {
        int hit = _stricmp(existing[i], path) == 0;
        if (hit && op == 1)
            continue;
        if (hit && op == 0) {
            store_unlock();
            lk_store_free_rasters(existing, on);
            return; /* already installed, and its switch is the mariner's */
        }
        paths[n] = existing[i];
        flags[n] = (hit && op == 2) ? (arg ? 1 : 0) : on[i];
        n++;
    }
    if (op == 0 && n < LK_MAX_CHARTSETS) {
        paths[n] = path;
        flags[n] = 1;
        n++;
    }
    save_chartsets_locked(paths, flags, n);
    store_unlock();
    lk_store_free_rasters(existing, on);
}

void
lk_store_note_chartset(const char *path)
{
    edit_chartsets(path, 0, 0);
}

void
lk_store_forget_chartset(const char *path)
{
    edit_chartsets(path, 1, 0);
}

void
lk_store_set_chartset_on(const char *path, int on)
{
    edit_chartsets(path, 2, on);
}

/* ---- raster shown state --------------------------------------------------- */

/* Which raster SETS are not drawn, by set name, one per line in
 * rasters.hidden beside the library. Beside it because both describe the same
 * charts, and either living somewhere else is a way for them to drift apart.
 * Not the same thing as a path's enabled flag: off means "installed and
 * quiet" and takes a set out of the pill's list; this is the pill's own
 * choice of which picture covers a water, and a hidden set is still offered.
 * Sets not installed this launch keep their entry: a mariner who unplugs the
 * drive holding one has not changed their mind about it. */

#define LK_MAX_HIDDEN_SETS 256

static const char *
hidden_sets_path(void)
{
    return store_file("rasters.hidden", path_hidden, sizeof path_hidden);
}

char **
lk_store_load_hidden_sets(void)
{
    store_lock();
    char **out = (char **)calloc(LK_MAX_HIDDEN_SETS + 1, sizeof(char *));
    if (out == NULL) {
        store_unlock();
        return NULL;
    }
    FILE *f = fopen(hidden_sets_path(), "rb");
    int n = 0;
    if (f != NULL) {
        char line[512];
        while (n < LK_MAX_HIDDEN_SETS && fgets(line, sizeof line, f) != NULL) {
            size_t len = strlen(line);
            while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r'))
                line[--len] = '\0';
            if (len == 0)
                continue;
            out[n] = _strdup(line);
            if (out[n] != NULL)
                n++;
        }
        fclose(f);
    }
    out[n] = NULL;
    store_unlock();
    return out;
}

void
lk_store_save_hidden_sets(const char *const *names, int n)
{
    store_lock();
    char tmp[MAX_PATH + 8];
    snprintf(tmp, sizeof tmp, "%s.tmp", hidden_sets_path());
    FILE *f = fopen(tmp, "wb");
    if (f == NULL) {
        store_unlock();
        return;
    }
    int ok = 1;
    for (int i = 0; i < n; i++) {
        if (names[i] == NULL || names[i][0] == '\0')
            continue;
        if (fprintf(f, "%s\n", names[i]) < 0)
            ok = 0;
    }
    if (fclose(f) != 0)
        ok = 0;
    if (ok)
        MoveFileExA(tmp, hidden_sets_path(), MOVEFILE_REPLACE_EXISTING);
    else
        DeleteFileA(tmp);
    store_unlock();
}

int
lk_store_chart_hidden(void)
{
    store_lock();
    int v = 0;
    get_int(LK_GROUP_RASTER, "chart_hidden", &v);
    store_unlock();
    return v ? 1 : 0;
}

void
lk_store_set_chart_hidden(int hidden)
{
    store_lock();
    set_int(LK_GROUP_RASTER, "chart_hidden", hidden ? 1 : 0);
    store_unlock();
}

/* ---- chart links ---------------------------------------------------------- */

/* chartlinks.json beside settings.ini: the whole list as one JSON text whose
 * shape the UI layer owns (a TileJSON link carries a generated wrapper style,
 * which is a JSON document itself — a line format would spend its life
 * escaping). Replaced whole through a temp file, like the raster library. */

static const char *
chartlinks_path(void)
{
    return store_file("chartlinks.json", path_chartlinks, sizeof path_chartlinks);
}

char *
lk_store_load_chartlinks(void)
{
    store_lock();
    FILE *f = fopen(chartlinks_path(), "rb");
    if (f == NULL) {
        store_unlock();
        return NULL;
    }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (n <= 0 || n > (16 << 20)) {
        fclose(f);
        store_unlock();
        return NULL;
    }
    char *out = (char *)malloc((size_t)n + 1);
    if (out == NULL) {
        fclose(f);
        store_unlock();
        return NULL;
    }
    size_t got = fread(out, 1, (size_t)n, f);
    fclose(f);
    store_unlock();
    out[got] = '\0';
    return out;
}

void
lk_store_save_chartlinks(const char *json)
{
    if (json == NULL)
        return;
    store_lock();
    char tmp[MAX_PATH + 8];
    snprintf(tmp, sizeof tmp, "%s.tmp", chartlinks_path());
    FILE *f = fopen(tmp, "wb");
    if (f == NULL) {
        store_unlock();
        return;
    }
    int ok = fwrite(json, 1, strlen(json), f) == strlen(json);
    if (fclose(f) != 0)
        ok = 0;
    if (ok)
        MoveFileExA(tmp, chartlinks_path(), MOVEFILE_REPLACE_EXISTING);
    else
        DeleteFileA(tmp);
    store_unlock();
}

int
lk_store_load_chartlink_active(char *out, int out_len)
{
    if (out == NULL || out_len <= 0)
        return 0;
    out[0] = '\0';
    store_lock();
    int have = get_str(LK_GROUP_VIEW, "chartlink_active", out, out_len);
    store_unlock();
    return have && out[0] != '\0';
}

void
lk_store_save_chartlink_active(const char *url)
{
    store_lock();
    set_str(LK_GROUP_VIEW, "chartlink_active", url != NULL ? url : "");
    store_unlock();
}

/* ---- mariner ------------------------------------------------------------- */

void
lk_store_save_mariner(const tile57_mariner *m)
{
    if (m == NULL)
        return;

    store_lock();
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
    store_unlock();
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

    store_lock();
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

    /* Sized from the field it fills, not from a guess: a shorter buffer here
     * silently clipped a date the engine had room for. */
    char date[sizeof m->date_view];
    if (get_str(LK_GROUP_MARINER, "date_view", date, (int)sizeof date)) {
        memset(m->date_view, 0, sizeof m->date_view);
        strncpy(m->date_view, date, sizeof m->date_view - 1);
    }
    store_unlock();
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
    store_lock();
    set_str(LK_GROUP_PLUGINS, plugin_id, json);
    store_unlock();
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
        fn(user, id, value);
    }
    free(value);
}
