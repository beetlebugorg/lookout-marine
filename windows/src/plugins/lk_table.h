/* lk_table — the plugin tables, and the units they are read in.
 *
 * A plugin declares a table: a menu, a title, typed columns and a default
 * sort. The rows arrive already ordered by the core, band first — an alarmed
 * vessel holds the top line whatever column the mariner sorted by.
 *
 * THE UNITS ARE THE SHELL'S. A column TYPE is the unit contract: distance in
 * metres, speed in metres per second, bearing in degrees true, duration in
 * seconds. The plugin sends SI and this converts for the mariner — the
 * reverse of the pick report, which arrives formatted. Every shell converts
 * the same way, which is why it is worth one place and a test.
 *
 * A cell the plugin did not send is a DASH, not a zero: never heard and heard
 * as zero are different values, and on a collision table the difference is the
 * whole point.
 *
 * The windows that lay this out are plugins/ui/Tables.cpp.
 */
#pragma once

#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "lk_plugin_model.h"

namespace lkw
{
    /* The dash for a cell the plugin did not send (U+2014, as UTF-8). */
    extern char const *const kMissingCell;

    /* One cell, formatted for the mariner. `missing` is what greys it. */
    struct TableCell
    {
        std::string text;
        bool missing{ false };
    };

    struct TableRow
    {
        std::vector<TableCell> cells; /* one per declared column, in order */
        std::string flag;             /* the flag column's value, as the plugin wrote it */
        bool has_at{ false };         /* the row carries a position to reveal */
        double lon{ 0 }, lat{ 0 };
    };

    struct TableBatch
    {
        /* The core's sequence number. A batch whose seq has not moved is the
         * same rows, and rebuilding for it flickers a table nobody is
         * feeding once a second. */
        long long seq{ -1 };
        std::vector<TableRow> rows;
    };

    /* The declarations, from lookout_plugin_tables_json. Nothing when the
     * document does not parse. */
    std::optional<std::vector<TableSpec>> ReadTables(std::string_view json);

    /* One batch of rows for `spec`, cells formatted in its columns' units.
     * Nothing when the document does not parse — a malformed batch changes
     * nothing and the next second answers again. */
    std::optional<TableBatch> ReadTableRows(std::string_view json, TableSpec const &spec);

    /* Layout facts that follow from the type, so the header and the cells
     * cannot disagree about them. */
    bool NumericColumn(std::string const &type);
    double ColumnWidth(std::string const &type);

    /* The unit conversions themselves. Metres under a cable, nautical miles
     * over; metres per second as knots; a bearing normalised to three digits;
     * a duration as h:mm:ss or m:ss. */
    std::string FormatDistance(double metres);
    std::string FormatSpeed(double metres_per_second);
    std::string FormatBearing(double degrees);
    std::string FormatDuration(double seconds);
}
