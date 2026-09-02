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
 * The declarations and the rows come from lookout_tables_read and
 * lookout_table_rows_read. Reading the arrays out of one needs a live read, so
 * the window does that call and hands the pieces here.
 *
 * The windows that lay this out are plugins/ui/Tables.cpp.
 */
#pragma once

#include <string>
#include <vector>

#include "lookout.h"

namespace lkw
{
    /* The dash for a cell the plugin did not send (U+2014, as UTF-8). */
    extern char const *const kMissingCell;

    struct TableColumn
    {
        std::string key;
        std::string label;
        lookout_column_type type{ LOOKOUT_COLUMN_TEXT };

        TableColumn() = default;
        explicit TableColumn(lookout_table_column const &c);
    };

    /* One declared plugin table (the AIS Targets list). */
    struct TableSpec
    {
        std::string plugin; /* owning plugin id */
        std::string key;    /* table key within the plugin */
        std::string title;  /* "AIS Targets" */
        std::vector<TableColumn> columns;
        std::string sort_key;       /* declared default sort */
        bool sort_ascending{ true };
        bool locatable{ false }; /* rows carry a position: activate centres the chart */

        TableSpec() = default;
        TableSpec(lookout_table const &t, std::vector<TableColumn> cols);
    };

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

        TableRow() = default;
        /* `cells` is one core cell per declared column, in declaration order.
         * The flag column tints the row, in the plugin's own word rather than
         * the upper-cased one on screen. */
        TableRow(lookout_table_row const &row, TableSpec const &spec,
                 lookout_table_cell const *const *cells, size_t n);
    };

    /* One cell in its column's units. */
    TableCell FormatCell(lookout_table_cell const &cell);

    /* Layout facts that follow from the type, so the header and the cells
     * cannot disagree about them. */
    bool NumericColumn(lookout_column_type type);
    double ColumnWidth(lookout_column_type type);

    /* The unit conversions themselves. Metres under a cable, nautical miles
     * over; metres per second as knots; a bearing normalised to three digits;
     * a duration as h:mm:ss or m:ss. */
    std::string FormatDistance(double metres);
    std::string FormatSpeed(double metres_per_second);
    std::string FormatBearing(double degrees);
    std::string FormatDuration(double seconds);
}
