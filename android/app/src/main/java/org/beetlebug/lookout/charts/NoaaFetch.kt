package org.beetlebug.lookout.charts

import org.beetlebug.lookout.Lookout

import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/**
 * The NOAA service's fetcher: fetch the bytes at each url the core hands over.
 *
 * One thread blocks in [Lookout.noaaFetchWait] until the core parks a request
 * or a cancel, or wakes after queueing a response. A small pool streams each
 * body back a piece at a time. An idle service leaves the thread blocked, so
 * this runs no timer.
 */
class NoaaFetch(private val noaa: Long, private val wake: () -> Unit) {
    @Volatile private var live = false

    /** Held by each response and by [stop], as in ChartLinkFetch. */
    private val respondLock = Any()
    private var pool: ExecutorService? = null
    private var waiter: Thread? = null
    private val inFlight = ConcurrentHashMap<Long, HttpURLConnection>()

    @Synchronized
    fun start() {
        if (live) return
        live = true
        Lookout.noaaFetch(noaa, true)
        val p = Executors.newFixedThreadPool(TRANSFERS)
        pool = p
        waiter = Thread({
            val ids = LongArray(16)
            val allow = IntArray(16)
            val urls = arrayOfNulls<String>(16)
            val cancelled = LongArray(64)
            val counts = IntArray(2)
            while (true) {
                val r = Lookout.noaaFetchWait(ids, allow, urls, cancelled, counts)
                if (r == STOPPED) break
                for (i in 0 until counts[1]) inFlight.remove(cancelled[i])?.disconnect()
                for (i in 0 until counts[0]) {
                    val id = ids[i]
                    val url = urls[i] ?: ""
                    try {
                        p.execute { fetch(id, url) }
                    } catch (_: RejectedExecutionException) {
                        respond(id, null, 0, 0, true)
                    }
                }
                if (r == WOKEN) wake()
            }
        }, "lookout-noaa-fetch").also { it.start() }
    }

    @Synchronized
    fun stop() {
        if (!live) return
        live = false
        Lookout.noaaFetch(noaa, false)
        waiter?.let { w -> try { w.join(1_000) } catch (_: InterruptedException) {} }
        waiter = null
        pool?.shutdownNow()
        pool = null
        for ((_, conn) in inFlight) conn.disconnect()
        inFlight.clear()
        synchronized(respondLock) {}
    }

    /** False once the fetcher has stood down, and the read stops there. */
    private fun respond(id: Long, buf: ByteArray?, len: Int, status: Int, done: Boolean): Boolean {
        synchronized(respondLock) {
            if (!live) return false
            Lookout.noaaRespondChunk(noaa, id, buf, len, status, done)
        }
        return true
    }

    private fun fetch(id: Long, url: String) {
        var conn: HttpURLConnection? = null
        try {
            conn = URL(url).openConnection() as HttpURLConnection
            conn.setRequestProperty("User-Agent", ChartLinkFetch.USER_AGENT)
            conn.setRequestProperty("Referer", ChartLinkFetch.REFERER)
            conn.connectTimeout = TIMEOUT_MS
            conn.readTimeout = TIMEOUT_MS
            inFlight[id] = conn
            val code = conn.responseCode
            if (code !in 200..299) {
                respond(id, null, 0, code, true)
                return
            }
            // A district is one zip of a couple of hundred megabytes, so the
            // body goes back in pieces rather than as one ByteArray.
            val buf = ByteArray(READ_CHUNK)
            conn.inputStream.use { input ->
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    if (n == 0) continue
                    if (!respond(id, buf, n, code, false)) return
                }
            }
            respond(id, null, 0, code, true)
        } catch (e: Exception) {
            respond(id, null, 0, 0, true)
        } finally {
            inFlight.remove(id)
            conn?.disconnect()
        }
    }

    private companion object {
        /** The core keeps four transfers out at once. */
        const val TRANSFERS = 4
        const val READ_CHUNK = 256 * 1024
        const val TIMEOUT_MS = 8_000
        const val WOKEN = 1
        const val STOPPED = 2
    }
}
