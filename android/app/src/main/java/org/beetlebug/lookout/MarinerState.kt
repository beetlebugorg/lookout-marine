package org.beetlebug.lookout

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * Kotlin mirror of `tile57_mariner` — the full S-52 mariner state — and its
 * persistence. The Android twin of MarinerSettings.swift.
 *
 * The state crosses to the engine as a flat double[] whose indices are declared
 * in exactly two places: [MI] here and the `MI` block in src/jni_android.zig.
 * Edit them together. Fields the UI doesn't surface (device_scale, viewing
 * groups, …) never appear here at all: the native setter overlays these indices
 * onto the engine's current struct, so those survive untouched.
 */
object MI {
    const val SCHEME = 0
    const val DEPTH_UNIT = 1
    const val SHALLOW_CONTOUR = 2
    const val SAFETY_CONTOUR = 3
    const val DEEP_CONTOUR = 4
    const val SAFETY_DEPTH = 5
    const val FOUR_SHADE_WATER = 6
    const val DISPLAY_BASE = 7
    const val DISPLAY_STANDARD = 8
    const val DISPLAY_OTHER = 9
    const val SOUNDINGS = 10
    const val TEXT_NAMES = 11
    const val SHOW_LIGHT_DESCRIPTIONS = 12
    const val TEXT_OTHER = 13
    const val SIMPLIFIED_POINTS = 14
    const val BOUNDARY_STYLE = 15
    const val SHOW_FULL_SECTOR_LINES = 16
    const val DATA_QUALITY = 17
    const val SHOW_ISOLATED_DANGERS_SHALLOW = 18
    const val SHOW_INFORM_CALLOUTS = 19
    const val SHOW_META_BOUNDS = 20
    const val SHOW_OVERSCALE = 21
    const val SIZE_SCALE = 22
    const val TEXT_SIZE_SCALE = 23
    const val SOUNDING_SIZE_SCALE = 24
    const val DATE_DEPENDENT = 25
    const val HIGHLIGHT_DATE_DEPENDENT = 26

    /**
     * Preference keys, indexed the same way. The names match the iOS
     * UserDefaults keys so the two platforms' stored settings read alike.
     */
    val KEYS = arrayOf(
        "scheme", "depth_unit", "shallow_contour", "safety_contour", "deep_contour",
        "safety_depth", "four_shade_water", "display_base", "display_standard",
        "display_other", "soundings", "text_names", "show_light_descriptions",
        "text_other", "simplified_points", "boundary_style", "show_full_sector_lines",
        "data_quality", "show_isolated_dangers_shallow", "show_inform_callouts",
        "show_meta_bounds", "show_overscale", "size_scale", "text_size_scale",
        "sounding_size_scale", "date_dependent", "highlight_date_dependent",
    )
    const val DATE_KEY = "date_view"

    init {
        // The indices above, these keys and the MI block in jni_android.zig are
        // three parallel lists. Catch the easy half of that drift at startup
        // rather than as silently misfiled settings.
        require(KEYS.size == Lookout.MARINER_LEN) {
            "mariner key table (${KEYS.size}) != MARINER_LEN (${Lookout.MARINER_LEN})"
        }
    }
}

enum class Scheme(val label: String) { DAY("Day"), DUSK("Dusk"), NIGHT("Night") }
enum class DepthUnit(val label: String) { METERS("Meters"), FEET("Feet") }
enum class DisplayCategory(val label: String) { BASE("Base"), STANDARD("Standard"), OTHER("Other") }
enum class BoundaryStyle(val label: String) { SYMBOLIZED("Symbolized"), PLAIN("Plain") }
enum class SoundingsMode(val label: String) { FOLLOW("Follow category"), ON("Always on"), OFF("Always off") }

private inline fun <reified E : Enum<E>> entryAt(i: Int): E =
    enumValues<E>()[i.coerceIn(0, enumValues<E>().size - 1)]

/**
 * The editable mariner state, observable by Compose.
 *
 * Backed by the flat array the JNI layer speaks, with a revision counter as the
 * single snapshot-state read: any field change recomposes every reader. That is
 * the right trade for a settings form — the alternative is 27 separate state
 * objects to keep in sync with one array.
 */
class MarinerState {
    val values = DoubleArray(Lookout.MARINER_LEN)
    private var rev by mutableIntStateOf(0)
    var dateView by mutableStateOf("")

    /**
     * Counts MARINER EDITS only — what drives the debounced apply-and-save.
     * Deliberately not bumped by [loadFrom]: loading is the engine telling us
     * its state, and treating that as an edit would write the settings file on
     * every launch and echo the load straight back at the engine.
     */
    var edits by mutableIntStateOf(0)
        private set

