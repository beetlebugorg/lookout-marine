/* lk_licenses — the licenses screen's model.
 *
 * The core bakes vendor/licenses/licenses.json into the binary and hands it
 * over whole (lookout_licenses_json), so this needs no connection and no file.
 * The entries whose `shells` array names "windows" are the ones this build
 * carries; the rest belong to other shells and are dropped.
 *
 * A license text is shown WHOLE. Nothing here truncates one, reflows one or
 * summarises one: only the width of the view breaks a line.
 */
#pragma once

#include <string>
#include <string_view>
#include <vector>

namespace lkw
{
    /* One component this build carries. Every field is set, and a field
     * upstream states nothing for is an empty string. */
    struct LicenseComponent
    {
        std::string id;
        std::string name;
        std::string group;
        std::string summary;
        std::string license;       /* empty when the terms could not be determined */
        std::string license_short; /* the same terms, for a narrow column */
        std::string license_note;  /* why, when `license` is empty */
        std::string version;
        std::string commit;
        std::string pinned_in;
        std::string copyright;
        std::string url;
        std::string text;   /* the license, whole */
        std::string notice; /* the NOTICE file, empty when it ships none */

        /* What it is pinned at: its version, or the first seven of its commit.
         * Empty when it states neither. */
        std::string PinLabel() const;
        /* What a detail pane says the terms are. An entry whose terms could
         * not be determined says so rather than showing nothing. */
        std::string LicenseLabel() const;
        /* The short form for the list column, falling back to the full one. */
        std::string ColumnLabel() const;
    };

    /* This app's own terms. Not a component, and never in the component count. */
    struct LicenseApp
    {
        std::string name;
        std::string summary;
        std::string license;
        std::string copyright;
        std::string url;
        std::string text;
    };

    struct LicenseManifest
    {
        bool ok{ false }; /* false when the baked list will not parse */
        LicenseApp app;
        std::vector<LicenseComponent> components;

        /* The groups in the order the manifest lists them, each with the
         * indices of its rows. */
        std::vector<std::pair<std::string, std::vector<size_t>>> Groups() const;
    };

    /* Read one manifest document (lk_licenses.cpp). Separate from Licenses()
     * so the shape of the manifest can be checked without the core: what the
     * screens depend on is the filtering and the labels, not where the bytes
     * came from. */
    LicenseManifest ParseLicenses(std::string_view json);

    /* The BAKED manifest, the one this build actually carries
     * (lk_licenses_baked.cpp). Parsed once, then borrowed for the life of the
     * process. */
    LicenseManifest const &Licenses();

    /* One component by id, or nullptr when this build carries none by that name. */
    LicenseComponent const *LicenseById(std::string const &id);

    /* The version this build reports, as About and Licenses say it. */
    char const *AppVersion();
}
