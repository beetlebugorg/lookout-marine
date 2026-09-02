/* The plugin tables and their units.
 *
 * The plugin sends SI and the CORE orders the rows; the shell converts. Every
 * shell converts the same way, so these are the numbers a mariner reads off an
 * AIS table and calls on the radio, and the dash that says a value was never
 * heard, which on a collision table is not the same as zero.
 *
 * Reading the arrays out of a live read is the window's call, so the pieces
 * below are built the way plugins/ui/Tables.cpp hands them over.
 */
#include "lk_test.h"

#include "lk_table.h"

using namespace lktest;
using namespace lkw;

namespace
{
    lookout_table_column Column(char const *key, char const *label, lookout_column_type type)
    {
        lookout_table_column c{};
        c.key = key;
        c.label = label;
        c.type = type;
        return c;
    }

    /* An AIS Targets declaration, as the ais plugin writes it. */
    TableSpec Spec(bool locatable = true)
    {
        lookout_table t{};
        t.plugin = "org.beetlebug.ais";
        t.key = "targets";
        t.title = "AIS Targets";
        t.menu = "Vessels";
        t.sort_key = "cpa";
        t.sort_ascending = 1;
        t.at_lat = locatable ? "lat" : "";
        t.at_lon = locatable ? "lon" : "";
        t.open = 1;
        t.rows = 0;
        t.seq = 0;

        std::vector<lookout_table_column> raw{
            Column("flag", "", LOOKOUT_COLUMN_FLAG),
            Column("name", "Name", LOOKOUT_COLUMN_TEXT),
            Column("cpa", "CPA", LOOKOUT_COLUMN_DISTANCE),
            Column("tcpa", "TCPA", LOOKOUT_COLUMN_DURATION),
            Column("sog", "SOG", LOOKOUT_COLUMN_SPEED),
            Column("brg", "Bearing", LOOKOUT_COLUMN_BEARING),
            Column("mmsi", "MMSI", LOOKOUT_COLUMN_NUMBER),
        };
        std::vector<TableColumn> cols;
        for (auto const &c : raw)
            cols.emplace_back(c);
        return TableSpec{ t, std::move(cols) };
    }

    lookout_table_cell Number(lookout_column_type type, double v)
    {
        lookout_table_cell c{};
        c.type = type;
        c.kind = LOOKOUT_TABLE_CELL_NUMBER;
        c.number = v;
        c.text = "";
        return c;
    }

    lookout_table_cell Words(lookout_column_type type, char const *v)
    {
        lookout_table_cell c{};
        c.type = type;
        c.kind = LOOKOUT_TABLE_CELL_TEXT;
        c.text = v;
        return c;
    }

    lookout_table_cell Absent(lookout_column_type type)
    {
        lookout_table_cell c{};
        c.type = type;
        c.kind = LOOKOUT_TABLE_CELL_ABSENT;
        c.text = "";
        return c;
    }

    /* One row out of the cells the read hands over. */
    TableRow Row(TableSpec const &spec, std::vector<lookout_table_cell> const &cells,
                 bool located, double lon = 0, double lat = 0)
    {
        lookout_table_row r{};
        r.id = "367123456";
        r.band = 0;
        r.located = located ? 1 : 0;
        r.lon = lon;
        r.lat = lat;
        std::vector<lookout_table_cell const *> ptrs;
        for (auto const &c : cells)
            ptrs.push_back(&c);
        return TableRow{ r, spec, ptrs.data(), ptrs.size() };
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
        TableSpec spec = Spec();
        LK_EQ(spec.plugin, std::string("org.beetlebug.ais"));
        LK_EQ(spec.key, std::string("targets"));
        LK_EQ(spec.title, std::string("AIS Targets"));
        LK_EQ(spec.locatable, true);
        LK_EQ(spec.sort_key, std::string("cpa"));
        LK_EQ(spec.sort_ascending, true);
        LK_EQ(spec.columns.size(), (size_t)7);
        LK_EQ(spec.columns[2].key, std::string("cpa"));
        LK_EQ(spec.columns[2].label, std::string("CPA"));
        LK_EQ(spec.columns[2].type, LOOKOUT_COLUMN_DISTANCE);
    }

    /* A row can only be revealed on the chart when the DECLARATION says its
     * rows carry a position. Both keys are set together. */
    LK_CASE("a table that names no position keys is not locatable");
    {
        LK_EQ(Spec(false).locatable, false);
    }

