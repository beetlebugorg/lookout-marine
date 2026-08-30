/* lk_utf8 — see lk_utf8.h. */
#include "lk_utf8.h"

namespace lkw
{
    bool IsUtf8(std::string_view text)
    {
        size_t i = 0;
        while (i < text.size())
        {
            unsigned char c = (unsigned char)text[i];
            if (c < 0x80)
            {
                i++;
                continue;
            }

            int extra;
            uint32_t code;
            if ((c & 0xE0) == 0xC0)
            {
                extra = 1;
                code = c & 0x1Fu;
            }
            else if ((c & 0xF0) == 0xE0)
            {
                extra = 2;
                code = c & 0x0Fu;
            }
            else if ((c & 0xF8) == 0xF0)
            {
                extra = 3;
                code = c & 0x07u;
            }
            else
            {
                return false; /* a continuation byte or 0xF8+ can't start one */
            }

            if (i + (size_t)extra >= text.size())
                return false;
            for (int k = 1; k <= extra; k++)
            {
                unsigned char cc = (unsigned char)text[i + (size_t)k];
                if ((cc & 0xC0) != 0x80)
                    return false;
                code = (code << 6) | (cc & 0x3Fu);
            }

            /* The forms that are well-formed byte by byte and still not a
             * character: an overlong encoding, a surrogate half, and anything
             * past the last plane. */
            if (extra == 1 && code < 0x80)
                return false;
            if (extra == 2 && code < 0x800)
                return false;
            if (extra == 3 && code < 0x10000)
                return false;
            if (code >= 0xD800 && code <= 0xDFFF)
                return false;
            if (code > 0x10FFFF)
                return false;

            i += (size_t)extra + 1;
        }
        return true;
    }

    std::string Utf8OrLatin1(std::string_view text)
    {
        if (IsUtf8(text))
            return std::string(text);

        std::string out;
        out.reserve(text.size() * 2);
        for (unsigned char c : text)
        {
            if (c < 0x80)
            {
                out += (char)c;
            }
            else
            {
                out += (char)(0xC0 | (c >> 6));
                out += (char)(0x80 | (c & 0x3F));
            }
        }
        return out;
    }
}
