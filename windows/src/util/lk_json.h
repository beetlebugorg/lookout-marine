/* lk_json — a small JSON reader for the shell's model layer.
 *
 * The core hands this shell JSON at every seam: the picked feature's report,
 * the plugin registry, the alert list, the table declarations, the licence
 * manifest. Windows has a JSON reader of its own in
 * winrt::Windows::Data::Json, and the shell used it — which bound every one of
 * those parsers to WinRT, and through WinRT to a running XAML host. That is
 * why none of them could be tested.
 *
 * So this reads the subset JSON actually is — objects, arrays, strings,
 * numbers, booleans, null — the way linux/src/lk-json.c does for the GTK
 * shell, with the same contracts, so a raw pick dump reads the same on both:
 *
 *   - A node owns its children; the tree goes when the root does.
 *   - Trailing junk after the value is a parse FAILURE. A half-parsed report
 *     is worse than none.
 *   - A number keeps the digits the document wrote, so "17" does not come
 *     back "17.0" in a raw attribute row.
 *   - Member names come back sorted.
 *   - A walk down a missing branch reads as absent rather than crashing:
 *     every accessor answers on the absent node too, so
 *     root["report"]["rows"].At(3)["label"].String() is "" and not a fault.
 *
 * Text is UTF-8 throughout, like the rest of windows/src; the WinUI layer
 * converts at the point of display.
 */
#pragma once

#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace lkw::json
{
    enum class Kind
    {
        Absent, /* no such member, or past the end of an array */
        Null,
        Bool,
        Number,
        String,
        Array,
        Object,
    };

    class Value
    {
    public:
        Kind kind() const { return kind_; }
        bool IsAbsent() const { return kind_ == Kind::Absent; }
        /* Absent AND JSON null both read as nothing to show. The two are kept
         * apart by kind() for the callers that must tell "the core did not say"
         * from "the core said nothing". */
        bool IsNothing() const { return kind_ == Kind::Absent || kind_ == Kind::Null; }

        /* ---- objects ----------------------------------------------------- */

        /* The member, or the absent node. */
        Value const &Member(std::string_view name) const;
        Value const &operator[](std::string_view name) const { return Member(name); }
        bool Has(std::string_view name) const { return !Member(name).IsAbsent(); }
        /* Sorted, so a raw dump reads the same on every shell. */
        std::vector<std::string> MemberNames() const;

        /* ---- arrays ------------------------------------------------------ */

        size_t Length() const { return kind_ == Kind::Array ? items_.size() : 0; }
        Value const &At(size_t index) const;
        /* An array's items, or nothing at all — so a `for (auto const &v :
         * node["rows"].Items())` over a missing member is an empty loop. */
        std::vector<Value> const &Items() const;

        /* ---- scalars ----------------------------------------------------- */

        /* A string node's text, else empty. A number is not coerced: a caller
         * that wants the cell's own digits asks for Text(). */
        std::string const &String() const;
        /* Any scalar as the text the document wrote. Empty for a container. */
        std::string const &Text() const { return text_; }
        double Number(double fallback) const { return kind_ == Kind::Number ? number_ : fallback; }
        bool Bool(bool fallback) const { return kind_ == Kind::Bool ? boolean_ : fallback; }

        /* ---- member shorthands ------------------------------------------- */

        /* Empty for a missing, null, non-string or empty member: every caller
         * treats an empty title the same as no title. */
        std::string MemberString(std::string_view name, std::string const &fallback = {}) const;
        double MemberNumber(std::string_view name, double fallback) const;
        bool MemberBool(std::string_view name, bool fallback) const;

        /* The absent node. Shared, so returning a reference to it is free. */
        static Value const &Nothing();

    private:
        friend class Reader;

        Kind kind_{ Kind::Absent };
        std::string text_;   /* the scalar as written; a string's own value */
        double number_{ 0 };
        bool boolean_{ false };
        std::vector<Value> items_;      /* array items, or an object's values */
        std::vector<std::string> keys_; /* parallel to items_ for an object */
    };

    /* Nothing when `text` is not JSON, or when anything but whitespace follows
     * the value. Nesting past `kMaxDepth` is also refused: the payloads this
     * reads are shallow, and a hostile one must not take the stack with it. */
    inline constexpr int kMaxDepth = 64;
    std::optional<Value> Parse(std::string_view text);
}
