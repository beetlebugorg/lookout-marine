// The licence manifest's model: the shape of one entry, and the labels the two
// screens put on a row. See lk_licenses.h. Where the entries come from is
// lk_licenses_baked.cpp — this file calls no core function, and no WinRT, so
// the labels can be tested.
#include "lk_licenses.h"

#include <algorithm>

namespace lkw
{
    LicenseComponent::LicenseComponent(lookout_license const &c)
        : id{ c.id }, name{ c.name }, group{ c.group }, summary{ c.summary },
          license{ c.license }, license_short{ c.license_short },
          license_note{ c.license_note }, version{ c.version }, commit{ c.commit },
          pinned_in{ c.pinned_in }, copyright{ c.copyright }, url{ c.url },
          text{ c.text }, notice{ c.notice }
    {
    }

    LicenseApp::LicenseApp(lookout_license const &a)
        : name{ a.name }, summary{ a.summary }, license{ a.license },
          copyright{ a.copyright }, url{ a.url }, text{ a.text }
    {
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
