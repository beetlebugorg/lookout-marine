/* The licence manifest.
 *
 * One manifest serves every shell, so the thing that matters here is the
 * filter: a build must list the components it actually carries and no others.
 * Listing another shell's dependency is a false statement about this binary,
 * and dropping one of its own is a licence obligation unmet.
 *
 * The labels matter for the same reason. A component whose terms could not be
 * determined has to SAY so — a blank licence column reads as "no licence",
 * which is the one thing it never means.
 */
#include "lk_test.h"

#include "lk_licenses.h"

using namespace lktest;
using lkw::LicenseComponent;
using lkw::ParseLicenses;

namespace
{
    char const *kManifest = R"({
      "app": {
        "name": "Lookout Marine",
        "summary": "A chartplotter",
        "license": "MIT",
        "copyright": "2026 the authors",
        "url": "https://example.invalid",
        "text": "MIT License\n\nPermission is hereby granted..."
      },
      "components": [
        { "id": "wamr", "name": "WAMR", "group": "Runtime",
          "license": "Apache-2.0 WITH LLVM-exception",
          "license_short": "Apache-2.0",
          "commit": "0123456789abcdef", "pinned_in": "scripts/build-wamr.sh",
          "shells": ["windows", "linux", "android", "macos"],
          "text": "Apache License..." },
        { "id": "winappsdk", "name": "Windows App SDK", "group": "Platform",
          "license": "MIT", "version": "2.3.1",
          "shells": ["windows"] },
        { "id": "gtk", "name": "GTK", "group": "Platform",
          "license": "LGPL-2.1", "version": "4.14",
          "shells": ["linux"] },
        { "id": "mystery", "name": "Mystery", "group": "Runtime",
          "license": "", "license_note": "no licence file upstream",
          "version": "1.0", "shells": ["windows"] },
        { "id": "nobody", "name": "Nobody", "group": "Runtime" }
      ]
    })";
}

void TestLicenses()
{
    Suite("lk_licenses");

    LK_CASE("this build lists what this build carries, and nothing else");
    {
        auto m = ParseLicenses(kManifest);
        LK_EQ(m.ok, true);
        LK_EQ(m.components.size(), (size_t)3); /* gtk and the shell-less one are out */
        LK_EQ(m.components[0].id, std::string("wamr"));
        LK_EQ(m.components[1].id, std::string("winappsdk"));
        LK_EQ(m.components[2].id, std::string("mystery"));
    }

    LK_CASE("an entry that names no shells is nobody's");
    {
        auto m = ParseLicenses(R"({"app":{"name":"A"},"components":[{"id":"x"}]})");
        LK_EQ(m.components.size(), (size_t)0);
        LK_EQ(m.ok, false); /* no components is not a manifest this build can show */
    }

    LK_CASE("the app's own terms are not a component");
    {
        auto m = ParseLicenses(kManifest);
        LK_EQ(m.app.name, std::string("Lookout Marine"));
        LK_EQ(m.app.license, std::string("MIT"));
        LK_CHECK(m.app.text.find("Permission is hereby granted") != std::string::npos);
        for (auto const &c : m.components)
            LK_NE(c.id, std::string("app"));
    }

    LK_CASE("every field is set, and an unstated one is empty");
    {
        auto m = ParseLicenses(kManifest);
        LicenseComponent const &wamr = m.components[0];
        LK_EQ(wamr.name, std::string("WAMR"));
        LK_EQ(wamr.group, std::string("Runtime"));
        LK_EQ(wamr.pinned_in, std::string("scripts/build-wamr.sh"));
        LK_EQ(wamr.version, std::string("")); /* pinned by commit, not version */
        LK_EQ(wamr.notice, std::string(""));
        LK_EQ(wamr.summary, std::string(""));
    }

    /* What it is pinned at: its version, or the first seven of its commit. */
    LK_CASE("the pin label");
    {
        auto m = ParseLicenses(kManifest);
        LK_EQ(m.components[0].PinLabel(), std::string("0123456"));
        LK_EQ(m.components[1].PinLabel(), std::string("2.3.1"));

        LicenseComponent neither;
        LK_EQ(neither.PinLabel(), std::string(""));

        LicenseComponent shortish;
        shortish.commit = "abc";
        LK_EQ(shortish.PinLabel(), std::string("abc"));
    }

    /* Terms that could not be determined say so rather than showing nothing. */
    LK_CASE("the licence labels");
    {
        auto m = ParseLicenses(kManifest);
        LicenseComponent const &wamr = m.components[0];
        LK_EQ(wamr.LicenseLabel(), std::string("Apache-2.0 WITH LLVM-exception"));
        LK_EQ(wamr.ColumnLabel(), std::string("Apache-2.0")); /* the narrow column */

        LicenseComponent const &sdk = m.components[1];
        LK_EQ(sdk.ColumnLabel(), std::string("MIT")); /* no short form; the full one */

        LicenseComponent const &mystery = m.components[2];
        LK_EQ(mystery.LicenseLabel(), std::string("Not resolved"));
        LK_EQ(mystery.ColumnLabel(), std::string("Not resolved"));
        LK_EQ(mystery.license_note, std::string("no licence file upstream"));
    }

    LK_CASE("the groups keep the manifest's order and their rows");
    {
        auto groups = ParseLicenses(kManifest).Groups();
        LK_EQ(groups.size(), (size_t)2);
        LK_EQ(groups[0].first, std::string("Runtime"));
        LK_EQ(groups[0].second.size(), (size_t)2); /* wamr and mystery */
        LK_EQ(groups[0].second[0], (size_t)0);
        LK_EQ(groups[0].second[1], (size_t)2);
        LK_EQ(groups[1].first, std::string("Platform"));
        LK_EQ(groups[1].second.size(), (size_t)1);
    }

    /* A manifest that will not parse is not an empty one: the screen says the
     * list could not be read rather than claiming this build carries nothing. */
    LK_CASE("a manifest that does not parse is not ok");
    {
        for (char const *bad : { "", "not json", "[]", "{", "{\"app\":\"text\"}" })
        {
            auto m = ParseLicenses(bad);
            LK_EQ(m.ok, false);
            LK_EQ(m.components.size(), (size_t)0);
        }
    }

    LK_CASE("an app with no name is not ok either");
    {
        auto m = ParseLicenses(R"({"components":[{"id":"x","shells":["windows"]}]})");
        LK_EQ(m.components.size(), (size_t)1);
        LK_EQ(m.ok, false);
    }
}
