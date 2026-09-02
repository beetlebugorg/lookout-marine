/* The licence manifest, as the two screens read it.
 *
 * One manifest serves every shell and the CORE filters it to the shell that
 * asks, so what is left here is the labels. They matter for the same reason
 * the filter does: a component whose terms could not be determined has to SAY
 * so — a blank licence column reads as "no licence", which is the one thing it
 * never means.
 */
#include "lk_test.h"

#include "lk_licenses.h"

using namespace lktest;
using lkw::LicenseComponent;
using lkw::LicenseManifest;

namespace
{
    lookout_license Entry(char const *id, char const *name, char const *group,
                          char const *license, char const *license_short,
                          char const *license_note, char const *version,
                          char const *commit, char const *pinned_in)
    {
        lookout_license c{};
        c.id = id;
        c.name = name;
        c.group = group;
        c.summary = "";
        c.license = license;
        c.license_short = license_short;
        c.license_note = license_note;
        c.version = version;
        c.commit = commit;
        c.pinned_in = pinned_in;
        c.copyright = "";
        c.url = "";
        c.text = "Apache License...";
        c.notice = "";
        return c;
    }

    /* The three components this build would carry, in the manifest's order. */
    LicenseManifest Manifest()
    {
        LicenseManifest m;
        m.app.name = "Lookout Marine";
        m.app.license = "MIT";
        m.app.text = "MIT License\n\nPermission is hereby granted...";
        m.components.emplace_back(Entry("wamr", "WAMR", "Runtime",
                                        "Apache-2.0 WITH LLVM-exception", "Apache-2.0", "",
                                        "", "0123456789abcdef", "scripts/build-wamr.sh"));
        m.components.emplace_back(Entry("winappsdk", "Windows App SDK", "Platform", "MIT",
                                        "", "", "2.3.1", "", ""));
        m.components.emplace_back(Entry("mystery", "Mystery", "Runtime", "", "",
                                        "no licence file upstream", "1.0", "", ""));
        m.ok = true;
        return m;
    }
}

void TestLicenses()
{
    Suite("lk_licenses");

    LK_CASE("every field the core states reaches the row");
    {
        LicenseComponent const &wamr = Manifest().components[0];
        LK_EQ(wamr.id, std::string("wamr"));
        LK_EQ(wamr.name, std::string("WAMR"));
        LK_EQ(wamr.group, std::string("Runtime"));
        LK_EQ(wamr.pinned_in, std::string("scripts/build-wamr.sh"));
        LK_EQ(wamr.version, std::string("")); /* pinned by commit, not version */
        LK_EQ(wamr.notice, std::string(""));
        LK_EQ(wamr.summary, std::string(""));
    }

    LK_CASE("the app's own terms are not a component");
    {
        auto m = Manifest();
        LK_EQ(m.app.name, std::string("Lookout Marine"));
        LK_EQ(m.app.license, std::string("MIT"));
        LK_CHECK(m.app.text.find("Permission is hereby granted") != std::string::npos);
        for (auto const &c : m.components)
            LK_NE(c.id, std::string("app"));
    }

    /* What it is pinned at: its version, or the first seven of its commit. */
    LK_CASE("the pin label");
    {
        auto m = Manifest();
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
        auto m = Manifest();
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
        auto groups = Manifest().Groups();
        LK_EQ(groups.size(), (size_t)2);
        LK_EQ(groups[0].first, std::string("Runtime"));
        LK_EQ(groups[0].second.size(), (size_t)2); /* wamr and mystery */
        LK_EQ(groups[0].second[0], (size_t)0);
        LK_EQ(groups[0].second[1], (size_t)2);
        LK_EQ(groups[1].first, std::string("Platform"));
        LK_EQ(groups[1].second.size(), (size_t)1);
    }

    /* Above this many rows the screens group them under their headings and
     * offer a search. The number is the core's, so the four shells stop each
     * holding their own copy of it. */
    LK_CASE("the grouping threshold is the core's");
    {
        LK_EQ(LOOKOUT_LICENSES_GROUP_ABOVE, 12);
    }
}
