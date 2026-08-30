// Where the licence manifest comes from: the core bakes
// vendor/licenses/licenses.json into the binary and hands it over whole, so
// this needs no connection and no file. The reading of it is
// lk_licenses.cpp; this is only the seam to the core and to the build's
// version, which is the part a test cannot link.
#include "lk_licenses.h"

#include <string_view>

#include "lookout.h"

namespace lkw
{
    LicenseManifest const &Licenses()
    {
        // Static in the core, so this needs no chart open and never changes.
        static LicenseManifest const manifest = [] {
            size_t len = 0;
            char const *json = lookout_licenses_json(&len);
            if (json == nullptr || len == 0)
                return LicenseManifest{};
            return ParseLicenses(std::string_view{ json, len });
        }();
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
