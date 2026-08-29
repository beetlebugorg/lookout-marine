package org.beetlebug.lookout

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * The line under a plugin's name in the management section.
 *
 * A plugin's status is TEXT the plugin wrote. A managed one writes the JSON
 * line; anything else may write a plain sentence, and this shell shows whatever
 * it gets rather than falling over on it. What it must never do is show a
 * mariner raw JSON, which is what the word map is for.
 */
@RunWith(RobolectricTestRunner::class)
class StatusCaptionTest {

    private fun caption(status: String): String? =
        statusCaption(
            PluginInfo(
                id = "org.example.x", name = "X", version = "1", origin = "installed",
                status = status, capabilities = emptyList(),
                fields = emptyList(), lists = emptyList(), rows = emptyMap(),
            )
        )

    @Test fun everyStateBecomesAWord() {
        assertEquals("Running", caption("""{"state":"running"}"""))
        assertEquals("Starting", caption("""{"state":"starting"}"""))
        assertEquals("Degraded", caption("""{"state":"degraded"}"""))
        assertEquals("Disabled", caption("""{"state":"disabled"}"""))
        assertEquals("Stopped", caption("""{"state":"stopped"}"""))
    }

    /** No state at all is a plugin that came up and said nothing. */
    @Test fun anAbsentStateReadsAsRunning() {
        assertEquals("Running", caption("""{"detail":""}"""))
    }

    /** A state a newer core added shows as itself rather than as nothing. */
    @Test fun anUnknownStateShowsItself() {
        assertEquals("quiescent", caption("""{"state":"quiescent"}"""))
    }

    @Test fun theDetailIsJoinedWithAMiddleDot() {
        assertEquals("Degraded · no file loaded", caption("""{"state":"degraded","detail":"no file loaded"}"""))
        assertEquals("Running · 44 msg/s", caption("""{"state":"running","detail":"44 msg/s"}"""))
    }

    @Test fun noDetailIsJustTheWord() {
        assertEquals("Running", caption("""{"state":"running","detail":""}"""))
    }

    /** A plugin that writes a sentence gets its sentence shown. */
    @Test fun aPlainSentencePassesThrough() {
        assertEquals("Tracking 14 targets", caption("Tracking 14 targets"))
    }

    /** Saying nothing shows nothing, so the id takes the line instead. */
    @Test fun anEmptyStatusIsNoCaption() {
        assertNull(caption(""))
        assertNull(caption("   "))
    }

    /**
     * A status that starts like JSON and is not gets shown raw rather than
     * swallowed. The mariner seeing something odd beats a blank line.
     */
    @Test fun aBrokenJsonStatusIsShownAsItStands() {
        assertEquals("""{"state":""", caption("""{"state":"""))
    }
}
