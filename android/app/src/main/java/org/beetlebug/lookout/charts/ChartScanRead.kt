package org.beetlebug.lookout.charts

import org.beetlebug.lookout.Lookout

/**
 * What a folder or one .zip holds, as the core reports it.
 *
 * The CORE does the looking (lookout_scan_read). It walks the folder, names
 * each dataset, decides what each file is and what it would take to draw it.
 * Nothing here decides any of that.
 */
data class ChartScanRead(
    /** Where the scan started. */
    val root: String,
    /** S-57 update files. Each one bakes with its base cell. */
    val updates: Int,
    /** Files that are not charts. */
    val other: Int,
    /** Files carrying a chart name that the engine refused. */
    val refused: Int,
    /** How many cells bake before they draw. */
    val sources: Int,
    /** The bytes of every cell. */
    val bytes: Long,
    /** The agency every chart here came from, empty when they disagree. */
    val producer: String,
    /** The baked archives and the source cells, then the picture charts. */
    val files: List<ChartFile>,
) {
    data class ChartFile(
        /** The absolute path, or the entry name inside an archive. */
        val path: String,
        /** The eight character dataset name, such as US5MD1MC. */
        val name: String,
        val kind: Int,
        /** 1 to 6, or 0 when the name has no usage band. */
        val band: Int,
        /** The band in the words the readouts use. */
        val bandName: String,
        val bytes: Long,
        /** 0 when the archive states none. */
        val scale: Double,
        /** The four edges, when the archive states its coverage. */
        val west: Double?,
        val south: Double?,
        val east: Double?,
        val north: Double?,
    )

    companion object {
        // lookout_file_kind
        const val BAKED = 0
        const val SOURCE = 1
        const val UPDATE = 2
        const val RASTER = 3
        const val RASTER_SOURCE = 4
        const val OTHER = 5

        fun read(path: String, zip: Boolean): ChartScanRead? = decode(Lookout.scanRead(path, zip))

        /**
         * The flat read: the summary, the counts, then twelve strings per
         * file. `internal` so the suite drives the same walk with no core.
         */
        internal fun decode(flat: Array<String>?): ChartScanRead? {
            if (flat == null || flat.size < HEADER) return null
            val cellCount = flat[7].toIntOrNull() ?: 0
            val rasterCount = flat[8].toIntOrNull() ?: 0
            val files = decodeFiles(flat, HEADER, cellCount + rasterCount)
            return ChartScanRead(
                root = flat[0],
                updates = flat[1].toIntOrNull() ?: 0,
                other = flat[2].toIntOrNull() ?: 0,
                refused = flat[3].toIntOrNull() ?: 0,
                sources = flat[4].toIntOrNull() ?: 0,
                bytes = flat[5].toLongOrNull() ?: 0L,
                producer = flat[6],
                files = files,
            )
        }

        /**
         * A run of files, twelve strings each. The set list hands back the same
         * shape, so both reads walk it here.
         */
        internal fun decodeFiles(
            flat: Array<String>?,
            from: Int = 0,
            limit: Int = Int.MAX_VALUE,
        ): List<ChartFile> {
            if (flat == null) return emptyList()
            val out = ArrayList<ChartFile>()
            var k = from
            while (k + FIELDS <= flat.size && out.size < limit) {
                val located = flat[k + 7] != "0"
                out.add(
                    ChartFile(
                        path = flat[k],
                        name = flat[k + 1],
                        kind = flat[k + 2].toIntOrNull() ?: OTHER,
                        band = flat[k + 3].toIntOrNull() ?: 0,
                        bandName = flat[k + 4],
                        bytes = flat[k + 5].toLongOrNull() ?: 0L,
                        scale = flat[k + 6].toDoubleOrNull() ?: 0.0,
                        west = if (located) flat[k + 8].toDoubleOrNull() else null,
                        south = if (located) flat[k + 9].toDoubleOrNull() else null,
                        east = if (located) flat[k + 10].toDoubleOrNull() else null,
                        north = if (located) flat[k + 11].toDoubleOrNull() else null,
                    ),
                )
                k += FIELDS
            }
            return out
        }

        private const val HEADER = 9
        private const val FIELDS = 12
    }
}
