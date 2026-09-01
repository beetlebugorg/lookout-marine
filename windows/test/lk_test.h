/* lk_test — the check harness the Windows shell's tests are written against.
 *
 * Header only, no dependencies, no framework: the suite has to build with the
 * one compiler this shell already requires (zig, for the core), on a machine
 * that may have nothing else installed. A test is a plain function; a check
 * that fails prints the suite, the case, the file and line, and what the two
 * sides actually were, then carries on — one broken expectation should not
 * hide the twenty behind it.
 *
 * Write:
 *
 *   LK_CASE("a row with no id is dropped");
 *   LK_EQ(rows.size(), 2u);
 *   LK_NEAR(rows[0].cog_deg, 38.9, 1e-9);
 */
#pragma once

#include <cstdio>
#include <cstring>
#include <string>

namespace lktest
{
    struct Run
    {
        int checks{ 0 };
        int failures{ 0 };
        char const *suite{ "" };
        char const *test_case{ "" };
    };

    inline Run &run()
    {
        static Run r;
        return r;
    }

    inline void Suite(char const *name)
    {
        run().suite = name;
        run().test_case = "";
        std::printf("  %s\n", name);
    }

    inline void Case(char const *name) { run().test_case = name; }

    /* ---- how a value is shown when a check fails ------------------------- */

    inline std::string Show(bool v) { return v ? "true" : "false"; }
    inline std::string Show(int v) { return std::to_string(v); }
    inline std::string Show(long v) { return std::to_string(v); }
    inline std::string Show(long long v) { return std::to_string(v); }
    inline std::string Show(unsigned v) { return std::to_string(v); }
    inline std::string Show(unsigned long v) { return std::to_string(v); }
    inline std::string Show(unsigned long long v) { return std::to_string(v); }

    inline std::string Show(double v)
    {
        char buf[64];
        std::snprintf(buf, sizeof buf, "%.10g", v);
        return buf;
    }

    inline std::string Show(std::string const &v) { return "\"" + v + "\""; }
    inline std::string Show(char const *v) { return v == nullptr ? "null" : Show(std::string(v)); }

    /* A wide string is shown as UTF-8 with the non-ASCII bytes spelled out:
     * a coordinate readout differs from its expectation by a degree sign more
     * often than by a digit, and "38°58.80'N" says which. */
    inline std::string Show(std::wstring const &v)
    {
        std::string out = "\"";
        for (wchar_t c : v)
        {
            if (c >= 0x20 && c < 0x7F)
            {
                out += (char)c;
            }
            else
            {
                char buf[16];
                std::snprintf(buf, sizeof buf, "\\u%04x", (unsigned)(c & 0xFFFF));
                out += buf;
            }
        }
        return out + "\"";
    }

    inline std::string Show(wchar_t const *v)
    {
        return v == nullptr ? "null" : Show(std::wstring(v));
    }

    /* ---- reporting -------------------------------------------------------- */

    inline void Failed(char const *file, int line, char const *expr, std::string const &detail)
    {
        run().failures++;
        std::printf("    FAIL  %s\n", run().test_case);
        std::printf("          %s:%d\n", file, line);
        std::printf("          %s\n", expr);
        if (!detail.empty())
            std::printf("          %s\n", detail.c_str());
    }

    inline void Ok() { run().checks++; }

    template <typename A, typename B>
    void CheckEq(char const *file, int line, char const *expr, A const &a, B const &b)
    {
        if (a == b)
            Ok();
        else
            Failed(file, line, expr, "got " + Show(a) + ", want " + Show(b));
    }

    template <typename A, typename B>
    void CheckNe(char const *file, int line, char const *expr, A const &a, B const &b)
    {
        if (!(a == b))
            Ok();
        else
            Failed(file, line, expr, "both " + Show(a));
    }

    inline void CheckNear(char const *file, int line, char const *expr,
                          double a, double b, double tol)
    {
        double d = a - b;
        if (d < 0)
            d = -d;
        if (d <= tol)
            Ok();
        else
            Failed(file, line, expr, "got " + Show(a) + ", want " + Show(b) +
                                         " (within " + Show(tol) + ")");
    }

    inline void CheckTrue(char const *file, int line, char const *expr, bool v)
    {
        if (v)
            Ok();
        else
            Failed(file, line, expr, "was false");
    }

    /* 0 when everything passed, 1 otherwise — the runner's exit code. */
    inline int Report()
    {
        std::printf("\n%d check(s), %d failure(s)\n", run().checks, run().failures);
        return run().failures == 0 ? 0 : 1;
    }
}

#define LK_CASE(name) ::lktest::Case(name)
#define LK_CHECK(expr) ::lktest::CheckTrue(__FILE__, __LINE__, #expr, (bool)(expr))
#define LK_EQ(a, b) ::lktest::CheckEq(__FILE__, __LINE__, #a " == " #b, (a), (b))
#define LK_NE(a, b) ::lktest::CheckNe(__FILE__, __LINE__, #a " != " #b, (a), (b))
#define LK_NEAR(a, b, tol) ::lktest::CheckNear(__FILE__, __LINE__, #a " ~= " #b, (a), (b), (tol))
