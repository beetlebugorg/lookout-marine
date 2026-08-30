// lk_pick — decode a ranked-pick report envelope into the model the pick
// report card lays out. The ENGINE composes the report ({"report":{...},
// "s57":<raw>}); this only parses and flattens, mirroring PickDecoded.kt
// (Android) and PickReport.swift's PickDecoded + S57 (macOS/iOS).
//
// Model code: UTF-8 std::string and no WinRT, so it links into the test
// target. Every string here is valid UTF-8 whatever the cell held (see
// lk_utf8.h), so the card converts with winrt::to_hstring without guarding.
#pragma once

#include <string>
#include <vector>

namespace lkw
{
    // One decoded detail row from report.rows.
    struct PickRow
    {
        std::string label;
        std::string value;
        int depth{ 0 };
        bool file{ false };    // value names an aux file (TXTDSC/NTXTDS/PICREP)
        bool picture{ false }; // that file is a picture
    };

    // One flattened raw S-57/S-101 attribute row (name may be empty for an
    // array element; value is empty for an object/array heading).
    struct RawRow
    {
        std::string name;
        std::string value;
        int depth{ 0 };
    };

    // Why the body has nothing to read; a blank body reads as a defect.
    enum class PickEmpty
    {
        No,           // there is something to read
        NoAttributes, // "The cell carries no attributes for this object."
        SourceOnly,   // "The cell carries only source data for this object."
    };

    struct PickDecoded
    {
        std::string title;    // the operative fact; falls back to cls
        std::string subtitle; // what the object is; may be empty
        std::string chip;     // short list-column name; falls back to cls
        std::string footnote; // provenance; falls back to the chart name
        std::vector<std::string> notes; // promoted INFORM cautions
        std::vector<PickRow> rows;
        PickEmpty empty{ PickEmpty::No };
        std::vector<RawRow> raw; // the raw payload, flattened
    };

    // Decode one pick feature (UTF-8 C strings from lk_controller_pick_at).
    // Never throws: an unparseable payload yields the fallbacks and no rows.
    PickDecoded DecodePick(char const *cls, char const *json, char const *chart);

    // The clipboard form: "<cls>  <chart>" then the raw rows, two spaces per
    // depth — a chart problem gets reported in the cell's own words.
    std::string PickPlainText(char const *cls, char const *json, char const *chart);
}
