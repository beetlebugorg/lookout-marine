package org.beetlebug.lookout

import org.beetlebug.lookout.settings.MI

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The other half of the mariner index check, the half that needs the engine.
 *
 * [MI] and the `MI` block in src/jni_android.zig are parallel lists: the same
 * fields, in the same order, written twice. They cross as a flat double[] with
 * no names in it, so a field inserted on one side and not the other misfiles
 * every setting after it and nothing complains — the chart simply draws with
 * the wrong safety contour, or the wrong scheme, and the mariner is the one
 * who finds out.
 *
 * `MarinerIndexTest` on the JVM checks the LENGTH, which a reordering passes.
 * This checks the names and the order, which it does not, and it is the reason
 * `nMarinerKeys` exists at all.
 */
@RunWith(AndroidJUnit4::class)
class MarinerKeysTest {

    @Test fun theKotlinKeyTableMatchesTheEngineFieldForField() {
        val fromEngine = Lookout.marinerKeys().toList()
        assertEquals(
            "the shell and src/jni_android.zig disagree about the mariner fields",
            fromEngine,
            MI.KEYS.toList(),
        )
    }

    /** The engine's own list has to be the length it says it is. */
    @Test fun theEngineReportsAsManyNamesAsItDeclaresFields() {
        assertEquals(Lookout.MARINER_LEN, Lookout.marinerKeys().size)
    }

    /** No name is blank: a hole would mean two Zig constants shared an index
     *  and one field was silently lost. */
    @Test fun everyNameIsFilledIn() {
        for ((i, name) in Lookout.marinerKeys().withIndex()) {
            assertEquals("index $i has no name", true, name.isNotEmpty())
        }
    }
}
