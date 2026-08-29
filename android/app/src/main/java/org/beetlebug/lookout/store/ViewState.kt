package org.beetlebug.lookout.store

import org.beetlebug.lookout.settings.MarinerState

import android.content.Context

/** A saved camera pose: where the chart was when the app last had it. */
data class SavedView(
    val lon: Double,
    val lat: Double,
    val zoom: Double,
    val rotationDeg: Double,
)

/**
 * Persists the view across launches, alongside the mariner state and the chosen
 * library — reopening on the far side of the world from where you left is the
 * kind of thing a chartplotter must not do.
 *
 * Stored as Float like [MarinerState]: SharedPreferences has no double, and a
 * degree in float still resolves to ~1m, far finer than the view is ever set.
 */
object ViewState {

    private const val PREFS = "view.v1"
    private const val KEY_LON = "lon"
    private const val KEY_LAT = "lat"
    private const val KEY_ZOOM = "zoom"
    private const val KEY_ROT = "rotationDeg"

    fun load(ctx: Context): SavedView? {
        val p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (!p.contains(KEY_LON) || !p.contains(KEY_LAT) || !p.contains(KEY_ZOOM)) return null
        return SavedView(
            lon = p.getFloat(KEY_LON, 0f).toDouble(),
            lat = p.getFloat(KEY_LAT, 0f).toDouble(),
            zoom = p.getFloat(KEY_ZOOM, 0f).toDouble(),
            rotationDeg = p.getFloat(KEY_ROT, 0f).toDouble(),
        )
    }

    fun save(ctx: Context, lon: Double, lat: Double, zoom: Double, rotationDeg: Double) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putFloat(KEY_LON, lon.toFloat())
            .putFloat(KEY_LAT, lat.toFloat())
            .putFloat(KEY_ZOOM, zoom.toFloat())
            .putFloat(KEY_ROT, rotationDeg.toFloat())
            .apply()
    }
}
