package org.beetlebug.lookout

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * The licence list, as the core bakes it in.
 *
 * The device suite (`LicensesTest`) checks the REAL baked list against what this
 * build actually ships, which is the thing that matters and the thing a fixture
 * cannot do. This checks the parsing rules around it: which entries this shell
 * carries, what each row reads, and that a list which will not decode answers
 * null rather than an empty screen. An empty licences screen reads as "no
 * obligation", which is the one wrong answer here.
 */
@RunWith(RobolectricTestRunner::class)
class LicenseManifestTest {

    private val json = """
    {"app":{"name":"Lookout Marine","summary":"A chartplotter.","license":"MIT",
            "copyright":"© 2026 Jeremy Collins","url":"https://beetlebug.org/",
            "text":"MIT License\n\nPermission is hereby granted"},
     "components":[
      {"id":"tile57","name":"tile57","group":"Chart and rendering",
       "summary":"The S-57, S-101 and raster chart engine.",
       "license":"MIT","license_short":"MIT","commit":"edcac13f00d",
       "pinned_in":"build.zig.zon","copyright":"© 2026 Jeremy Collins",
       "url":"https://github.com/beetlebugorg/tile57","text":"Permission is hereby granted",
       "shells":["macos","android","linux","windows"]},
      {"id":"wamr","name":"WebAssembly Micro Runtime","group":"Plugins",
       "summary":"The runtime the plugins execute in.",
       "license":"Apache 2.0 with the LLVM exception","license_short":"Apache-2.0",
       "version":"WAMR-2.4.5","pinned_in":"scripts/build-wamr.sh",
       "url":"https://github.com/bytecodealliance/wasm-micro-runtime",
       "text":"Apache License","notice":"This product includes software developed at",
       "shells":["macos","android","linux","windows"]},
      {"id":"s101","name":"IHO S-101 Portrayal Catalogue","group":"Images and data",
       "summary":"The portrayal rules.","license":"","license_note":"Upstream states no licence.",
       "commit":"62f7773aaaa","pinned_in":"tile57's build.zig.zon",
       "url":"https://github.com/iho-ohi/S-101_Portrayal-Catalogue","text":"",
       "shells":["macos","android","linux","windows"]},
      {"id":"gtk4","name":"GTK 4","group":"Platform","summary":"The Linux shell's toolkit.",
       "license":"LGPL-2.1","version":"4.14","pinned_in":"linux/meson.build",
       "url":"https://gitlab.gnome.org/GNOME/gtk","text":"GNU LESSER",
       "shells":["linux"]}]}
    """.trimIndent()

    private val manifest = requireNotNull(LicenseManifest.parse(json))

    // ---- which entries this shell carries -----------------------------------

    /** An entry belonging to another shell must not ride along: the list is a
     *  statement about what THIS binary is made of. */
    @Test fun onlyTheEntriesNamingThisShellAreKept() {
        assertEquals(listOf("tile57", "wamr", "s101"), manifest.components.map { it.id })
        assertTrue("gtk4 is a Linux entry", manifest.components.none { it.id == "gtk4" })
    }

    @Test fun theShellIsNamedOnceAndIsThisOne() {
        assertEquals("android", LicenseManifest.SHELL)
    }

    /** An entry naming no shells at all is carried by none. */
    @Test fun anEntryWithNoShellsIsDropped() {
        val m = LicenseManifest.parse(
            """{"app":{"name":"A"},"components":[{"id":"x","name":"X"}]}"""
        )!!
        assertTrue(m.components.isEmpty())
    }

    // ---- what a row reads ---------------------------------------------------

    /**
     * The narrow list column takes the SHORT form and the detail pane takes the
     * full one. The two are easy to get the wrong way round — this fixture did,
     * until the device suite's real-manifest expectations disagreed with it.
     */
    @Test fun theListColumnIsShortAndTheDetailPaneIsFull() {
        val wamr = manifest.components.first { it.id == "wamr" }
        assertEquals("Apache-2.0", wamr.licenseShort)
        assertEquals("Apache-2.0", wamr.licenseColumnLabel)
        assertEquals("Apache 2.0 with the LLVM exception", wamr.licenseLabel)
    }

    @Test fun aLicenceWithNoShortFormUsesTheFullOne() {
        val tile57 = manifest.components.first { it.id == "tile57" }
        assertEquals("MIT", tile57.licenseColumnLabel)
    }

    /**
     * A component whose terms the build could not determine says so in both
     * places. An empty column would read as "no obligation".
     */
    @Test fun anUnresolvedLicenceSaysSoRatherThanShowingNothing() {
        val s101 = manifest.components.first { it.id == "s101" }
        assertEquals("", s101.license)
        assertEquals("Not resolved", s101.licenseColumnLabel)
        assertEquals("Not resolved", s101.licenseLabel)
        assertTrue("and it carries the note saying why", s101.licenseNote.isNotEmpty())
    }

    /** A version when there is one, else the commit clipped to seven. */
    @Test fun thePinIsTheVersionOrTheShortCommit() {
        assertEquals("WAMR-2.4.5", manifest.components.first { it.id == "wamr" }.pinLabel)
        assertEquals("edcac13", manifest.components.first { it.id == "tile57" }.pinLabel)
        assertEquals("62f7773", manifest.components.first { it.id == "s101" }.pinLabel)
    }

    @Test fun aComponentWithNeitherVersionNorCommitHasNoPin() {
        val m = LicenseManifest.parse(
            """{"app":{"name":"A"},"components":[{"id":"x","name":"X","shells":["android"]}]}"""
        )!!
        assertEquals("", m.components.single().pinLabel)
    }

    @Test fun aFieldUpstreamStatesNothingForIsEmptyNotNull() {
        val tile57 = manifest.components.first { it.id == "tile57" }
        assertEquals("", tile57.version)
        assertEquals("", tile57.notice)
    }

    // ---- the groups ---------------------------------------------------------

    /** Manifest order, not alphabetical: the order is a statement about what
     *  the build is mostly made of. */
    @Test fun theGroupsKeepManifestOrder() {
        assertEquals(
            listOf("Chart and rendering", "Plugins", "Images and data"),
            manifest.groups.map { it.first },
        )
        assertEquals(listOf("tile57"), manifest.groups[0].second.map { it.id })
    }

    // ---- this app's own entry -----------------------------------------------

    /** The app heads the list and is never a component, so it stays out of the
     *  count the About row promises. */
    @Test fun theAppIsReadAndIsNotAComponent() {
        assertEquals("Lookout Marine", manifest.app.name)
        assertEquals("MIT", manifest.app.license)
        assertEquals("© 2026 Jeremy Collins", manifest.app.copyright)
        assertTrue(manifest.components.none { it.name == manifest.app.name })
    }

    /** A licence text is shown WHOLE; nothing here truncates one. */
    @Test fun theLicenceTextIsCarriedWhole() {
        assertTrue(manifest.app.text.contains("MIT License"))
        assertTrue(manifest.components.first { it.id == "wamr" }.notice.isNotEmpty())
    }

    // ---- what it refuses ----------------------------------------------------

    @Test fun aListThatWillNotDecodeIsNull() {
        assertNull(LicenseManifest.parse(null))
        assertNull(LicenseManifest.parse(""))
        assertNull(LicenseManifest.parse("{"))
        assertNull(LicenseManifest.parse("""{"components":[]}"""))
        assertNull(LicenseManifest.parse("""{"app":{"name":"A"}}"""))
    }
}
