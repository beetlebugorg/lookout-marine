package org.beetlebug.lookout

import org.beetlebug.lookout.settings.MI

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The mariner index table, checked against itself and against the engine's
 * declared length.
 *
 * [MI] and the `MI` block in src/jni_android.zig are parallel lists: the same
 * fields, in the same order, written twice. A field inserted on one side and
 * not the other misfiles every setting after it, silently, because the crossing
 * is a flat double[] with no names in it.
 *
 * This is the cheap half of that check, and the half that needs no device.
 * `MARINER_LEN` is a Java compile-time constant, so reading it here does not
 * load the native library. The other half — that the NAMES agree, in order —
 * needs the engine to answer, and lives in the instrumented suite.
 *
 * It is also the smoke test for the JVM suite itself: if this does not run,
 * nothing else in src/test does either.
 */
class MarinerIndexTest {

    @Test fun theKeyTableIsAsLongAsTheEngineSaysTheStructIs() {
        assertEquals(
            "the mariner key table and MARINER_LEN have drifted apart",
            Lookout.MARINER_LEN,
            MI.KEYS.size,
        )
    }

    /**
     * Every index names a distinct slot, and the slots run 0..n-1 with no gap.
     * A duplicated constant is the drift this catches without needing the Zig
     * side at all: two names for one slot means one setting was silently lost.
     */
    @Test fun theIndicesAreContiguousAndDistinct() {
        val indices = listOf(
            MI.SCHEME, MI.DEPTH_UNIT, MI.SHALLOW_CONTOUR, MI.SAFETY_CONTOUR,
            MI.DEEP_CONTOUR, MI.SAFETY_DEPTH, MI.FOUR_SHADE_WATER, MI.DISPLAY_BASE,
            MI.DISPLAY_STANDARD, MI.DISPLAY_OTHER, MI.SOUNDINGS, MI.TEXT_NAMES,
            MI.SHOW_LIGHT_DESCRIPTIONS, MI.TEXT_OTHER, MI.SIMPLIFIED_POINTS,
            MI.BOUNDARY_STYLE, MI.SHOW_FULL_SECTOR_LINES, MI.DATA_QUALITY,
            MI.SHOW_ISOLATED_DANGERS_SHALLOW, MI.SHOW_INFORM_CALLOUTS,
            MI.SHOW_META_BOUNDS, MI.SHOW_OVERSCALE, MI.SIZE_SCALE,
            MI.TEXT_SIZE_SCALE, MI.SOUNDING_SIZE_SCALE, MI.DATE_DEPENDENT,
            MI.HIGHLIGHT_DATE_DEPENDENT,
        )
        assertEquals("an index constant is missing from this list", MI.KEYS.size, indices.size)
        assertEquals("two fields share an index", indices.size, indices.toSet().size)
        assertEquals("the indices are not 0..n-1", (0 until MI.KEYS.size).toList(), indices.sorted())
    }

    /** A preference key names one field. Two the same would overwrite. */
    @Test fun everyPreferenceKeyIsDistinctAndNonEmpty() {
        assertEquals("two fields share a preference key", MI.KEYS.size, MI.KEYS.toSet().size)
        assertTrue("a preference key is empty", MI.KEYS.none { it.isEmpty() })
    }

    /**
     * The date is stored beside the numbered fields and must not collide with
     * one: it is a string in the same preferences file.
     */
    @Test fun theDateKeyIsNotOneOfTheNumberedFields() {
        assertTrue(MI.DATE_KEY !in MI.KEYS)
    }
}
