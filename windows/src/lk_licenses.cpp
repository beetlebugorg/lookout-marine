// The baked license manifest, parsed once into the model the screens read.
#include "pch.h"

#include "lk_licenses.h"

#include <winrt/Windows.Data.Json.h>

#include <algorithm>

#include "lookout.h"

using namespace winrt::Windows::Data::Json;

namespace
{
    std::string Str(JsonObject const &o, wchar_t const *key)
    {
        if (!o.HasKey(key))
            return {};
        auto v = o.GetNamedValue(key);
        if (v.ValueType() != JsonValueType::String)
            return {};
        return winrt::to_string(v.GetString());
    }

    // Which builds carry this entry. One manifest serves every shell, so a
    // shell draws the entries that name it and no others.
    bool CarriedHere(JsonObject const &o)
    {
        if (!o.HasKey(L"shells") || o.GetNamedValue(L"shells").ValueType() != JsonValueType::Array)
            return false;
        for (auto const &s : o.GetNamedArray(L"shells"))
        {
            if (s.ValueType() == JsonValueType::String && s.GetString() == L"windows")
                return true;
        }
        return false;
    }

    lkw::LicenseComponent ReadComponent(JsonObject const &o)
    {
        lkw::LicenseComponent c;
        c.id = Str(o, L"id");
        c.name = Str(o, L"name");
        c.group = Str(o, L"group");
        c.summary = Str(o, L"summary");
        c.license = Str(o, L"license");
        c.license_short = Str(o, L"license_short");
        c.license_note = Str(o, L"license_note");
        c.version = Str(o, L"version");
        c.commit = Str(o, L"commit");
        c.pinned_in = Str(o, L"pinned_in");
        c.copyright = Str(o, L"copyright");
        c.url = Str(o, L"url");
        c.text = Str(o, L"text");
        c.notice = Str(o, L"notice");
        return c;
    }

    lkw::LicenseManifest Parse()
    {
        lkw::LicenseManifest m;
        size_t len = 0;
        char const *json = lookout_licenses_json(&len);
        if (json == nullptr || len == 0)
            return m;

        JsonValue root{ nullptr };
        if (!JsonValue::TryParse(winrt::to_hstring(std::string_view{ json, len }), root))
            return m;
        if (root.ValueType() != JsonValueType::Object)
            return m;
        JsonObject obj = root.GetObject();

        if (obj.HasKey(L"app") && obj.GetNamedValue(L"app").ValueType() == JsonValueType::Object)
        {
            JsonObject a = obj.GetNamedObject(L"app");
            m.app.name = Str(a, L"name");
            m.app.summary = Str(a, L"summary");
            m.app.license = Str(a, L"license");
            m.app.copyright = Str(a, L"copyright");
            m.app.url = Str(a, L"url");
            m.app.text = Str(a, L"text");
        }

        if (obj.HasKey(L"components") &&
            obj.GetNamedValue(L"components").ValueType() == JsonValueType::Array)
        {
            for (auto const &entry : obj.GetNamedArray(L"components"))
            {
                if (entry.ValueType() != JsonValueType::Object)
                    continue;
                JsonObject c = entry.GetObject();
                if (!CarriedHere(c))
                    continue;
                m.components.push_back(ReadComponent(c));
            }
        }

        // An app entry that did not parse leaves nothing to show, and a build
        // with no components would say this one carries none.
        m.ok = !m.app.name.empty() && !m.components.empty();
        return m;
    }
}

namespace lkw
{
    std::string LicenseComponent::PinLabel() const
    {
        if (!version.empty())
            return version;
        return commit.substr(0, std::min<size_t>(7, commit.size()));
    }

    std::string LicenseComponent::LicenseLabel() const
    {
        return license.empty() ? "Not resolved" : license;
    }

    std::string LicenseComponent::ColumnLabel() const
    {
        if (license.empty())
            return "Not resolved";
        return license_short.empty() ? license : license_short;
    }

    std::vector<std::pair<std::string, std::vector<size_t>>> LicenseManifest::Groups() const
    {
        std::vector<std::pair<std::string, std::vector<size_t>>> out;
        for (size_t i = 0; i < components.size(); ++i)
        {
            auto it = std::find_if(out.begin(), out.end(),
                                   [&](auto const &g) { return g.first == components[i].group; });
            if (it == out.end())
                out.push_back({ components[i].group, { i } });
            else
                it->second.push_back(i);
        }
        return out;
    }

    LicenseManifest const &Licenses()
    {
        // Static in the core, so this needs no chart open and never changes.
        static LicenseManifest const manifest = Parse();
        return manifest;
    }

    LicenseComponent const *LicenseById(std::string const &id)
    {
        for (auto const &c : Licenses().components)
            if (c.id == id)
                return &c;
        return nullptr;
    }

    char const *AppVersion()
    {
        // The vcxproj passes the version unquoted, because a quoted define
        // does not survive MSBuild's own escaping into the compiler.
#define LK_STRINGIFY_(x) #x
#define LK_STRINGIFY(x) LK_STRINGIFY_(x)
        return LK_STRINGIFY(LK_VERSION);
    }
}
