package org.beetlebug.lookout

import org.beetlebug.lookout.charts.Library
import org.beetlebug.lookout.hud.LookoutTheme
import org.beetlebug.lookout.licenses.LicenseManifest
import org.beetlebug.lookout.licenses.LicenseSelection
import org.beetlebug.lookout.licenses.LicensesScreen

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The licenses screen, on a device.
 *
 * It reads the REAL baked list ([Lookout.licensesJson]), not a fixture: what
 * this screen has to get right is which components this build actually carries
 * and what each row says about one, and a fixture would agree with itself
 * while the binary shipped something else.
 *
 * The expected rows are held here as a second copy of vendor/licenses/licenses.json,
 * so a row that silently loses its licence or its pin has to disagree with
 * something.
 */
@RunWith(AndroidJUnit4::class)
class LicensesTest {

    @get:Rule val compose = createComposeRule()

    /** One row, as the manifest says it should read. */
    data class Expected(
        val name: String,
        val summary: String,
        /** The short form the list column shows. */
        val column: String,
        /** The full label the detail's License row shows. */
        val licenseLabel: String,
        val pin: String,
        val pinnedIn: String,
        val url: String,
        /** A phrase from the licence text, proving the body is the real one. */
        val textPhrase: String,
    )

    private val expected = listOf(
        Expected("tile57", "The S-57, S-101 and raster chart engine.", "MIT", "MIT",
            "edcac13", "build.zig.zon", "https://github.com/beetlebugorg/tile57",
            "Permission is hereby granted, free of charge"),
        Expected("charttable", "Renders the chart.", "MIT", "MIT",
            "0d137fa", "build.zig.zon", "https://github.com/beetlebugorg/charttable",
            "Permission is hereby granted, free of charge"),
        Expected("IHO S-101 Portrayal Catalogue",
            "The portrayal rules: which symbol, which color, which text, at which scale.",
            "Not resolved", "Not resolved", "62f7773", "tile57's build.zig.zon",
            "https://github.com/iho-ohi/S-101_Portrayal-Catalogue", ""),
        Expected("WebAssembly Micro Runtime", "The runtime the plugins execute in.",
            "Apache-2.0", "Apache 2.0 with the LLVM exception", "WAMR-2.4.5",
            "scripts/build-wamr.sh", "https://github.com/bytecodealliance/wasm-micro-runtime",
            "Apache License"),
        Expected("stb_image", "Reads the PNG and JPEG files a chart carries.",
            "MIT OR Unlicense", "MIT or the Unlicense, at your option", "2.30",
            "vendor/stb/stb_image.h", "https://github.com/nothings/stb", "ALTERNATIVE A"),
        Expected("GSHHG coastline", "The world coastline baked into the basemap.",
            "LGPL", "GNU Lesser General Public License", "",
            "vendor/gshhg/coastline.geojson.gz", "https://www.soest.hawaii.edu/pwessel/gshhg/",
            "GNU LESSER GENERAL PUBLIC LICENSE"),
        Expected("Vulkan headers", "The Vulkan API headers the Linux and Android builds compile against.",
            "Apache-2.0", "Apache 2.0", "VK_HEADER_VERSION 350",
            "vendor/vulkan/include/vulkan/vulkan_core.h",
            "https://github.com/KhronosGroup/Vulkan-Headers", "Apache License"),
        Expected("libwebp", "Decodes the WebP tiles a chart link serves.",
            "BSD-3-Clause", "BSD 3-Clause", "1.4.0", "charttable's build.zig.zon",
            "https://github.com/webmproject/libwebp",
            "Redistribution and use in source and binary forms"),
        Expected("libpng", "Reads interlaced and 16-bit PNGs.", "libpng-2.0",
            "PNG Reference Library License version 2", "1.6.44", "charttable's build.zig.zon",
            "https://github.com/pnggroup/libpng", "COPYRIGHT NOTICE, DISCLAIMER, and LICENSE"),
        Expected("zlib", "Deflate compression.", "Zlib", "zlib License", "1.3.1",
            "charttable's build.zig.zon", "https://github.com/madler/zlib",
            "Jean-loup Gailly and Mark Adler"),
    )

    private val unresolved = expected[2]
    private val appName = "Lookout Marine"
    private val appCopyright = "© 2026 Jeremy Collins"

    private fun manifest(): LicenseManifest {
        val m = LicenseManifest.current
        assertNotNull("the baked licence list would not parse", m)
        return m!!
    }

    /** The screen, driven the way the settings pane drives it. */
    private fun showLicenses() {
        compose.setContent {
            LookoutTheme {
                var entry by remember { mutableStateOf<LicenseSelection?>(null) }
                LicensesScreen(LicenseManifest.current, entry) { entry = it }
            }
        }
    }

    // ---- the manifest -------------------------------------------------------

    @Test fun theBakedListCarriesTheComponentsThisShellShips() {
        val m = manifest()
        assertEquals("android carries a different number of components than the list says",
            expected.size, m.components.size)
        assertEquals("the components are out of manifest order",
            expected.map { it.name }, m.components.map { it.name })
        assertEquals(appName, m.app.name)
        assertEquals(appCopyright, m.app.copyright)
    }

    /** An entry belonging to another shell must not ride along. */
    @Test fun theListDropsWhatOtherShellsCarry() {
        val m = manifest()
        for (foreign in listOf("gtk4", "glib", "libsoup", "json-glib", "libx11", "wayland")) {
            assertTrue("$foreign is a Linux entry and does not belong in the Android list",
                m.components.none { it.id == foreign })
        }
    }

