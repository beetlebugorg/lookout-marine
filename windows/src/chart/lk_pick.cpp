// lk_pick — see lk_pick.h.
#include "lk_pick.h"

#include "lk_utf8.h"

namespace
{
    // A cell states its text in whatever it was published in, and the core
    // hands those bytes over as they are. A TextBlock takes UTF-16 through
    // winrt::to_hstring, which throws on bytes that are not UTF-8, so every
    // string a cell wrote is made safe on the way in (see lk_utf8.h).
    std::string Safe(char const *s)
    {
        return s == nullptr ? std::string{} : lkw::Utf8OrLatin1(s);
    }
}

namespace lkw
{
    PickRow::PickRow(lookout_pick_row const &r)
        : label{ Safe(r.label) }, value{ Safe(r.value) }, depth{ r.depth },
          file{ r.file != 0 }, picture{ r.picture != 0 }
    {
    }

    PickDecoded::PickDecoded(lookout_pick_feature const &f,
                             char const *const *notes, size_t note_n,
                             lookout_pick_row const *const *rows, size_t row_n,
                             lookout_pick_row const *const *source, size_t source_n)
        : cls{ Safe(f.cls) }, chart{ Safe(f.chart) }, title{ Safe(f.title) },
          subtitle{ Safe(f.subtitle) }, chip{ Safe(f.chip) },
          footnote{ Safe(f.footnote) }, empty{ f.empty }
    {
        for (size_t i = 0; i < note_n; ++i)
            this->notes.push_back(Safe(notes[i]));
        for (size_t i = 0; i < row_n; ++i)
            this->rows.emplace_back(*rows[i]);
        for (size_t i = 0; i < source_n; ++i)
            this->source.emplace_back(*source[i]);
    }

    std::string PickPlainText(PickDecoded const &d)
    {
        std::string text = d.cls + "  " + d.chart + "\n";
        for (auto const &r : d.source)
        {
            text.append((size_t)r.depth * 2, ' ');
            if (r.label.empty())
            {
                text += r.value;
            }
            else
            {
                text += r.label;
                text += ":";
                if (!r.value.empty())
                {
                    text += " ";
                    text += r.value;
                }
            }
            text += "\n";
        }
        return text;
    }
}
