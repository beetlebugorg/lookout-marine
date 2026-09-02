// Where the licence manifest comes from: the core bakes
// vendor/licenses/licenses.json into the binary and hands over the entries
// this build carries, so this needs no connection and no file. The labels on
// a row are lk_licenses.cpp's; this is only the seam to the core and to the
// build's version, which is the part a test cannot link.
#include "lk_licenses.h"

#include "lookout.h"

namespace lkw
{
    LicenseManifest const &Licenses()
    {
        // Static in the core, so this needs no chart open and never changes.
        // The read is a copy, and every field is copied out of it, so it is
        // freed here rather than held for the life of the process.
        static LicenseManifest const manifest = [] {
            LicenseManifest m;
            lookout_licenses *read = lookout_licenses_read("windows");
            if (read == nullptr)
                return m;
            if (lookout_license const *app = lookout_licenses_app(read))
                m.app = LicenseApp{ *app };
            size_t n = 0;
            lookout_license const *const *all = lookout_licenses_all(read, &n);
            for (size_t i = 0; i < n; ++i)
                m.components.emplace_back(*all[i]);
            lookout_licenses_free(read);
            // An app entry the core could not name leaves nothing to show, and
            // a build with no components would say this one carries none.
            m.ok = !m.app.name.empty() && !m.components.empty();
            return m;
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
