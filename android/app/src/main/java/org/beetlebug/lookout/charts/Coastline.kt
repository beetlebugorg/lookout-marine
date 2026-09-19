package org.beetlebug.lookout.charts

import android.content.Context
import android.util.Log
import java.io.DataInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * The coastline the coverage picker draws.
 *
 * Baked from the GSHHG data the engine's basemap is baked from, clipped to the
 * waters the picker shows and simplified to 0.02 degrees. The same file the
 * Apple shells read, in assets/coastline.bin.
 *
 * The picker draws this rather than photographing the chart. A picture of the
 * chart has to be taken at a view the camera has visited, because tiles load on
 * the frame loop, and it then needs the projection it was taken under carried
 * alongside it. This is a static array and a projection the picker owns, so it
 * draws the same on the first frame every time.
 *
 * Layout, little-endian: a u32 ring count, then per ring a u8 level, a u32
 * point count, and that many pairs of f32 longitude and latitude.
 */
object Coastline {

    /** GSHHG level: land is 1 and a lake is 2. A lake is its own polygon
     *  rather than a hole, so it draws over the land. */
    class Ring(val level: Int, val lon: FloatArray, val lat: FloatArray) {
        val west: Float
        val south: Float
        val east: Float
        val north: Float

        init {
            var w = 180f; var e = -180f; var s = 90f; var n = -90f
            for (i in lon.indices) {
                if (lon[i] < w) w = lon[i]
                if (lon[i] > e) e = lon[i]
                if (lat[i] < s) s = lat[i]
                if (lat[i] > n) n = lat[i]
            }
            west = w; east = e; south = s; north = n
        }

        /** True when the ring reaches into this window.
         *
         *  A ring spanning more than 180 degrees of longitude is one that
         *  crosses the antimeridian, such as an Aleutian island with points at
         *  +172 and -179. Drawn straight through, it spans the map as a band. */
        fun touches(w: Double, s: Double, e: Double, n: Double): Boolean {
            if (east - west > 180f) return false
            return west <= e && east >= w && south <= n && north >= s
        }
    }

    @Volatile private var loaded: List<Ring>? = null

    /** Read once, on first use. An empty list when the asset is missing, which
     *  draws a picker with water and no land rather than no picker. */
    fun rings(context: Context): List<Ring> {
        loaded?.let { return it }
        synchronized(this) {
            loaded?.let { return it }
            val read = load(context)
            loaded = read
            return read
        }
    }

    private fun load(context: Context): List<Ring> {
        return try {
            val bytes = context.assets.open("coastline.bin").use { it.readBytes() }
            val buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            val count = buf.int
            val out = ArrayList<Ring>(count)
            for (r in 0 until count) {
                if (buf.remaining() < 5) break
                val level = buf.get().toInt() and 0xFF
                val n = buf.int
                if (n < 0 || buf.remaining() < n * 8) break
                val lon = FloatArray(n)
                val lat = FloatArray(n)
                for (i in 0 until n) {
                    lon[i] = buf.float
                    lat[i] = buf.float
                }
                out.add(Ring(level, lon, lat))
            }
            out
        } catch (e: Exception) {
            Log.w("Coastline", "coverage map: coastline.bin did not read: $e")
            emptyList()
        }
    }
}