    /** A row's licence column is the SHORT form when there is one. */
    @Test fun everyRowReportsTheLicenceAndPinTheManifestGivesIt() {
        val m = manifest()
        for (e in expected) {
            val c = m.components.first { it.name == e.name }
            assertEquals("${e.name}'s licence column", e.column, c.licenseColumnLabel)
            assertEquals("${e.name}'s licence label", e.licenseLabel, c.licenseLabel)
            assertEquals("${e.name}'s pin", e.pin, c.pinLabel)
            assertEquals("${e.name}'s summary", e.summary, c.summary)
        }
    }

    // ---- the list -----------------------------------------------------------

    @Test fun theListShowsThisAppAndEveryComponent() {
        showLicenses()
        compose.onNodeWithText("THIS APP").assertIsDisplayed()
        compose.onNodeWithText("COMPONENTS").assertIsDisplayed()
        compose.onNodeWithText(appName).assertIsDisplayed()
        compose.onNodeWithText(appCopyright).assertIsDisplayed()

        // A row merges its children, so one node carries the name, the summary,
        // the licence column and the pin. Matching all of them at once is both
        // the check that the row is whole and the only way to tell two rows
        // apart: "MIT" alone matches three of them.
        for (e in expected) {
            compose.onNodeWithTag("licenses-list").performScrollToNode(hasText(e.name))
            var row = hasText(e.name, substring = true)
                .and(hasText(e.summary, substring = true))
                .and(hasText(e.column, substring = true))
            if (e.pin.isNotEmpty()) row = row.and(hasText(e.pin, substring = true))
            compose.onNode(row).assertIsDisplayed()
        }
    }

    /** Ten entries, so neither the search field nor the group headings, which
     *  only earn their place above twelve, appear. */
    @Test fun tenComponentsGetNoSearchField() {
        showLicenses()
        assertTrue(
            "a search field appeared below the twelve-row threshold",
            compose.onAllNodes(hasTestTag("licenses-search")).fetchSemanticsNodes().isEmpty(),
        )
    }

    @Test fun tenComponentsGetNoGroupHeadings() {
        showLicenses()
        for (group in listOf("CHART AND RENDERING", "PLUGINS", "IMAGES AND DATA", "PLATFORM")) {
            assertTrue(
                "group heading '$group' appeared below the twelve-row threshold",
                compose.onAllNodes(hasText(group)).fetchSemanticsNodes().isEmpty(),
            )
        }
    }

    // ---- the detail panes ---------------------------------------------------

    @Test fun aComponentRowOpensItsTerms() {
        showLicenses()
        val e = expected.first { it.name == "libwebp" }

        compose.onNodeWithTag("licenses-list").performScrollToNode(hasText(e.name))
        compose.onNodeWithText(e.name).performClick()

        compose.onNodeWithText("Upstream").assertIsDisplayed()
        compose.onNodeWithText(e.licenseLabel).assertIsDisplayed()
        compose.onNodeWithText(e.url).assertIsDisplayed()
        compose.onNodeWithContentDescription("Copy address").assertIsDisplayed()
        compose.onNodeWithTag("license-detail").performScrollToNode(hasText(e.pinnedIn))
        compose.onNodeWithText(e.pinnedIn).assertIsDisplayed()
    }

    /** The licence body is the real text, and it is not truncated. */
    @Test fun aComponentPaneCarriesTheWholeLicence() {
        showLicenses()
        val e = expected.first { it.name == "zlib" }

        compose.onNodeWithTag("licenses-list").performScrollToNode(hasText(e.name))
        compose.onNodeWithText(e.name).performClick()

        val text = manifest().components.first { it.name == e.name }.text
        assertTrue("${e.name}'s licence text is not the real one",
            text.contains(e.textPhrase))
        compose.onNodeWithTag("license-detail").performScrollToNode(hasTestTag("license-text"))
        compose.onNodeWithTag("license-text").assertIsDisplayed()
    }

    /** A component whose terms the build could not determine says so, rather
     *  than showing an empty pane. */
    @Test fun anUnresolvedComponentExplainsItself() {
        val m = manifest()
        val c = m.components.first { it.name == unresolved.name }
        assertTrue("the unresolved entry ships a licence text after all", c.text.isEmpty())
        assertTrue("the unresolved entry carries no note saying why",
            c.licenseNote.isNotEmpty())

        showLicenses()
        compose.onNodeWithTag("licenses-list").performScrollToNode(hasText(c.name))
        compose.onNodeWithText("Not resolved").assertIsDisplayed()
        compose.onNodeWithText(c.name).performClick()

        compose.onNodeWithText("License not resolved").assertIsDisplayed()
        compose.onNodeWithText(c.licenseNote).assertIsDisplayed()
        compose.onNodeWithTag("license-detail").performScrollToNode(hasText("No license text."))
        compose.onNodeWithText("No license text.").assertIsDisplayed()
    }

    /** This app's own entry, which carries the terms the binary ships under. */
    @Test fun theAppsOwnEntryCarriesItsTerms() {
        showLicenses()
        compose.onNodeWithText(appName).performClick()

        compose.onNodeWithText("Upstream").assertIsDisplayed()
        compose.onNodeWithText(appCopyright).assertIsDisplayed()
        assertTrue("the app's own licence text is missing",
            manifest().app.text.contains("MIT License"))
        compose.onNodeWithTag("license-detail").performScrollToNode(hasTestTag("license-text"))
        compose.onNodeWithTag("license-text").assertIsDisplayed()
    }

    /** The app's entry is not a component and stays out of the count. */
    @Test fun theAppIsNotCountedAsAComponent() {
        val m = manifest()
        assertTrue("the app's own entry is in the component list",
            m.components.none { it.name == appName })
        assertEquals(expected.size, m.components.size)
    }
}
