// lk_pick — pick-report envelope decode. See lk_pick.h.
#include "lk_pick.h"

#include <cinttypes>
#include <cmath>
#include <cstdio>

#include "lk_json.h"
#include "lk_utf8.h"

namespace
{
    using lkw::json::Kind;
    using lkw::json::Value;

    std::string Text(char const *s)
    {
        return s == nullptr ? std::string{} : lkw::Utf8OrLatin1(s);
    }

    // A scalar JSON value as display text: whole numbers without the ".0",
    // null as empty — matching S57.text() in PickDecoded.kt.
    std::string ScalarText(Value const &v)
    {
        switch (v.kind())
        {
        case Kind::String:
            return v.String();
        case Kind::Number:
        {
            double d = v.Number(0);
            char buf[64];
            if (d == (double)(long long)d)
                std::snprintf(buf, sizeof buf, "%lld", (long long)d);
            else
                std::snprintf(buf, sizeof buf, "%.10g", d);
            return buf;
        }
        case Kind::Bool:
            return v.Bool(false) ? "true" : "false";
        default:
            return {};
        }
    }

    // Flatten any JSON into (name, value, depth) rows: an object emits a
    // heading then its keys SORTED one level in (top-level keys stay at depth
    // 0), an array emits a heading then its items in, a scalar emits one row.
    void Flatten(std::string const &name, Value const &v, int depth,
                 std::vector<lkw::RawRow> &out)
    {
        if (v.IsAbsent())
            return;
        switch (v.kind())
        {
        case Kind::Object:
        {
            int child_depth = depth;
            if (!name.empty())
            {
                out.push_back({ name, {}, depth });
                child_depth = depth + 1;
            }
            for (auto const &k : v.MemberNames())
                Flatten(k, v[k], child_depth, out);
            break;
        }
        case Kind::Array:
        {
            out.push_back({ name, {}, depth });
            for (auto const &item : v.Items())
                Flatten({}, item, depth + 1, out);
            break;
        }
        default:
            out.push_back({ name, ScalarText(v), depth });
            break;
        }
    }
}

namespace lkw
{
    PickDecoded DecodePick(char const *cls, char const *json, char const *chart)
    {
        PickDecoded d;
        std::string cls_text = Text(cls);
        std::string chart_text = Text(chart);

        // An unparseable payload keeps the fallbacks; the fold shows nothing.
        auto doc = json != nullptr && *json != '\0'
                       ? json::Parse(Utf8OrLatin1(json))
                       : std::nullopt;
        if (doc)
        {
            // Split the envelope: the composed report, and the raw payload
            // half. No envelope means the core's fallback emitted the raw
            // payload bare; an envelope with no "s57" means the whole document
            // was the report's.
            Value const &root = *doc;
            bool enveloped = root.kind() == Kind::Object &&
                             root["report"].kind() == Kind::Object;
            Value const &report = enveloped ? root["report"] : Value::Nothing();
            Value const &raw = enveloped ? root["s57"] : root;

            if (enveloped)
            {
                d.title = report.MemberString("title");
                d.subtitle = report.MemberString("subtitle");
                d.chip = report.MemberString("chip");
                d.footnote = report.MemberString("footnote");
                std::string empty = report.MemberString("empty");
                if (empty == "none")
                    d.empty = PickEmpty::NoAttributes;
                else if (empty == "source")
                    d.empty = PickEmpty::SourceOnly;

                for (auto const &n : report["notes"].Items())
                {
                    std::string text = n.String();
                    if (!text.empty())
                        d.notes.push_back(std::move(text));
                }

                for (auto const &rv : report["rows"].Items())
                {
                    if (rv.kind() != Kind::Object)
                        continue;
                    PickRow row;
                    row.label = rv.MemberString("label");
                    row.value = rv.MemberString("value");
                    row.depth = (int)rv.MemberNumber("depth", 0);
                    row.file = rv.MemberBool("file", false);
                    row.picture = rv.MemberBool("picture", false);
                    d.rows.push_back(std::move(row));
                }
            }

            Flatten({}, raw, 0, d.raw);
        }

        if (d.title.empty())
            d.title = cls_text;
        if (d.chip.empty())
            d.chip = cls_text;
        if (d.footnote.empty())
            d.footnote = chart_text;
        return d;
    }

    std::string PickPlainText(char const *cls, char const *json, char const *chart)
    {
        PickDecoded d = DecodePick(cls, json, chart);
        std::string text;
        text += Text(cls);
        text += "  ";
        text += Text(chart);
        text += "\n";
        for (auto const &r : d.raw)
        {
            text.append((size_t)r.depth * 2, ' ');
            if (r.name.empty())
            {
                text += r.value;
            }
            else
            {
                text += r.name;
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
