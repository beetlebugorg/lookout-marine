/* lk_coord — coordinate parsing and DMS formatting for the Windows shell.
 *
 * Plain C, no dependencies. Ports the coordinate go-to parser from the Linux
 * shell (linux/src/lk-app-model.c lk_coordinate_parse) and the DMS readout
 * format from linux/src/lk-hud.c, so the Windows HUD and search behave
 * identically to macOS/Linux. */
#ifndef LK_COORD_H
#define LK_COORD_H

#ifdef __cplusplus
extern "C" {
#endif

/* Parse "lat, lon". Accepts either a decimal pair (latitude first, comma- or
 * whitespace-separated, e.g. "38.978, -76.492") or a hemisphere/DMS form
 * (e.g. "38 58.5N 76 28.9W", "38°58.8'N 076°29.0'W"). Returns 1 on success and
 * writes *out_lat/*out_lon; 0 if it can't parse a valid lat+lon. */
int lk_coord_parse(const char *text, double *out_lat, double *out_lon);

/* Format one coordinate component as S-52-style DMS "D°MM.mm'H" into dst
 * (e.g. "38°58.80'N"). is_lat picks N/S vs E/W. dst_len should be >= 16. */
void lk_coord_format_dms(double value, int is_lat, char *dst, int dst_len);

/* Parse a chart scale: "25000", "25,000", "1:25000", "25k", "1:2.5M". Text
 * before the last ':' is discarded; whitespace and commas strip; a trailing
 * k/m multiplies by 1e3/1e6. Range-gated to [100, 100,000,000] — a value
 * outside that is not a chart scale. Ports ScaleParser (macos
 * HUDOverlay.swift) / ScaleParser (android GoTo.kt). 1 on success. */
int lk_scale_parse(const char *text, double *out_denom);

#ifdef __cplusplus
}
#endif
#endif /* LK_COORD_H */
