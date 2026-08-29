/* lk_utf8 — making the engine's bytes safe to show.
 *
 * A cell's attribute text is not always well-formed UTF-8, and an aux file is
 * whatever the office wrote. winrt::to_hstring THROWS on bytes that are not
 * UTF-8, so every string on its way from the engine to a TextBlock has to be
 * known-good before it gets there — otherwise one bad character in one chart
 * takes down a pick report, or the process.
 *
 * The rule is the one the shell has always used: if the text is UTF-8, it is
 * left exactly as it is; if it is not, EVERY byte is read as Latin-1 instead.
 * All or nothing, because a mixed repair invents characters that are in no
 * encoding the office used, and a mariner reading a chart note needs to see
 * what the cell says or see that it is unreadable — not a plausible fiction.
 */
#pragma once

#include <string>
#include <string_view>

namespace lkw
{
    /* True when every byte is part of a well-formed UTF-8 sequence. Rejects
     * overlong forms, surrogates and anything past U+10FFFF, which is what
     * WinRT rejects too. */
    bool IsUtf8(std::string_view text);

    /* `text` when it is UTF-8, else the same bytes read as Latin-1. The result
     * is always valid UTF-8 and always safe to hand to winrt::to_hstring. */
    std::string Utf8OrLatin1(std::string_view text);
}
