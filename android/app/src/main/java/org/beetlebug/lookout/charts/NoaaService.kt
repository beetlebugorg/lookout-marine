package org.beetlebug.lookout.charts

import org.beetlebug.lookout.Lookout
import org.beetlebug.lookout.store.Store

/**
 * The NOAA service handle and its fetcher, for the life of the process.
 *
 * It belongs to the app rather than to a chart handle. The engine closes and
 * reopens whenever the chart sets change, and a download running on the
 * service goes on through that.
 */
object NoaaService {
    /** 0 until [open], and 0 when the core could not open one. */
    @Volatile var handle: Long = 0
        private set

    /** Called on the fetcher's thread when the core has queued a response. */
    @Volatile var onWake: (() -> Unit)? = null

    private var fetch: NoaaFetch? = null

    /** Open the service over the store and the chart sets. After both. */
    @Synchronized
    fun open() {
        if (handle != 0L) return
        handle = Lookout.noaaOpen(Store.handle, ChartSets.handle)
        if (handle == 0L) return
        fetch = NoaaFetch(handle) { onWake?.invoke() }.also { it.start() }
    }
}
