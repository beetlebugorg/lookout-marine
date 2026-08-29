/* The pick report decoder.
 *
 * The engine composes the report and the shell lays it out, so what is tested
 * here is the contract between them: the envelope's two halves, the fallbacks
 * that keep a card from ever being blank, and the flattening order of the raw
 * S-57 payload — which is what a mariner copies into a chart-error report, so
 * it has to come out the same every time and the same as the other shells.
 */
#include "lk_test.h"

#include "lk_pick.h"

using namespace lktest;
using lkw::DecodePick;
using lkw::PickEmpty;
using lkw::PickPlainText;

void TestPick()
{
    Suite("lk_pick");

    LK_CASE("the composed report is what the card shows");
    {
        auto d = DecodePick("BOYLAT", R"({"report":{
              "title":"Green can",
              "subtitle":"Lateral buoy",
              "chip":"Buoy",
              "footnote":"US5MD1MC",
              "rows":[{"label":"Colour","value":"green"},
                      {"label":"Shape","value":"can","depth":1}]
            }})",
                            "chart.pmtiles");
        LK_EQ(d.title, std::string("Green can"));
        LK_EQ(d.subtitle, std::string("Lateral buoy"));
        LK_EQ(d.chip, std::string("Buoy"));
        LK_EQ(d.footnote, std::string("US5MD1MC"));
        LK_EQ(d.rows.size(), (size_t)2);
        LK_EQ(d.rows[0].label, std::string("Colour"));
        LK_EQ(d.rows[0].value, std::string("green"));
        LK_EQ(d.rows[0].depth, 0);
        LK_EQ(d.rows[1].depth, 1);
        LK_EQ(d.empty == PickEmpty::No, true);
    }

    /* A card must never be blank: what the report does not say, the class name
     * and the chart name say. */
    LK_CASE("the title, chip and footnote fall back");
    {
        auto d = DecodePick("DEPARE", R"({"report":{}})", "US5MD1MC");
        LK_EQ(d.title, std::string("DEPARE"));
        LK_EQ(d.chip, std::string("DEPARE"));
        LK_EQ(d.footnote, std::string("US5MD1MC"));
        LK_EQ(d.subtitle, std::string("")); /* the one field with no fallback */
    }

    LK_CASE("an empty string in the report is not a value");
    {
        auto d = DecodePick("DEPARE", R"({"report":{"title":"","footnote":""}})", "US5MD1MC");
        LK_EQ(d.title, std::string("DEPARE"));
        LK_EQ(d.footnote, std::string("US5MD1MC"));
    }

    /* A blank body reads as a defect, so the report says why it is blank. */
    LK_CASE("the two reasons a body has nothing to read");
    {
        LK_CHECK(DecodePick("X", R"({"report":{"empty":"none"}})", "c").empty ==
                 PickEmpty::NoAttributes);
        LK_CHECK(DecodePick("X", R"({"report":{"empty":"source"}})", "c").empty ==
                 PickEmpty::SourceOnly);
        LK_CHECK(DecodePick("X", R"({"report":{"empty":"who knows"}})", "c").empty ==
                 PickEmpty::No);
        LK_CHECK(DecodePick("X", R"({"report":{}})", "c").empty == PickEmpty::No);
    }

    LK_CASE("promoted cautions, empty ones dropped");
    {
        auto d = DecodePick("X", R"({"report":{"notes":["Report changes","","Depths unreliable"]}})",
                            "c");
        LK_EQ(d.notes.size(), (size_t)2);
        LK_EQ(d.notes[0], std::string("Report changes"));
        LK_EQ(d.notes[1], std::string("Depths unreliable"));
    }

    LK_CASE("a row that names a file, and one that names a picture");
    {
        auto d = DecodePick("X", R"({"report":{"rows":[
              {"label":"Textual description","value":"US5MD1MC.TXT","file":true},
              {"label":"Pictorial representation","value":"BR.jpg","file":true,"picture":true},
              {"label":"Colour","value":"green"}]}})",
                            "c");
        LK_EQ(d.rows.size(), (size_t)3);
        LK_EQ(d.rows[0].file, true);
        LK_EQ(d.rows[0].picture, false);
        LK_EQ(d.rows[1].file, true);
        LK_EQ(d.rows[1].picture, true);
        LK_EQ(d.rows[2].file, false);
    }

    LK_CASE("a row that is not an object is skipped, not half read");
    {
        auto d = DecodePick("X", R"({"report":{"rows":[{"label":"A"},"junk",17]}})", "c");
        LK_EQ(d.rows.size(), (size_t)1);
        LK_EQ(d.rows[0].label, std::string("A"));
    }

    /* The raw half, flattened. Top-level keys stay at depth 0; an object or
     * array member emits a heading and takes its children one level in. */
    LK_CASE("the raw payload flattens with sorted keys");
    {
        auto d = DecodePick("X", R"({"report":{},"s57":{"OBJNAM":"Thomas Point","COLOUR":"3"}})",
                            "c");
        LK_EQ(d.raw.size(), (size_t)2);
        LK_EQ(d.raw[0].name, std::string("COLOUR")); /* sorted, not as written */
        LK_EQ(d.raw[0].value, std::string("3"));
        LK_EQ(d.raw[0].depth, 0);
        LK_EQ(d.raw[1].name, std::string("OBJNAM"));
    }

    LK_CASE("a nested object emits a heading and indents its keys");
    {
        auto d = DecodePick("X", R"({"report":{},"s57":{"A":1,"Z":{"inner":"v"}}})", "c");
        LK_EQ(d.raw.size(), (size_t)3);
        LK_EQ(d.raw[0].name, std::string("A"));
        LK_EQ(d.raw[0].depth, 0);
        LK_EQ(d.raw[1].name, std::string("Z"));
        LK_EQ(d.raw[1].value, std::string("")); /* a heading carries no value */
        LK_EQ(d.raw[1].depth, 0);
        LK_EQ(d.raw[2].name, std::string("inner"));
        LK_EQ(d.raw[2].depth, 1);
    }

    LK_CASE("an array emits a heading and its items one level in, unnamed");
    {
        auto d = DecodePick("X", R"({"report":{},"s57":{"SORDAT":["1998","2004"]}})", "c");
        LK_EQ(d.raw.size(), (size_t)3);
        LK_EQ(d.raw[0].name, std::string("SORDAT"));
        LK_EQ(d.raw[0].depth, 0);
        LK_EQ(d.raw[1].name, std::string(""));
        LK_EQ(d.raw[1].value, std::string("1998"));
        LK_EQ(d.raw[1].depth, 1);
        LK_EQ(d.raw[2].value, std::string("2004"));
    }

    /* An attribute reads as the cell wrote it: a whole number carries no ".0",
     * and a boolean and a null are not invented text. */
    LK_CASE("scalars as display text");
    {
        auto d = DecodePick("X", R"({"report":{},"s57":{"a":17,"b":2.5,"c":true,"d":null}})", "c");
        LK_EQ(d.raw.size(), (size_t)4);
        LK_EQ(d.raw[0].value, std::string("17"));
        LK_EQ(d.raw[1].value, std::string("2.5"));
        LK_EQ(d.raw[2].value, std::string("true"));
        LK_EQ(d.raw[3].value, std::string(""));
    }

    LK_CASE("no envelope: the whole document is the raw payload");
    {
        auto d = DecodePick("SOUNDG", R"({"VALSOU":4.2})", "US5MD1MC");
        LK_EQ(d.title, std::string("SOUNDG")); /* nothing decoded it */
        LK_EQ(d.rows.size(), (size_t)0);
        LK_EQ(d.raw.size(), (size_t)1);
        LK_EQ(d.raw[0].name, std::string("VALSOU"));
        LK_EQ(d.raw[0].value, std::string("4.2"));
    }

    LK_CASE("an envelope with no raw half has an empty fold");
    {
        auto d = DecodePick("X", R"({"report":{"title":"T"}})", "c");
        LK_EQ(d.title, std::string("T"));
        LK_EQ(d.raw.size(), (size_t)0);
    }

    LK_CASE("an unreadable payload keeps the fallbacks and shows nothing");
    {
        for (char const *bad : { "", "not json", "{", "{\"report\":", "[1,2" })
        {
            auto d = DecodePick("BCNCAR", bad, "US5MD1MC");
            LK_EQ(d.title, std::string("BCNCAR"));
            LK_EQ(d.footnote, std::string("US5MD1MC"));
            LK_EQ(d.rows.size(), (size_t)0);
            LK_EQ(d.raw.size(), (size_t)0);
        }
    }

    LK_CASE("null strings from the engine are not a fault");
    {
        auto d = DecodePick(nullptr, nullptr, nullptr);
        LK_EQ(d.title, std::string(""));
        LK_EQ(d.raw.size(), (size_t)0);
    }

    /* A cell's text is not always well-formed UTF-8. It has to come out
     * showable either way — the card hands it straight to a TextBlock. */
    LK_CASE("a payload that is not UTF-8 still decodes");
    {
        std::string json = "{\"report\":{\"title\":\"caf\xe9\"}}"; /* Latin-1 e-acute */
        auto d = DecodePick("X", json.c_str(), "c");
        LK_EQ(d.title, std::string("caf\xc3\xa9")); /* the same character, as UTF-8 */
    }

    Suite("lk_pick clipboard form");

    LK_CASE("the class, the chart, then the raw rows two spaces per depth");
    {
        std::string text = PickPlainText(
            "BOYLAT", R"({"report":{},"s57":{"OBJNAM":"Bell","SORDAT":["1998"]}})", "US5MD1MC");
        LK_EQ(text, std::string("BOYLAT  US5MD1MC\n"
                                "OBJNAM: Bell\n"
                                "SORDAT:\n"
                                "  1998\n"));
    }

    LK_CASE("an unreadable payload still names the object and the chart");
    {
        LK_EQ(PickPlainText("BOYLAT", "junk", "US5MD1MC"),
              std::string("BOYLAT  US5MD1MC\n"));
    }
}
