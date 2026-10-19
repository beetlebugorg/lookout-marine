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
    /** One press of the draft stepper, and the deepest draft the step
     *  accepts. The plan holds the draft between the two. */
    val draftStep get() = v[17]
    val draftMax get() = v[18]

    companion object {
        /** The plan for a boat. A draft of zero is the core's starting
         *  keelboat. */
        fun of(draftM: Double, clearanceM: Double, feet: Boolean) =
            DepthPlan(Lookout.depthPlan(draftM, clearanceM, feet))
    }
}

/**
 * The depth step's picture (lookout_depth_preview in lookout-shell.h). Every
 * coordinate is in a unit square with y down. A line's point i is at
 * x = i / 48.
 */
class DepthPreview private constructor(private val v: DoubleArray) {
    /** One line's y values: [SHORE], [SAFETY_DEPTH], [SAFETY_CONTOUR] or
     *  [DEEP_CONTOUR]. */
    fun line(which: Int): DoubleArray = v.copyOfRange(which * POINTS, (which + 1) * POINTS)
    fun spotX(i: Int) = v[SPOTS_AT + i]
    fun spotY(i: Int) = v[SPOTS_AT + SPOTS + i]
    fun sounding(i: Int) = v[SPOTS_AT + 2 * SPOTS + i].toInt()
    fun bold(i: Int) = v[SPOTS_AT + 3 * SPOTS + i] != 0.0

    companion object {
        const val SHORE = 0
        const val SAFETY_DEPTH = 1
        const val SAFETY_CONTOUR = 2
        const val DEEP_CONTOUR = 3
        const val POINTS = 49
        const val SPOTS = 12
        private const val SPOTS_AT = 4 * POINTS

        fun of(draftM: Double, clearanceM: Double, feet: Boolean) =
            DepthPreview(Lookout.depthPreview(draftM, clearanceM, feet))
    }
}
