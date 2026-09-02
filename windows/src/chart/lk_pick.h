// lk_pick — the pick report as the card lays it out.
//
// The ENGINE composes the report and flattens the source fold
// (lookout_picks_read): the title, the rows, the notes, the footnote and the
// two empty kinds are all its words, and so is the depth-first walk with the
// keys sorted. Reading the arrays out of a read needs a live read, so
// chart/ui/Pick.cpp does that call and this holds what it copied out.
//
// What the CLIPBOARD says is still the shell's: a chart problem gets reported
// in the cell's own words, and how those words are laid out on the way to the
// clipboard is a shell decision.
//
// Model code: UTF-8 std::string and no WinRT. Every string here is valid UTF-8
// whatever the cell held (see lk_utf8.h), so the card converts with
// winrt::to_hstring without guarding.
#pragma once

#include <string>
#include <vector>

#include "lookout.h"

namespace lkw
{
    // One line of the page, or one line of the source fold. The core uses one
    // row type for both. `label` is empty for an element of an array.
    struct PickRow
    {
        std::string label;
        std::string value;
        int depth{ 0 };
        bool file{ false };    // value names an aux file (TXTDSC/NTXTDS/PICREP)
        bool picture{ false }; // that file is a picture

        PickRow() = default;
        explicit PickRow(lookout_pick_row const &r);
    };

    struct PickDecoded
    {
        std::string cls;      // the S-57 class the engine reported
        std::string chart;    // the source cell
        std::string title;    // the operative fact
        std::string subtitle; // what the object is; may be empty
        std::string chip;     // short list-column name
        std::string footnote; // provenance
        std::vector<std::string> notes; // promoted INFORM cautions
        std::vector<PickRow> rows;
        // Why the body has nothing to read; a blank body reads as a defect.
        lookout_pick_empty empty{ LOOKOUT_PICK_READS };
        std::vector<PickRow> source; // the payload, flattened

        PickDecoded() = default;
        // `rows`, `notes` and `source` are the feature's own arrays, which the
        // caller reads out of the live read.
        PickDecoded(lookout_pick_feature const &f,
                    char const *const *notes, size_t note_n,
                    lookout_pick_row const *const *rows, size_t row_n,
                    lookout_pick_row const *const *source, size_t source_n);
    };

    // The clipboard form: "<cls>  <chart>" then the source rows, two spaces
    // per depth.
    std::string PickPlainText(PickDecoded const &d);
}
