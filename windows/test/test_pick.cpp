/* The pick report, as the card holds it.
 *
 * The engine composes the report and flattens the source fold, so what is
 * tested here is what this shell still decides: that every field the core
 * hands over reaches the card, and the CLIPBOARD form — which is what a
 * mariner pastes into a chart-error report, so it has to come out the same
 * every time.
 */
#include "lk_test.h"

#include "lk_pick.h"

using namespace lktest;
using lkw::PickDecoded;
using lkw::PickPlainText;
using lkw::PickRow;

namespace
{
    lookout_pick_row Row(char const *label, char const *value, int depth, int file,
                         int picture)
    {
        lookout_pick_row r{};
        r.label = label;
        r.value = value;
        r.depth = depth;
        r.file = file;
        r.picture = picture;
        return r;
    }

    lookout_pick_feature Feature(char const *cls, char const *chart)
    {
        lookout_pick_feature f{};
        f.cls = cls;
        f.chart = chart;
        f.title = "";
        f.subtitle = "";
        f.chip = "";
        f.footnote = "";
        f.empty = LOOKOUT_PICK_READS;
        f.raw = "";
        return f;
    }

    /* One decoded feature out of the pieces a read hands over. */
    PickDecoded Decode(lookout_pick_feature const &f,
                       std::vector<char const *> const &notes,
                       std::vector<lookout_pick_row> const &rows,
                       std::vector<lookout_pick_row> const &source)
    {
        std::vector<lookout_pick_row const *> row_ptrs, source_ptrs;
        for (auto const &r : rows)
            row_ptrs.push_back(&r);
        for (auto const &r : source)
            source_ptrs.push_back(&r);
        return PickDecoded{ f, notes.data(), notes.size(),
                            row_ptrs.data(), row_ptrs.size(),
                            source_ptrs.data(), source_ptrs.size() };
    }
}

void TestPick()
{
    Suite("lk_pick");

    LK_CASE("the composed report is what the card shows");
    {
        lookout_pick_feature f = Feature("BOYLAT", "US5MD1MC");
        f.title = "Green can";
        f.subtitle = "Lateral buoy";
        f.chip = "Green can";
        f.footnote = "US5MD1MC · NOAA · 1:12,000";
        std::vector<lookout_pick_row> rows{ Row("Colour", "green", 0, 0, 0),
                                            Row("Shape", "can", 0, 0, 0) };
        std::vector<char const *> notes{ "Reported adrift 2024." };
        auto d = Decode(f, notes, rows, {});

        LK_EQ(d.cls, std::string("BOYLAT"));
        LK_EQ(d.chart, std::string("US5MD1MC"));
        LK_EQ(d.title, std::string("Green can"));
        LK_EQ(d.subtitle, std::string("Lateral buoy"));
        LK_EQ(d.chip, std::string("Green can"));
        LK_EQ(d.footnote, std::string("US5MD1MC \xc2\xb7 NOAA \xc2\xb7 1:12,000"));
        LK_EQ(d.empty, LOOKOUT_PICK_READS);
        LK_EQ(d.notes.size(), (size_t)1);
        LK_EQ(d.notes[0], std::string("Reported adrift 2024."));
        LK_EQ(d.rows.size(), (size_t)2);
        LK_EQ(d.rows[0].label, std::string("Colour"));
        LK_EQ(d.rows[0].value, std::string("green"));
    }

    /* A blank body reads as a defect, so the card says which of the two it is. */
    LK_CASE("the two reasons a body has nothing to read");
    {
        lookout_pick_feature f = Feature("DEPARE", "US5MD1MC");
        f.empty = LOOKOUT_PICK_NO_ATTRIBUTES;
        LK_EQ(Decode(f, {}, {}, {}).empty, LOOKOUT_PICK_NO_ATTRIBUTES);
        f.empty = LOOKOUT_PICK_SOURCE_ONLY;
        LK_EQ(Decode(f, {}, {}, {}).empty, LOOKOUT_PICK_SOURCE_ONLY);
    }

    LK_CASE("a row that names a file, and one that names a picture");
    {
        std::vector<lookout_pick_row> rows{ Row("Text", "US5MD1MC.TXT", 0, 1, 0),
                                            Row("Picture", "US5MD1MC.TIF", 0, 1, 1) };
        auto d = Decode(Feature("BOYLAT", "US5MD1MC"), {}, rows, {});
        LK_EQ(d.rows[0].file, true);
        LK_EQ(d.rows[0].picture, false);
        LK_EQ(d.rows[1].file, true);
        LK_EQ(d.rows[1].picture, true);
    }

    /* An array element has no name of its own; the fold indents it under the
     * heading above. */
    LK_CASE("the source fold keeps its depths and its unnamed rows");
    {
        std::vector<lookout_pick_row> source{ Row("OBJNAM", "Bell", 0, 0, 0),
                                              Row("SORDAT", "", 0, 0, 0),
                                              Row("", "1998", 1, 0, 0) };
        auto d = Decode(Feature("BOYLAT", "US5MD1MC"), {}, {}, source);
        LK_EQ(d.source.size(), (size_t)3);
        LK_EQ(d.source[1].value, std::string(""));
        LK_EQ(d.source[2].label, std::string(""));
        LK_EQ(d.source[2].depth, 1);
    }

    /* A cell states its text in whatever it was published in. A TextBlock
     * takes UTF-16 and throws on bytes that are not UTF-8, so the card must
     * never be handed any. */
    LK_CASE("a value that is not UTF-8 arrives as UTF-8");
    {
        std::vector<lookout_pick_row> rows{ Row("Name", "caf\xe9", 0, 0, 0) };
        auto d = Decode(Feature("BOYLAT", "US5MD1MC"), {}, rows, {});
        LK_EQ(d.rows[0].value, std::string("caf\xc3\xa9"));
    }

    Suite("lk_pick clipboard form");

    LK_CASE("the class, the chart, then the source rows two spaces per depth");
    {
        std::vector<lookout_pick_row> source{ Row("OBJNAM", "Bell", 0, 0, 0),
                                              Row("SORDAT", "", 0, 0, 0),
                                              Row("", "1998", 1, 0, 0) };
        auto d = Decode(Feature("BOYLAT", "US5MD1MC"), {}, {}, source);
        LK_EQ(PickPlainText(d), std::string("BOYLAT  US5MD1MC\n"
                                            "OBJNAM: Bell\n"
                                            "SORDAT:\n"
                                            "  1998\n"));
    }

    LK_CASE("a feature with no source fold still names the object and the chart");
    {
        auto d = Decode(Feature("BOYLAT", "US5MD1MC"), {}, {}, {});
        LK_EQ(PickPlainText(d), std::string("BOYLAT  US5MD1MC\n"));
    }
}
