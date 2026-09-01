package org.beetlebug.lookout

import org.beetlebug.lookout.licenses.LicenseManifest

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
 * cannot do. This checks the walk around it: what each row reads, how the rows
 * group, and that a read short of this app's own terms answers null rather than
 * an empty screen. An empty licences screen reads as "no obligation", which is
 * the one wrong answer here.
 */
@RunWith(RobolectricTestRunner::class)
class LicenseManifestTest {

    private val manifest = requireNotNull(LicenseManifest.decode(LicenseFixture.manifest))

    // ---- the entries --------------------------------------------------------

    /** The core filters by shell, so a read holds this build's components and
     *  no other's, in the order the manifest lists them. */
    @Test fun everyComponentIsReadInManifestOrder() {
        assertEquals(listOf("tile57", "wamr", "s101"), manifest.components.map { it.id })
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
        val m = LicenseManifest.decode(LicenseFixture.read(
            LicenseFixture.app, LicenseFixture.entry(id = "x", name = "X"),
        ))!!
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

    /** A read short of this app's own entry is null rather than an empty
     *  screen, which reads as "no obligation". */
    @Test fun aReadWithoutTheAppsOwnTermsIsNull() {
        assertNull(LicenseManifest.decode(null))
        assertNull(LicenseManifest.decode(emptyArray()))
        assertNull(LicenseManifest.decode(arrayOf("short")))
    }

    /** This app's terms alone is a list with no components, which is a real
     *  answer: the core returns it for a shell the manifest never names. */
    @Test fun theAppsTermsAloneIsAListWithNoComponents() {
        val m = LicenseManifest.decode(LicenseFixture.read(LicenseFixture.app))!!
        assertEquals("Lookout Marine", m.app.name)
        assertTrue(m.components.isEmpty())
    }

    /** An entry cut short is dropped rather than read with the wrong fields. */
    @Test fun aTruncatedEntryIsDropped() {
        val flat = LicenseFixture.manifest
        val m = LicenseManifest.decode(flat.copyOfRange(0, 20))!!
        assertTrue(m.components.isEmpty())
    }
}
