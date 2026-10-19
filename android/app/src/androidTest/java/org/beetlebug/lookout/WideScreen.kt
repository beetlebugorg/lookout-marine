package org.beetlebug.lookout

import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assume

/**
 * Skip a test whose subject only exists on a wide screen.
 *
 * Some of this chrome has two layouts and the app picks by width: the readouts
 * capsule puts its raster pill on one row on a tablet and drops it on a phone,
 * and a declared plugin table shows every column where there is room. A test
 * of the wide one asserts something a narrow device never draws, and failing
 * there says nothing about the code.
 *
 * A skip rather than a silent pass: the run says which device could not answer.
 */
fun assumeWideScreen(minDp: Int = 600) {
    val ctx = InstrumentationRegistry.getInstrumentation().targetContext
    val dp = ctx.resources.configuration.screenWidthDp
    Assume.assumeTrue(
        "this layout wants a screen ${minDp}dp wide or more; this one is ${dp}dp",
        dp >= minDp,
    )
}
