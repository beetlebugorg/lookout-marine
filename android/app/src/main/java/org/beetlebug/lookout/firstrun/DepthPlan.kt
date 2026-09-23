package org.beetlebug.lookout.firstrun

import org.beetlebug.lookout.Lookout

/**
 * The core's depth plan (lookout_depth_plan in lookout-shell.h): the four
 * depth settings for a boat, and what the depth step displays.
 *
 * A name ending in M is metres. The rest are in the unit on screen.
 */
class DepthPlan private constructor(private val v: DoubleArray) {
    val draftM get() = v[0]
    val clearanceM get() = v[1]
    val draftRoundedM get() = v[2]
    val safetyDepthM get() = v[3]
    val shallowContourM get() = v[4]
    val safetyContourM get() = v[5]
    val deepContourM get() = v[6]
    val draft get() = v[7]
    val clearance get() = v[8]
    val safetyDepth get() = v[9]
    val safetyContour get() = v[10]
    val deepContour get() = v[11]
    val clearances get() = listOf(v[12], v[13], v[14], v[15])
    val metresPerUnit get() = v[16]

    companion object {
        /** The plan for a boat. A draft of zero is the core's starting
         *  keelboat. */
        fun of(draftM: Double, clearanceM: Double, feet: Boolean) =
            DepthPlan(Lookout.depthPlan(draftM, clearanceM, feet))
    }
}
