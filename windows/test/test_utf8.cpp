/* Making the engine's bytes safe to show.
 *
 * Everything here exists because winrt::to_hstring throws on bytes that are
 * not UTF-8, and one malformed attribute in one cell must not be able to take
 * a pick report — or the process — with it.
 */
#include "lk_test.h"

#include "lk_utf8.h"

using namespace lktest;
using lkw::IsUtf8;
using lkw::Utf8OrLatin1;

void TestUtf8()
{
    Suite("lk_utf8");

    LK_CASE("what is UTF-8");
    {
        LK_EQ(IsUtf8(""), true);
        LK_EQ(IsUtf8("plain ascii"), true);
        LK_EQ(IsUtf8("38\xc2\xb0" "58.80'N"), true); /* U+00B0 */
        LK_EQ(IsUtf8("\xe2\x80\x94"), true);         /* U+2014 */
        LK_EQ(IsUtf8("\xf0\x9f\x9a\xa2"), true);     /* U+1F6A2 */
    }

    LK_CASE("what is not");
    {
        LK_EQ(IsUtf8("caf\xe9"), false);         /* a bare Latin-1 byte */
        LK_EQ(IsUtf8("\xc2"), false);            /* a lead byte with no tail */
        LK_EQ(IsUtf8("\xc2\x41"), false);        /* a tail that is not one */
        LK_EQ(IsUtf8("\x80"), false);            /* a continuation byte alone */
        LK_EQ(IsUtf8("\xc0\xaf"), false);        /* overlong '/' */
        LK_EQ(IsUtf8("\xe0\x80\xaf"), false);    /* overlong again */
        LK_EQ(IsUtf8("\xed\xa0\x80"), false);    /* a surrogate half */
        LK_EQ(IsUtf8("\xf5\x80\x80\x80"), false); /* past U+10FFFF */
        LK_EQ(IsUtf8("\xf8\x88\x80\x80\x80"), false); /* five bytes is not a form */
    }

    LK_CASE("UTF-8 is left exactly as it is");
    {
        LK_EQ(Utf8OrLatin1("38\xc2\xb0N"), std::string("38\xc2\xb0N"));
        LK_EQ(Utf8OrLatin1(""), std::string(""));
    }

    /* All or nothing: a mixed repair invents characters that are in no
     * encoding the office used. */
    LK_CASE("anything else is read as Latin-1, every byte of it");
    {
        LK_EQ(Utf8OrLatin1("caf\xe9"), std::string("caf\xc3\xa9"));
        LK_EQ(Utf8OrLatin1("\xff"), std::string("\xc3\xbf"));
    }

    LK_CASE("the repair is always showable");
    {
        for (char const *bad : { "caf\xe9", "\xc2", "\x80", "\xed\xa0\x80", "\xf8\x88\x80\x80\x80" })
            LK_EQ(IsUtf8(Utf8OrLatin1(bad)), true);
    }
}
