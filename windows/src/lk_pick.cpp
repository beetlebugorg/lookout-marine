// lk_pick — pick-report envelope decode. See lk_pick.h.
#include "pch.h"
#include "lk_pick.h"

#include <algorithm>
#include <cstdio>
#include <cwchar>

#include <winrt/Windows.Data.Json.h>

using namespace winrt;
using namespace winrt::Windows::Data::Json;

namespace
{
    // UTF-8 → hstring, falling back to Latin-1 when the bytes aren't UTF-8 (a
    // cell's attribute text is not always well-formed).
    hstring FromUtf8(char const *s)
    {
        if (s == nullptr || *s == '\0')
            return {};
        std::string_view view{ s };
        try
        {
            return to_hstring(view);
        }
        catch (hresult_error const &)
        {
            std::wstring wide;
            wide.reserve(view.size());
            for (unsigned char c : view)
                wide.push_back((wchar_t)c);
            return hstring{ wide };
        }
    }

    // A scalar JSON value as display text: whole numbers without the ".0",
    // null as empty — matching S57.text() in PickDecoded.kt.
    hstring ScalarText(IJsonValue const &v)
    {
        switch (v.ValueType())
        {
        case JsonValueType::String:
            return v.GetString();
        case JsonValueType::Number:
        {
            double d = v.GetNumber();
            wchar_t buf[64];
            if (d == (double)(long long)d)
                swprintf_s(buf, L"%lld", (long long)d);
            else
                swprintf_s(buf, L"%.10g", d);
            return hstring{ buf };
        }
        case JsonValueType::Boolean:
            return v.GetBoolean() ? hstring{ L"true" } : hstring{ L"false" };
        case JsonValueType::Null:
        default:
            return {};
        }
    }

    // JSON null and "" are both "absent" (optStringOrNull in PickDecoded.kt).
    hstring OptString(JsonObject const &o, hstring const &key)
    {
        if (o == nullptr || !o.HasKey(key))
            return {};
        auto v = o.GetNamedValue(key);
        if (v.ValueType() != JsonValueType::String)
            return {};
        return v.GetString();
    }

    // Flatten any JSON into (name, value, depth) rows: an object emits a
    // heading then its keys SORTED one level in (top-level keys stay at depth
    // 0), an array emits a heading then its items in, a scalar emits one row.
    void Flatten(hstring const &name, IJsonValue const &v, int depth,
                 std::vector<lkw::RawRow> &out)
    {
        if (v == nullptr)
            return;
        switch (v.ValueType())
        {
        case JsonValueType::Object:
        {
            int child_depth = depth;
            if (!name.empty())
            {
                out.push_back({ name, {}, depth });
                child_depth = depth + 1;
            }
            auto obj = v.GetObject();
            std::vector<hstring> keys;
            for (auto const &kv : obj)
                keys.push_back(kv.Key());
            std::sort(keys.begin(), keys.end(),
                      [](hstring const &a, hstring const &b) {
                          return std::wcscmp(a.c_str(), b.c_str()) < 0;
                      });
            for (auto const &k : keys)
                Flatten(k, obj.GetNamedValue(k), child_depth, out);
            break;
        }
        case JsonValueType::Array:
        {
            out.push_back({ name, {}, depth });
            for (auto const &item : v.GetArray())
                Flatten({}, item, depth + 1, out);
            break;
        }
        default:
            out.push_back({ name, ScalarText(v), depth });
            break;
        }
    }

    // Split the envelope: *report gets the composed report object (or null),
    // the return value is the raw payload half (or null when nothing parses).
    IJsonValue SplitEnvelope(char const *json, JsonObject *report)
    {
        *report = nullptr;
        if (json == nullptr || *json == '\0')
            return nullptr;
        JsonValue root{ nullptr };
        if (!JsonValue::TryParse(FromUtf8(json), root))
            return nullptr;
        if (root.ValueType() == JsonValueType::Object)
        {
            auto obj = root.GetObject();
            if (obj.HasKey(L"report") &&
                obj.GetNamedValue(L"report").ValueType() == JsonValueType::Object)
            {
                *report = obj.GetNamedObject(L"report");
                // The raw half; absent means the whole doc was the report's.
                if (obj.HasKey(L"s57"))
                    return obj.GetNamedValue(L"s57");
                return nullptr;
            }
        }
        // No envelope: the core's fallback emits the raw payload bare.
        return root;
    }
}

namespace lkw
{
    PickDecoded DecodePick(char const *cls, char const *json, char const *chart)
    {
        PickDecoded d;
        hstring cls_h = FromUtf8(cls);
        hstring chart_h = FromUtf8(chart);

        JsonObject report{ nullptr };
        IJsonValue raw{ nullptr };
        try
        {
            raw = SplitEnvelope(json, &report);

            if (report != nullptr)
            {
                d.title = OptString(report, L"title");
                d.subtitle = OptString(report, L"subtitle");
                d.chip = OptString(report, L"chip");
                d.footnote = OptString(report, L"footnote");
                hstring empty = OptString(report, L"empty");
                if (empty == L"none")
                    d.empty = PickEmpty::NoAttributes;
                else if (empty == L"source")
                    d.empty = PickEmpty::SourceOnly;
                if (report.HasKey(L"notes") &&
                    report.GetNamedValue(L"notes").ValueType() == JsonValueType::Array)
                {
                    for (auto const &n : report.GetNamedArray(L"notes"))
                    {
                        hstring text = n.ValueType() == JsonValueType::String ? n.GetString() : hstring{};
                        if (!text.empty())
                            d.notes.push_back(text);
                    }
                }
                if (report.HasKey(L"rows") &&
                    report.GetNamedValue(L"rows").ValueType() == JsonValueType::Array)
                {
                    for (auto const &rv : report.GetNamedArray(L"rows"))
                    {
                        if (rv.ValueType() != JsonValueType::Object)
                            continue;
                        auto ro = rv.GetObject();
                        PickRow row;
                        row.label = OptString(ro, L"label");
                        row.value = OptString(ro, L"value");
                        row.depth = (int)ro.GetNamedNumber(L"depth", 0);
                        row.file = ro.GetNamedBoolean(L"file", false);
                        row.picture = ro.GetNamedBoolean(L"picture", false);
                        d.rows.push_back(std::move(row));
                    }
                }
            }
            if (raw != nullptr)
                Flatten({}, raw, 0, d.raw);
        }
        catch (hresult_error const &)
        {
            // An unparseable payload keeps the fallbacks; the fold shows nothing.
        }

        if (d.title.empty())
            d.title = cls_h;
        if (d.chip.empty())
            d.chip = cls_h;
        if (d.footnote.empty())
            d.footnote = chart_h;
        return d;
    }

    hstring PickPlainText(char const *cls, char const *json, char const *chart)
    {
        PickDecoded d = DecodePick(cls, json, chart);
        std::wstring text;
        text += FromUtf8(cls);
        text += L"  ";
        text += FromUtf8(chart);
        text += L"\n";
        for (auto const &r : d.raw)
        {
            text.append((size_t)r.depth * 2, L' ');
            if (r.name.empty())
                text += r.value;
            else
            {
                text += r.name;
                text += L":";
                if (!r.value.empty())
                {
                    text += L" ";
                    text += r.value;
                }
            }
            text += L"\n";
        }
        return hstring{ text };
    }
}