    LK_CASE("the layout facts follow from the type");
    {
        LK_EQ(NumericColumn(LOOKOUT_COLUMN_DISTANCE), true);
        LK_EQ(NumericColumn(LOOKOUT_COLUMN_DURATION), true);
        LK_EQ(NumericColumn(LOOKOUT_COLUMN_NUMBER), true);
        LK_EQ(NumericColumn(LOOKOUT_COLUMN_TEXT), false);
        LK_EQ(NumericColumn(LOOKOUT_COLUMN_FLAG), false);
        LK_NEAR(ColumnWidth(LOOKOUT_COLUMN_TEXT), 150, 0);
        LK_NEAR(ColumnWidth(LOOKOUT_COLUMN_DISTANCE), 84, 0);
    }

    Suite("lk_table: rows");

    LK_CASE("a row in the mariner's units");
    {
        TableSpec spec = Spec();
        TableRow row = Row(spec,
                           { Words(LOOKOUT_COLUMN_FLAG, "alarm"),
                             Words(LOOKOUT_COLUMN_TEXT, "VICTORY"),
                             Number(LOOKOUT_COLUMN_DISTANCE, 120),
                             Number(LOOKOUT_COLUMN_DURATION, -65),
                             Number(LOOKOUT_COLUMN_SPEED, 5.144),
                             Number(LOOKOUT_COLUMN_BEARING, 7),
                             Number(LOOKOUT_COLUMN_NUMBER, 367123456) },
                           true, -76.48, 38.97);
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
        LK_EQ(FormatCell(Number(LOOKOUT_COLUMN_NUMBER, 2.5)).text, std::string("2.5"));
        LK_EQ(FormatCell(Number(LOOKOUT_COLUMN_NUMBER, 367123456)).text,
              std::string("367123456"));
    }

    /* A plugin may send a string for a numeric column, and the string is what
     * the mariner sees. */
    LK_CASE("a string in a numeric column stays a string");
    {
        LK_EQ(FormatCell(Words(LOOKOUT_COLUMN_DISTANCE, "over the horizon")).text,
              std::string("over the horizon"));
    }

    /* The flag tints the row, in the plugin's own word rather than the
     * upper-cased one on screen. */
    LK_CASE("the flag that tints the row keeps the core's word");
    {
        TableSpec spec = Spec();
        TableRow row = Row(spec,
                           { Words(LOOKOUT_COLUMN_FLAG, "warning"),
                             Words(LOOKOUT_COLUMN_TEXT, "X") },
                           false);
        LK_EQ(row.flag, std::string("warning"));
        LK_EQ(row.cells[0].text, std::string("WARNING"));
    }

    /* A row with nothing wrong with it is not a row nobody has heard from. */
    LK_CASE("an empty flag is not a flag");
    {
        TableSpec spec = Spec();
        TableRow row = Row(spec, { Words(LOOKOUT_COLUMN_FLAG, "") }, false);
        LK_EQ(row.flag, std::string(""));
        LK_EQ(row.cells[0].text, std::string(""));
        LK_EQ(row.cells[0].missing, false);
    }

    /* Never heard and heard as zero are different values. */
    LK_CASE("a cell the plugin did not send is a dash, not a zero");
    {
        TableSpec spec = Spec();
        TableRow row = Row(spec,
                           { Words(LOOKOUT_COLUMN_FLAG, ""),
                             Words(LOOKOUT_COLUMN_TEXT, "NAMED"),
                             Absent(LOOKOUT_COLUMN_DISTANCE),
                             Number(LOOKOUT_COLUMN_DURATION, 0) },
                           false);
        LK_EQ(row.cells[2].text, std::string("\xe2\x80\x94"));
        LK_EQ(row.cells[2].missing, true);
        LK_EQ(row.cells[3].text, std::string("0:00")); /* heard as zero */
        LK_EQ(row.cells[3].missing, false);
    }

    LK_CASE("a position a row carries");
    {
        TableSpec spec = Spec();
        TableRow here = Row(spec, {}, true, -76.48, 38.97);
        LK_EQ(here.has_at, true);
        LK_NEAR(here.lon, -76.48, 1e-9);
        LK_NEAR(here.lat, 38.97, 1e-9);

        TableRow nowhere = Row(spec, {}, false);
        LK_EQ(nowhere.has_at, false);
    }

    LK_CASE("a position on a table that is not locatable is not a reveal");
    {
        TableSpec flat = Spec(false);
        LK_EQ(Row(flat, {}, true, -76.48, 38.97).has_at, false);
    }
}
