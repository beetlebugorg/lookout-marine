/* The plugin tables and their units.
 *
 * The plugin sends SI; the shell converts. Every shell converts the same way,
 * so these are the numbers a mariner reads off an AIS table and calls on the
 * radio — and the dash that says a value was never heard, which on a collision
 * table is not the same as zero.
 */
#include "lk_test.h"

#include "lk_table.h"

using namespace lktest;
using namespace lkw;

namespace
{
    /* An AIS Targets declaration, as the ais plugin writes it. */
    char const *kTables = R"({"tables":[
      {"plugin":"org.beetlebug.ais","key":"targets","title":"AIS Targets",
       "at":true,
       "sort":{"key":"cpa","ascending":true},
       "columns":[
         {"key":"flag","label":"","type":"flag"},
         {"key":"name","label":"Name","type":"text"},
         {"key":"cpa","label":"CPA","type":"distance"},
         {"key":"tcpa","label":"TCPA","type":"duration"},
         {"key":"sog","label":"SOG","type":"speed"},
         {"key":"brg","label":"Bearing","type":"bearing"},
         {"key":"mmsi","label":"MMSI","type":"number"}
       ]}]})";

    TableSpec Spec()
    {
        auto tables = ReadTables(kTables);
        return tables && !tables->empty() ? (*tables)[0] : TableSpec{};
    }
}

