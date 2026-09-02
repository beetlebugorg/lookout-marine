package org.beetlebug.lookout

import org.beetlebug.lookout.settings.DisplayCategory
import org.beetlebug.lookout.settings.MI
import org.beetlebug.lookout.settings.MarinerState
import org.beetlebug.lookout.settings.Scheme

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * The mariner settings form.
 *
 * What the shell REMEMBERS lives in the core store, which needs the engine
 * loaded, so those tests are on the device (`StoreTest`). This is the half that
 * is the shell's own: the edit counter the settings sheet debounces on, how the
 * display categories nest, and what an ordinal past the end of an enum reads
 * as.
 */
@RunWith(RobolectricTestRunner::class)
class MarinerFormTest {

    private val ctx: Context get() = ApplicationProvider.getApplicationContext()

    // ---- the mariner's display settings -------------------------------------

    @Test fun anEditBumpsTheCounterAndALoadDoesNot() {
        val m = MarinerState()
        assertEquals(0, m.edits)

        m.safetyContour = 10.0
        assertEquals(1, m.edits)

        // A load is the engine telling us its state. Counting it as an edit
        // would write the settings file on every launch and echo the load
        // straight back at the engine.
        m.loadFrom(DoubleArray(Lookout.MARINER_LEN), "")
        assertEquals(1, m.edits)
    }

    @Test fun settingAFieldToWhatItAlreadyIsIsNotAnEdit() {
        val m = MarinerState()
        m.safetyContour = 10.0
        val after = m.edits
        m.safetyContour = 10.0
        assertEquals(after, m.edits)
    }

    /**
     * Base is contained in Standard is contained in Other (S-52 §10.2). The
     * engine stores three independent flags; the mariner gets one choice.
     */
    @Test fun theDisplayCategoriesNest() {
        val m = MarinerState()

        m.displayCategory = DisplayCategory.BASE
        assertTrue(m.flag(MI.DISPLAY_BASE))
        assertFalse(m.flag(MI.DISPLAY_STANDARD))
        assertFalse(m.flag(MI.DISPLAY_OTHER))
        assertEquals(DisplayCategory.BASE, m.displayCategory)

        m.displayCategory = DisplayCategory.STANDARD
        assertTrue(m.flag(MI.DISPLAY_BASE))
        assertTrue(m.flag(MI.DISPLAY_STANDARD))
        assertFalse(m.flag(MI.DISPLAY_OTHER))
        assertEquals(DisplayCategory.STANDARD, m.displayCategory)

        m.displayCategory = DisplayCategory.OTHER
        assertTrue(m.flag(MI.DISPLAY_BASE))
        assertTrue(m.flag(MI.DISPLAY_STANDARD))
        assertTrue(m.flag(MI.DISPLAY_OTHER))
        assertEquals(DisplayCategory.OTHER, m.displayCategory)
    }

    /** An ordinal the engine has that this build does not clamps rather than
     *  throwing: a newer core must not crash an older shell. */
    @Test fun anOrdinalPastTheEnumClampsIntoRange() {
        val m = MarinerState()
        m.setNum(MI.SCHEME, 99.0)
        assertEquals(Scheme.NIGHT, m.scheme)
        m.setNum(MI.SCHEME, -1.0)
        assertEquals(Scheme.DAY, m.scheme)
    }

}
