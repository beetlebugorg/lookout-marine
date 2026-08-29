// The licence manifest's model: reading one document, and the labels the two
// screens put on a row. See lk_licenses.h. Where the document comes from is
// lk_licenses_baked.cpp — this file knows nothing about the core, and no
// WinRT, so the manifest's shape can be tested.
#include "lk_licenses.h"

#include <algorithm>

#include "lk_json.h"

namespace
{
    using lkw::json::Kind;
    using lkw::json::Value;

    // Which builds carry this entry. One manifest serves every shell, so a
    // shell draws the entries that name it and no others.
    bool CarriedHere(Value const &o)
    {
        for (auto const &s : o["shells"].Items())
            if (s.String() == "windows")
                return true;
        return false;
    }

    lkw::LicenseComponent ReadComponent(Value const &o)
    {
        lkw::LicenseComponent c;
        c.id = o.MemberString("id");
        c.name = o.MemberString("name");
        c.group = o.MemberString("group");
        c.summary = o.MemberString("summary");
        c.license = o.MemberString("license");
        c.license_short = o.MemberString("license_short");
        c.license_note = o.MemberString("license_note");
        c.version = o.MemberString("version");
        c.commit = o.MemberString("commit");
        c.pinned_in = o.MemberString("pinned_in");
        c.copyright = o.MemberString("copyright");
        c.url = o.MemberString("url");
        c.text = o.MemberString("text");
        c.notice = o.MemberString("notice");
        return c;
    }
}

namespace lkw
{
    LicenseManifest ParseLicenses(std::string_view json)
    {
        LicenseManifest m;
        auto doc = json::Parse(json);
        if (!doc || doc->kind() != Kind::Object)
            return m;
        Value const &obj = *doc;

        Value const &a = obj["app"];
        if (a.kind() == Kind::Object)
        {
            m.app.name = a.MemberString("name");
            m.app.summary = a.MemberString("summary");
            m.app.license = a.MemberString("license");
            m.app.copyright = a.MemberString("copyright");
            m.app.url = a.MemberString("url");
            m.app.text = a.MemberString("text");
        }

        for (auto const &entry : obj["components"].Items())
        {
            if (entry.kind() != Kind::Object || !CarriedHere(entry))
                continue;
            m.components.push_back(ReadComponent(entry));
        }

        // An app entry that did not parse leaves nothing to show, and a build
        // with no components would say this one carries none.
        m.ok = !m.app.name.empty() && !m.components.empty();
        return m;
    }

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
}