void TestTable()
{
    Suite("lk_table: units");

    /* A cable is 185.2 m: under it metres, over it nautical miles. */
    LK_CASE("distance");
    {
        LK_EQ(FormatDistance(0), std::string("0 m"));
        LK_EQ(FormatDistance(120), std::string("120 m"));
        LK_EQ(FormatDistance(185.1), std::string("185 m"));
        LK_EQ(FormatDistance(185.2), std::string("0.10 nm"));
        LK_EQ(FormatDistance(1852), std::string("1.00 nm"));
        LK_EQ(FormatDistance(9260), std::string("5.00 nm"));
    }

    LK_CASE("speed, in knots");
    {
        LK_EQ(FormatSpeed(0), std::string("0.0 kn"));
        LK_EQ(FormatSpeed(1852.0 / 3600.0), std::string("1.0 kn"));
        LK_EQ(FormatSpeed(5.144), std::string("10.0 kn"));
    }

    LK_CASE("bearing, three digits and normalised");
    {
        LK_EQ(FormatBearing(0), std::string("000\xc2\xb0"));
        LK_EQ(FormatBearing(7), std::string("007\xc2\xb0"));
        LK_EQ(FormatBearing(359.4), std::string("359\xc2\xb0"));
        LK_EQ(FormatBearing(370), std::string("010\xc2\xb0"));
        LK_EQ(FormatBearing(-10), std::string("350\xc2\xb0"));
        LK_EQ(FormatBearing(720), std::string("000\xc2\xb0"));
    }

    /* A time to CPA that has passed is negative, and a mariner has to be able
     * to see that it has. */
    LK_CASE("duration, signed");
    {
        LK_EQ(FormatDuration(0), std::string("0:00"));
        LK_EQ(FormatDuration(65), std::string("1:05"));
        LK_EQ(FormatDuration(599), std::string("9:59"));
        LK_EQ(FormatDuration(3600), std::string("1:00:00"));
        LK_EQ(FormatDuration(3661), std::string("1:01:01"));
        LK_EQ(FormatDuration(-65), std::string("-1:05"));
        LK_EQ(FormatDuration(-3661), std::string("-1:01:01"));
    }

    Suite("lk_table: declarations");

    LK_CASE("a table declaration");
    {
        auto tables = ReadTables(kTables);
        LK_CHECK(tables.has_value());
        if (!tables || tables->empty())
            return;
        auto const &spec = (*tables)[0];
        LK_EQ(spec.plugin, std::string("org.beetlebug.ais"));
        LK_EQ(spec.key, std::string("targets"));
        LK_EQ(spec.title, std::string("AIS Targets"));
        LK_EQ(spec.locatable, true);
        LK_EQ(spec.sort_key, std::string("cpa"));
        LK_EQ(spec.sort_ascending, true);
        LK_EQ(spec.columns.size(), (size_t)7);
        LK_EQ(spec.columns[2].key, std::string("cpa"));
        LK_EQ(spec.columns[2].type, std::string("distance"));
    }

    /* A row can only be revealed on the chart when the DECLARATION says its
     * rows carry a position. */
    LK_CASE("a table with no at is not locatable");
    {
        auto tables = ReadTables(R"({"tables":[{"plugin":"p","key":"k","title":"T"}]})");
        LK_CHECK(tables.has_value());
        if (tables && !tables->empty())
        {
            LK_EQ((*tables)[0].locatable, false);
            LK_EQ((*tables)[0].sort_ascending, true); /* the default */
        }
    }

    LK_CASE("a column that names no type is text");
    {
        auto tables = ReadTables(R"({"tables":[{"key":"k","columns":[{"key":"c"}]}]})");
        LK_CHECK(tables.has_value());
        if (tables && !tables->empty())
            LK_EQ((*tables)[0].columns[0].type, std::string("text"));
    }

    LK_CASE("no tables, and no readable answer, are different");
    {
        auto none = ReadTables(R"({"tables":[]})");
        LK_CHECK(none.has_value());
        if (none)
            LK_EQ(none->size(), (size_t)0);
        LK_CHECK(!ReadTables("").has_value());
        LK_CHECK(!ReadTables("junk").has_value());
    }

    LK_CASE("the layout facts follow from the type");
    {
        LK_EQ(NumericColumn("distance"), true);
        LK_EQ(NumericColumn("duration"), true);
        LK_EQ(NumericColumn("number"), true);
        LK_EQ(NumericColumn("text"), false);
        LK_EQ(NumericColumn("flag"), false);
        LK_NEAR(ColumnWidth("text"), 150, 0);
        LK_NEAR(ColumnWidth("distance"), 84, 0);
    }

    Suite("lk_table: rows");

    LK_CASE("a batch of rows in the mariner's units");
    {
        auto batch = ReadTableRows(R"({"seq":42,"rows":[
            {"cells":["alarm","VICTORY",120,-65,5.144,7,367123456],
             "at":[-76.48,38.97]}]})",
                                   Spec());
        LK_CHECK(batch.has_value());
        if (!batch || batch->rows.empty())
            return;
        LK_EQ(batch->seq, (long long)42);
        auto const &row = batch->rows[0];
        LK_EQ(row.cells.size(), (size_t)7);
        LK_EQ(row.cells[0].text, std::string("ALARM")); /* a flag is shown upper case */
        LK_EQ(row.cells[1].text, std::string("VICTORY"));
        LK_EQ(row.cells[2].text, std::string("120 m"));
        LK_EQ(row.cells[3].text, std::string("-1:05"));
        LK_EQ(row.cells[4].text, std::string("10.0 kn"));
        LK_EQ(row.cells[5].text, std::string("007\xc2\xb0"));
        LK_EQ(row.cells[6].text, std::string("367123456"));
    }

    /* "%g" alone would make that MMSI 3.67123e+08, which is not a number
     * anyone can read back to a coastguard. */
    LK_CASE("a plain number is written whole when it is whole");
    {
        auto batch = ReadTableRows(R"({"seq":1,"rows":[{"cells":["","",0,0,0,0,2.5]}]})", Spec());
        LK_CHECK(batch.has_value());
        if (batch && !batch->rows.empty())
            LK_EQ(batch->rows[0].cells[6].text, std::string("2.5"));
    }

    /* The flag tints the row, in the plugin's own word — not the upper-cased
     * one on screen. */
    LK_CASE("the flag that tints the row keeps the core's word");
    {
        auto batch = ReadTableRows(R"({"seq":1,"rows":[{"cells":["warning","X"]}]})", Spec());
        LK_CHECK(batch.has_value());
        if (batch && !batch->rows.empty())
        {
            LK_EQ(batch->rows[0].flag, std::string("warning"));
            LK_EQ(batch->rows[0].cells[0].text, std::string("WARNING"));
        }
    }

    /* Never heard and heard as zero are different values. */
    LK_CASE("a cell the plugin did not send is a dash, not a zero");
    {
        auto batch = ReadTableRows(R"({"seq":1,"rows":[{"cells":["","NAMED",null,0]}]})", Spec());
        LK_CHECK(batch.has_value());
        if (!batch || batch->rows.empty())
            return;
        auto const &row = batch->rows[0];
        LK_EQ(row.cells[2].text, std::string("\xe2\x80\x94"));
        LK_EQ(row.cells[2].missing, true);
        LK_EQ(row.cells[3].text, std::string("0:00")); /* heard as zero */
        LK_EQ(row.cells[3].missing, false);
        /* Short of the declared columns: the tail is missing, not absent. */
        LK_EQ(row.cells.size(), (size_t)7);
        LK_EQ(row.cells[6].missing, true);
    }

    LK_CASE("a position a row carries");
    {
        auto batch = ReadTableRows(
            R"({"seq":1,"rows":[{"cells":[],"at":[-76.48,38.97]},{"cells":[]}]})", Spec());
        LK_CHECK(batch.has_value());
        if (!batch || batch->rows.size() < 2)
            return;
        LK_EQ(batch->rows[0].has_at, true);
        LK_NEAR(batch->rows[0].lon, -76.48, 1e-9);
        LK_NEAR(batch->rows[0].lat, 38.97, 1e-9);
        LK_EQ(batch->rows[1].has_at, false);
    }

    LK_CASE("a position on a table that is not locatable is not a reveal");
    {
        TableSpec flat = Spec();
        flat.locatable = false;
        auto batch = ReadTableRows(R"({"seq":1,"rows":[{"cells":[],"at":[-76.48,38.97]}]})", flat);
        LK_CHECK(batch.has_value());
        if (batch && !batch->rows.empty())
            LK_EQ(batch->rows[0].has_at, false);
    }

    LK_CASE("a half-written position is no position");
    {
        auto batch = ReadTableRows(R"({"seq":1,"rows":[{"cells":[],"at":[-76.48]}]})", Spec());
        LK_CHECK(batch.has_value());
        if (batch && !batch->rows.empty())
            LK_EQ(batch->rows[0].has_at, false);
    }

    LK_CASE("an empty table, and an unreadable batch, are different");
    {
        auto empty = ReadTableRows(R"({"seq":9,"rows":[]})", Spec());
        LK_CHECK(empty.has_value());
        if (empty)
        {
            LK_EQ(empty->seq, (long long)9);
            LK_EQ(empty->rows.size(), (size_t)0);
        }
        LK_CHECK(!ReadTableRows("", Spec()).has_value());
        LK_CHECK(!ReadTableRows("{\"seq\":1,", Spec()).has_value());
    }
}