    fun num(i: Int): Double {
        // Reading `rev` inside the getter is what subscribes a composable to
        // this state — the array itself is not snapshot-aware.
        @Suppress("UNUSED_VARIABLE") val subscribe = rev
        return values[i]
    }

    fun setNum(i: Int, value: Double) {
        if (values[i] != value) {
            values[i] = value
            rev++
            edits++
        }
    }

    fun flag(i: Int): Boolean = num(i) != 0.0
    fun setFlag(i: Int, b: Boolean) = setNum(i, if (b) 1.0 else 0.0)

    /** Replace wholesale from the engine — a load, not an edit. */
    fun loadFrom(src: DoubleArray, date: String) {
        src.copyInto(values, endIndex = minOf(src.size, values.size))
        dateView = date
        rev++
    }

    // ---- typed accessors ---------------------------------------------------

    var scheme: Scheme
        get() = entryAt(num(MI.SCHEME).toInt())
        set(v) = setNum(MI.SCHEME, v.ordinal.toDouble())

    var depthUnit: DepthUnit
        get() = entryAt(num(MI.DEPTH_UNIT).toInt())
        set(v) = setNum(MI.DEPTH_UNIT, v.ordinal.toDouble())

    var boundaryStyle: BoundaryStyle
        get() = entryAt(num(MI.BOUNDARY_STYLE).toInt())
        set(v) = setNum(MI.BOUNDARY_STYLE, v.ordinal.toDouble())

    var soundings: SoundingsMode
        get() = entryAt(num(MI.SOUNDINGS).toInt())
        set(v) = setNum(MI.SOUNDINGS, v.ordinal.toDouble())

    /**
     * Base ⊂ Standard ⊂ Other: the engine stores three independent flags, but
     * S-52 only defines the nested categories, so the UI offers one choice.
     */
    var displayCategory: DisplayCategory
        get() = when {
            flag(MI.DISPLAY_OTHER) -> DisplayCategory.OTHER
            flag(MI.DISPLAY_STANDARD) -> DisplayCategory.STANDARD
            else -> DisplayCategory.BASE
        }
        set(v) {
            setFlag(MI.DISPLAY_BASE, true)
            setFlag(MI.DISPLAY_STANDARD, v != DisplayCategory.BASE)
            setFlag(MI.DISPLAY_OTHER, v == DisplayCategory.OTHER)
        }

    var shallowContour: Double
        get() = num(MI.SHALLOW_CONTOUR); set(v) = setNum(MI.SHALLOW_CONTOUR, v)
    var safetyContour: Double
        get() = num(MI.SAFETY_CONTOUR); set(v) = setNum(MI.SAFETY_CONTOUR, v)
    var deepContour: Double
        get() = num(MI.DEEP_CONTOUR); set(v) = setNum(MI.DEEP_CONTOUR, v)
    var safetyDepth: Double
        get() = num(MI.SAFETY_DEPTH); set(v) = setNum(MI.SAFETY_DEPTH, v)

    companion object {
        private const val PREFS = "mariner.v1"

        fun prefs(ctx: Context): SharedPreferences =
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        /**
         * Saved field-by-field, NOT as raw struct bytes: the engine struct's
         * layout is an ABI detail that changes (it did twice in one week); a
         * versioned key-per-field store survives that, and unknown or missing
         * keys simply keep the engine's defaults.
         *
         * Stored as Float — SharedPreferences has no double, and every field
         * here is a contour depth, an ordinal or a size multiplier, none of
         * which care past 7 digits. It also keeps the prefs XML readable when
         * debugging on device.
         */
        fun save(ctx: Context, values: DoubleArray, dateView: String) {
            val e = prefs(ctx).edit()
            for (i in MI.KEYS.indices) e.putFloat(MI.KEYS[i], values[i].toFloat())
            e.putString(MI.DATE_KEY, dateView)
            e.apply()
        }

        /**
         * Overlay saved settings onto `values` (normally the engine's own
         * defaults, read at open). Missing keys leave the field untouched, so a
         * newly added setting keeps its engine default until the mariner
         * changes it.
         */
        fun applySavedOverlay(ctx: Context, values: DoubleArray): String? {
            val p = prefs(ctx)
            for (i in MI.KEYS.indices) {
                val k = MI.KEYS[i]
                if (!p.contains(k)) continue
                val v = p.getFloat(k, values[i].toFloat()).toDouble()
                // A zero size multiplier means "unset", not "invisible".
                val isScale = i == MI.SIZE_SCALE || i == MI.TEXT_SIZE_SCALE ||
                        i == MI.SOUNDING_SIZE_SCALE
                if (isScale && v <= 0.0) continue
                values[i] = v
            }
            return p.getString(MI.DATE_KEY, null)
        }
    }
}
