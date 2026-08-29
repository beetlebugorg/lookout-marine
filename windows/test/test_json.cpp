/* The JSON reader the model layer parses with.
 *
 * Everything the core hands this shell comes through here, so the contracts
 * that matter are the ones the callers lean on: a walk down a branch that is
 * not there must read as absent rather than fault, a number must keep the
 * digits the cell wrote, and a document that does not parse whole must parse
 * as nothing at all — a half-read pick report is worse than none.
 */
#include "lk_test.h"

#include "lk_json.h"

using namespace lktest;
using lkw::json::Kind;
using lkw::json::Parse;
using lkw::json::Value;

namespace
{
    /* The parsed root, or the absent node when it did not parse — so a case
     * that expects a failure can say so and one that does not still reads. */
    Value Root(char const *text)
    {
        auto v = Parse(text);
        return v ? std::move(*v) : Value{};
    }
}

void TestJson()
{
    Suite("lk_json");

    LK_CASE("the scalars");
    {
        LK_CHECK(Root("\"hello\"").kind() == Kind::String);
        LK_EQ(Root("\"hello\"").String(), std::string("hello"));
        LK_CHECK(Root("17").kind() == Kind::Number);
        LK_NEAR(Root("17").Number(-1), 17, 0);
        LK_CHECK(Root("true").kind() == Kind::Bool);
        LK_EQ(Root("true").Bool(false), true);
        LK_EQ(Root("false").Bool(true), false);
        LK_CHECK(Root("null").kind() == Kind::Null);
    }

    LK_CASE("negative, fractional and exponent numbers");
    {
        LK_NEAR(Root("-3.5").Number(0), -3.5, 1e-12);
        LK_NEAR(Root("1e3").Number(0), 1000, 1e-12);
        LK_NEAR(Root("1.5E-2").Number(0), 0.015, 1e-12);
        LK_NEAR(Root("0").Number(-1), 0, 0);
    }

    /* A raw attribute row shows the cell's own digits. "17" must not come back
     * "17.0", and a depth written "3.00" must not come back "3". */
    LK_CASE("a number keeps the digits the document wrote");
    {
        LK_EQ(Root("17").Text(), std::string("17"));
        LK_EQ(Root("3.00").Text(), std::string("3.00"));
        LK_EQ(Root("-0.5").Text(), std::string("-0.5"));
    }

    LK_CASE("a string is not coerced to a number, nor a number to a string");
    {
        LK_EQ(Root("17").String(), std::string(""));
        LK_NEAR(Root("\"17\"").Number(-1), -1, 0);
    }

    LK_CASE("objects");
    {
        Value v = Root(R"({"b":2,"a":1,"c":{"d":"deep"}})");
        LK_CHECK(v.kind() == Kind::Object);
        LK_NEAR(v["a"].Number(-1), 1, 0);
        LK_NEAR(v["b"].Number(-1), 2, 0);
        LK_EQ(v["c"]["d"].String(), std::string("deep"));
        LK_EQ(v.Has("a"), true);
        LK_EQ(v.Has("z"), false);
    }

    LK_CASE("member names come back sorted");
    {
        auto names = Root(R"({"b":1,"a":1,"C":1})").MemberNames();
        LK_EQ(names.size(), (size_t)3);
        LK_EQ(names[0], std::string("C")); /* byte order, as the other shells sort */
        LK_EQ(names[1], std::string("a"));
        LK_EQ(names[2], std::string("b"));
    }

    LK_CASE("arrays");
    {
        Value v = Root(R"([1,"two",null,{"k":3}])");
        LK_CHECK(v.kind() == Kind::Array);
        LK_EQ(v.Length(), (size_t)4);
        LK_NEAR(v.At(0).Number(-1), 1, 0);
        LK_EQ(v.At(1).String(), std::string("two"));
        LK_CHECK(v.At(2).kind() == Kind::Null);
        LK_NEAR(v.At(3)["k"].Number(-1), 3, 0);
    }

    LK_CASE("the empty container");
    {
        LK_CHECK(Root("{}").kind() == Kind::Object);
        LK_EQ(Root("{}").MemberNames().size(), (size_t)0);
        LK_CHECK(Root("[]").kind() == Kind::Array);
        LK_EQ(Root("[]").Length(), (size_t)0);
    }

    /* The reason this reader answers on the absent node: the callers walk
     * straight down a path the core may not have written. */
    LK_CASE("a walk down a missing branch reads as absent");
    {
        Value v = Root(R"({"report":{}})");
        LK_EQ(v["report"]["rows"].At(3)["label"].String(), std::string(""));
        LK_CHECK(v["report"]["rows"].IsAbsent());
        LK_EQ(v["report"]["rows"].Length(), (size_t)0);
        LK_EQ(v["report"]["rows"].Items().size(), (size_t)0);
        LK_EQ(v["nope"].Number(42), 42);
        LK_EQ(v["nope"].Bool(true), true);
        LK_EQ(v["nope"].MemberString("deeper", "fallback"), std::string("fallback"));
    }

    LK_CASE("absent and null are both nothing to show, and still tell apart");
    {
        Value v = Root(R"({"said":null})");
        LK_CHECK(v["said"].IsNothing());
        LK_CHECK(v["unsaid"].IsNothing());
        LK_CHECK(!v["said"].IsAbsent());
        LK_CHECK(v["unsaid"].IsAbsent());
    }

    LK_CASE("an empty member string reads as no member string");
    {
        Value v = Root(R"({"title":"","chip":"AIS"})");
        LK_EQ(v.MemberString("title", "fallback"), std::string("fallback"));
        LK_EQ(v.MemberString("chip", "fallback"), std::string("AIS"));
        LK_EQ(v.MemberString("absent"), std::string(""));
    }

    LK_CASE("indexing a non-container is absent, not a fault");
    {
        Value v = Root(R"({"n":17})");
        LK_CHECK(v["n"]["deeper"].IsAbsent());
        LK_CHECK(v["n"].At(0).IsAbsent());
        LK_EQ(v["n"].MemberNames().size(), (size_t)0);
    }

    LK_CASE("the string escapes");
    {
        LK_EQ(Root(R"("a\"b")").String(), std::string("a\"b"));
        LK_EQ(Root(R"("a\\b")").String(), std::string("a\\b"));
        LK_EQ(Root(R"("a\/b")").String(), std::string("a/b"));
        LK_EQ(Root(R"("a\nb")").String(), std::string("a\nb"));
        LK_EQ(Root(R"("a\tb")").String(), std::string("a\tb"));
        LK_EQ(Root(R"("\b\f\r")").String(), std::string("\b\f\r"));
    }

    LK_CASE("\\u escapes arrive as UTF-8");
    {
        /* U+00B0 DEGREE SIGN — the one every readout carries. */
        LK_EQ(Root(R"("38°")").String(), std::string("38\xc2\xb0"));
        /* U+2014 EM DASH, the missing-cell mark. */
        LK_EQ(Root(R"("—")").String(), std::string("\xe2\x80\x94"));
        /* Upper case hex is the same escape. */
        LK_EQ(Root(R"("°")").String(), std::string("\xc2\xb0"));
    }

    LK_CASE("bytes that are already UTF-8 pass through untouched");
    {
        LK_EQ(Root("\"38\xc2\xb0\x4e\"").String(), std::string("38\xc2\xb0N"));
    }

    /* A cell name outside the BMP arrives as a surrogate pair. */
    LK_CASE("a surrogate pair is one character");
    {
        /* U+1F6A2 SHIP */
        LK_EQ(Root(R"("🚢")").String(), std::string("\xf0\x9f\x9a\xa2"));
    }

    LK_CASE("a lone surrogate becomes the replacement character");
    {
        LK_EQ(Root(R"("\ud83d")").String(), std::string("\xef\xbf\xbd"));
        LK_EQ(Root(R"("\udea2")").String(), std::string("\xef\xbf\xbd"));
    }

    LK_CASE("whitespace between anything");
    {
        Value v = Root("  {\n \"a\" : [ 1 , 2 ]\r\n}\t ");
        LK_EQ(v["a"].Length(), (size_t)2);
    }

    /* A document that does not parse whole parses as nothing at all. */
    LK_CASE("what is not JSON");
    {
        LK_CHECK(!Parse("").has_value());
        LK_CHECK(!Parse("   ").has_value());
        LK_CHECK(!Parse("{").has_value());
        LK_CHECK(!Parse("[1,").has_value());
        LK_CHECK(!Parse("[1,]").has_value());
        LK_CHECK(!Parse("{\"a\"}").has_value());
        LK_CHECK(!Parse("{\"a\":}").has_value());
        LK_CHECK(!Parse("{a:1}").has_value());
        LK_CHECK(!Parse("\"unterminated").has_value());
        LK_CHECK(!Parse(R"("bad \q escape")").has_value());
        LK_CHECK(!Parse(R"("short \u12")").has_value());
        LK_CHECK(!Parse("tru").has_value());
        LK_CHECK(!Parse("-").has_value());
        LK_CHECK(!Parse("1.").has_value());
        LK_CHECK(!Parse("1e").has_value());
        LK_CHECK(!Parse("nan").has_value());
        LK_CHECK(!Parse("0x10").has_value());
    }

    LK_CASE("trailing junk after the value is a failure, not a value");
    {
        LK_CHECK(!Parse("{} trailing").has_value());
        LK_CHECK(!Parse("1 2").has_value());
        LK_CHECK(!Parse("[1][2]").has_value());
        LK_CHECK(Parse("{}  \n ").has_value()); /* trailing whitespace is not junk */
    }

    /* A hostile payload must not take the stack with it. */
    LK_CASE("nesting past the cap is refused");
    {
        std::string deep;
        for (int i = 0; i < 40; i++)
            deep += "[";
        for (int i = 0; i < 40; i++)
            deep += "]";
        LK_CHECK(Parse(deep).has_value());

        std::string too_deep;
        for (int i = 0; i < 400; i++)
            too_deep += "[";
        for (int i = 0; i < 400; i++)
            too_deep += "]";
        LK_CHECK(!Parse(too_deep).has_value());
    }

    LK_CASE("an embedded NUL ends nothing early");
    {
        /* The span carries its own length, so a payload with a NUL in a string
         * reads to the closing quote rather than stopping at the byte. */
        std::string text = "{\"a\":\"x";
        text += '\0';
        text += "y\"}";
        auto v = Parse(std::string_view(text.data(), text.size()));
        LK_CHECK(v.has_value());
        if (v)
            LK_EQ((*v)["a"].String().size(), (size_t)3);
    }
}
