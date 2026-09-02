/* lk_table — see lk_table.h. */
#include "lk_table.h"

#include <cmath>
#include <cstdarg>
#include <cstdio>

#include "lk_plugin_registry.h" /* Trimmed: one rule for a number as text */

namespace
{
    std::string Upper(std::string s)
    {
        /* ASCII only, on purpose: a flag is one of the core's own words. */
        for (char &c : s)
            if (c >= 'a' && c <= 'z')
                c = (char)(c - 'a' + 'A');
        return s;
    }

    std::string Printf(char const *fmt, ...)
    {
        char buf[64];
        va_list args;
        va_start(args, fmt);
        std::vsnprintf(buf, sizeof buf, fmt, args);
        va_end(args);
        return buf;
    }
}

namespace lkw
{
    char const *const kMissingCell = "\xe2\x80\x94"; /* em dash */

    bool NumericColumn(lookout_column_type type)
    {
        return type != LOOKOUT_COLUMN_TEXT && type != LOOKOUT_COLUMN_FLAG;
    }

    double ColumnWidth(lookout_column_type type)
    {
        return type == LOOKOUT_COLUMN_TEXT ? 150.0 : 84.0;
    }

    /* A cable is 185.2 m: under that a mariner reads metres, over it nautical
     * miles, which is how a CPA is called on the radio. */
    std::string FormatDistance(double metres)
    {
        if (metres < 185.2)
            return Printf("%.0f m", metres);
        return Printf("%.2f nm", metres / 1852.0);
    }

    std::string FormatSpeed(double metres_per_second)
    {
        return Printf("%.1f kn", metres_per_second * 3600.0 / 1852.0);
    }

    std::string FormatBearing(double degrees)
    {
        double b = std::fmod(degrees, 360.0);
        if (b < 0)
            b += 360.0;
        return Printf("%03.0f\xc2\xb0", b);
    }

    /* Signed, because a time to CPA that has passed is negative and a mariner
     * must be able to see that it has. */
    std::string FormatDuration(double seconds)
    {
        long long t = (long long)std::llround(std::fabs(seconds));
        char const *sign = seconds < 0 ? "-" : "";
        if (t >= 3600)
            return Printf("%s%lld:%02lld:%02lld", sign, t / 3600, (t / 60) % 60, t % 60);
        return Printf("%s%lld:%02lld", sign, t / 60, t % 60);
    }

    /* `type` says how to format the value, `kind` says which field holds it.
     * A plugin may send a string for a numeric column, and the string is what
     * the mariner sees. */
    TableCell FormatCell(lookout_table_cell const &cell)
    {
        if (cell.kind == LOOKOUT_TABLE_CELL_ABSENT)
            return { kMissingCell, true };

        if (cell.kind == LOOKOUT_TABLE_CELL_TEXT)
        {
            std::string s = cell.text != nullptr ? cell.text : std::string{};
            return { cell.type == LOOKOUT_COLUMN_FLAG ? Upper(s) : s, false };
        }

        switch (cell.type)
        {
        case LOOKOUT_COLUMN_DISTANCE: return { FormatDistance(cell.number), false };
        case LOOKOUT_COLUMN_SPEED:    return { FormatSpeed(cell.number), false };
        case LOOKOUT_COLUMN_BEARING:  return { FormatBearing(cell.number), false };
        case LOOKOUT_COLUMN_DURATION: return { FormatDuration(cell.number), false };
        default:
            /* A plain number is written whole when it is whole: "%g" alone
             * turns an identifier past six digits — an MMSI in a number
             * column — into 3.67123e+08, which is not a number anyone can
             * read back to a coastguard. */
            return { Trimmed(cell.number), false };
        }
    }

    TableColumn::TableColumn(lookout_table_column const &c)
        : key{ c.key }, label{ c.label }, type{ c.type }
    {
    }

    TableSpec::TableSpec(lookout_table const &t, std::vector<TableColumn> cols)
        : plugin{ t.plugin }, key{ t.key }, title{ t.title }, columns{ std::move(cols) },
          sort_key{ t.sort_key }, sort_ascending{ t.sort_ascending != 0 },
          /* Both `at` keys are set together, and an empty pair means a row of
           * this table has no position to reveal. */
          locatable{ t.at_lat[0] != '\0' && t.at_lon[0] != '\0' }
    {
    }

    TableRow::TableRow(lookout_table_row const &row, TableSpec const &spec,
                       lookout_table_cell const *const *cells, size_t n)
        : has_at{ spec.locatable && row.located != 0 }, lon{ row.lon }, lat{ row.lat }
    {
        for (size_t i = 0; i < n; ++i)
        {
            this->cells.push_back(FormatCell(*cells[i]));
            /* The flag cell tints the whole row, in the plugin's own word
             * rather than the upper-cased one on screen. */
            if (cells[i]->type == LOOKOUT_COLUMN_FLAG &&
                cells[i]->kind == LOOKOUT_TABLE_CELL_TEXT && cells[i]->text != nullptr)
                flag = cells[i]->text;
        }
    }
}
