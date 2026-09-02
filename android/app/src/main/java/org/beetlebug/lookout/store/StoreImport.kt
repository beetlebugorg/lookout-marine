package org.beetlebug.lookout.store

import android.content.Context
import org.beetlebug.lookout.settings.MI

/**
 * The one-time move out of SharedPreferences.
 *
 * Everything the shell keeps used to live in five preference files under flat
 * keys. It lives in the core store now, in the groups every shell writes. This
 * copies what a mariner already has across, once, and then the preference
 * files are dead: nothing else in the shell reads them.
 *
 * It runs at the store's own open, before anything reads a setting. A launch
 * that finds the store already stamped does nothing, so the copy happens on the
 * first launch after the change and never again.
 */
object StoreImport {

    /** Set once the copy has run. It lives in the view group, which is the one
     *  a store always ends up with. */
    private const val STAMP_GROUP = Store.Group.VIEW
    private const val STAMP_KEY = "imported"

    fun once(ctx: Context) {
        if (Store.flag(STAMP_GROUP, STAMP_KEY)) return
        Store.setFlag(STAMP_GROUP, STAMP_KEY, true)

        view(ctx)
        mariner(ctx)
        raster(ctx)
        plugins(ctx)
        chartLinks(ctx)
        seedChartSets(ctx)
    }

    /** The camera pose. It was Float, because SharedPreferences has no double. */
    private fun view(ctx: Context) {
        val p = ctx.getSharedPreferences("view.v1", Context.MODE_PRIVATE)
        if (!p.contains("lon")) return
        Store.setNumber(Store.Group.VIEW, "lon", p.getFloat("lon", 0f).toDouble())
        Store.setNumber(Store.Group.VIEW, "lat", p.getFloat("lat", 0f).toDouble())
        Store.setNumber(Store.Group.VIEW, "zoom", p.getFloat("zoom", 0f).toDouble())
        Store.setNumber(Store.Group.VIEW, "rotation_deg", p.getFloat("rotationDeg", 0f).toDouble())
    }

    /** The mariner settings. Every key already has the name the core uses. */
    private fun mariner(ctx: Context) {
        val p = ctx.getSharedPreferences("mariner.v1", Context.MODE_PRIVATE)
        for (k in MI.KEYS) {
            if (!p.contains(k)) continue
            Store.setNumber(Store.Group.MARINER, k, p.getFloat(k, 0f).toDouble())
        }
        p.getString(MI.DATE_KEY, null)?.let { Store.setText(Store.Group.MARINER, MI.DATE_KEY, it) }
    }

    private fun raster(ctx: Context) {
        val p = ctx.getSharedPreferences("rastercharts.v1", Context.MODE_PRIVATE)
        // The ordered list is the one the mariner sees; the set is what an
        // older build wrote, and is only read when there is no ordered one.
        val ordered = p.getString("paths.ordered", null)
            ?.split("\n")?.filter { it.isNotEmpty() }
        val paths = ordered ?: p.getStringSet("paths", null)?.toList().orEmpty()
        if (paths.isNotEmpty()) Store.setList(Store.Group.RASTER, "paths", paths)
        p.getStringSet("off", null)?.let {
            if (it.isNotEmpty()) Store.setList(Store.Group.RASTER, "off", it.toList())
        }
        p.getStringSet("hidden.names", null)?.let {
            if (it.isNotEmpty()) Store.setList(Store.Group.RASTER, "hidden", it.toList())
        }
        if (p.contains("chart.hidden")) {
            Store.setFlag(Store.Group.RASTER, "chart_hidden", p.getBoolean("chart.hidden", false))
        }
    }

    /**
     * The plugin values and rows. A scalar was stored as raw double bits,
     * because SharedPreferences has no double; a row list was the JSON the
     * shell sends the core.
     */
    private fun plugins(ctx: Context) {
        val scalars = ctx.getSharedPreferences("plugins.v1", Context.MODE_PRIVATE)
        for ((k, v) in scalars.all) {
            val bits = v as? Long ?: continue
            Store.setNumber(Store.Group.PLUGINS, k, java.lang.Double.longBitsToDouble(bits))
        }
        val rows = ctx.getSharedPreferences("plugins.lists.v1", Context.MODE_PRIVATE)
        for ((k, v) in rows.all) {
            val json = v as? String ?: continue
            Store.setText(Store.Group.PLUGINS, "$k.rows", json)
        }
    }

    private fun chartLinks(ctx: Context) {
        val p = ctx.getSharedPreferences("chartlinks.v1", Context.MODE_PRIVATE)
        for ((k, v) in p.all) {
            when (v) {
                is String -> Store.setText(Store.Group.CHARTLINKS, k, v)
                is Boolean -> Store.setFlag(Store.Group.CHARTLINKS, k, v)
            }
        }
    }

    /**
     * The sets a mariner had before there was a set list.
     *
     * With NO list, the library they last opened becomes their set: without it
     * their charts are simply gone at the next launch, with the folder still on
     * disk and the app showing the first-run page.
     *
     * With a list, only the raster charts they added by hand join it, and only
     * once. There is one list, so a picture is a set like any other.
     *
     * The paths are not filtered. A scan decides what is a chart, so an entry
     * that was never a chart library, or has since been deleted, drops out on
     * its own the first time the list is built.
     */
    private fun seedChartSets(ctx: Context) {
        val group = Store.Group.CHARTSETS
        val migrated = "raster_migrated"
        val folders = legacyRasterFolders(ctx)
        if (Store.has(group, "paths")) {
            val saved = Store.list(group, "paths")
            val missing = folders.filter { it !in saved }
            if (missing.isEmpty() || Store.flag(group, migrated)) return
            Store.setFlag(group, migrated, true)
            Store.setList(group, "paths", saved + missing)
            return
        }
        val library = ctx.getSharedPreferences("charts.v1", Context.MODE_PRIVATE)
            .getString("library", null)
        val legacy = listOfNotNull(library) + folders
        Store.setFlag(group, migrated, true)
        if (legacy.isNotEmpty()) Store.setList(group, "paths", legacy)
    }

    /** The folders the raster charts a mariner added by hand live in. */
    private fun legacyRasterFolders(ctx: Context): List<String> {
        val p = ctx.getSharedPreferences("rastercharts.v1", Context.MODE_PRIVATE)
        val ordered = p.getString("paths.ordered", null)
            ?.split("\n")?.filter { it.isNotEmpty() }
        val paths = ordered ?: p.getStringSet("paths", null)?.toList().orEmpty()
        val prepared = java.io.File(
            ctx.getExternalFilesDir(null) ?: ctx.filesDir, "Rasters",
        ).absolutePath
        return paths
            .map { java.io.File(it) }
            .filter { it.exists() }
            // What this app prepared already belongs to the set it was made
            // from, and each sits in a directory of its own name: a folder of
            // 900 sheets would otherwise arrive as 900 sets.
            .mapNotNull { it.parent }
            .filterNot { it.startsWith(prepared) }
            .distinct()
    }
}
