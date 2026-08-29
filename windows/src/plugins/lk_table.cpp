/* lk_table — see lk_table.h. */
#include "lk_table.h"

#include <cmath>
#include <cstdarg>
#include <cstdio>

#include "lk_json.h"
#include "lk_plugin_registry.h" /* Trimmed: one rule for a number as text */

namespace
{
    using lkw::json::Kind;
    using lkw::json::Value;

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

    bool NumericColumn(std::string const &type)
    {
        return type != "text" && type != "flag";
    }

    double ColumnWidth(std::string const &type)
    {
        return type == "text" ? 150.0 : 84.0;
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

    namespace
    {
        TableCell FormatCell(std::string const &type, Value const &v)
        {
            if (v.IsNothing())
                return { kMissingCell, true };

            if (type == "text" || type == "flag")
            {
                std::string s = v.kind() == Kind::String ? v.String() : std::string{};
                return { type == "flag" ? Upper(s) : s, false };
            }

            double n = v.Number(0.0);
            if (type == "distance")
                return { FormatDistance(n), false };
            if (type == "speed")
                return { FormatSpeed(n), false };
            if (type == "bearing")
                return { FormatBearing(n), false };
            if (type == "duration")
                return { FormatDuration(n), false };
            /* A plain number is written whole when it is whole: "%g" alone
             * turns an identifier past six digits — an MMSI in a number
             * column — into 3.67123e+08, which is not a number anyone can
             * read back to a coastguard. */
            return { Trimmed(n), false };
        }
    }

    std::optional<std::vector<TableSpec>> ReadTables(std::string_view json)
    {
        auto doc = json::Parse(json);
        if (!doc || doc->kind() != Kind::Object)
            return std::nullopt;

        std::vector<TableSpec> out;
        for (auto const &o : (*doc)["tables"].Items())
        {
            if (o.kind() != Kind::Object)
                continue;
            TableSpec spec;
            spec.plugin = o.MemberString("plugin");
            spec.key = o.MemberString("key");
            spec.title = o.MemberString("title");
            /* `at` present means a row can carry a position, which is what
             * makes a row activate onto the chart. */
            spec.locatable = o.Has("at");
            Value const &sort = o["sort"];
            if (sort.kind() == Kind::Object)
            {
                spec.sort_key = sort.MemberString("key");
                spec.sort_ascending = sort.MemberBool("ascending", true);
            }
            for (auto const &c : o["columns"].Items())
            {
                if (c.kind() != Kind::Object)
                    continue;
                TableColumn col;
                col.key = c.MemberString("key");
                col.label = c.MemberString("label");
                col.type = c.MemberString("type", "text");
                spec.columns.push_back(std::move(col));
            }
            out.push_back(std::move(spec));
        }
        return out;
    }

    std::optional<TableBatch> ReadTableRows(std::string_view json, TableSpec const &spec)
    {
        auto doc = json::Parse(json);
        if (!doc || doc->kind() != Kind::Object)
            return std::nullopt;

        TableBatch batch;
        batch.seq = (long long)doc->MemberNumber("seq", 0);

        for (auto const &rv : (*doc)["rows"].Items())
        {
            if (rv.kind() != Kind::Object)
                continue;
            Value const &cells = rv["cells"];

            TableRow row;
            for (size_t i = 0; i < spec.columns.size(); ++i)
            {
                Value const &v = cells.At(i);
                row.cells.push_back(FormatCell(spec.columns[i].type, v));
                /* The flag cell tints the whole row, in the plugin's own
                 * word rather than the upper-cased one on screen. */
                if (spec.columns[i].type == "flag" && v.kind() == Kind::String)
                    row.flag = v.String();
            }

            Value const &at = rv["at"];
            if (spec.locatable && at.Length() >= 2)
            {
                row.has_at = true;
                row.lon = at.At(0).Number(0);
                row.lat = at.At(1).Number(0);
            }

            batch.rows.push_back(std::move(row));
        }
        return batch;
    }
}
