package org.beetlebug.lookout

import android.util.Log
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * The shell's whole part in charts by link: fetch the bytes at a url.
 *
 * Probing the link, inlining TileJSON sources, generating a wrapper style for
 * bare tiles, fetching sprite packs, building the credit line, templating tile
 * urls and keeping the list are all lookout's. See lookout_set_http_provider
 * in lookout.h.
 *
 * THE JNI LAYER STAYS DOWNCALL-ONLY. The core raises its asks on the render
 * thread with the api lock held, so they park in a ring here instead of
 * upcalling into the JVM: one thread drains the ring, a small pool fetches, and
 * every ask is ANSWERED, because an id that is neither answered nor cancelled
 * holds one of the core's outstanding-request slots.
 */
class ChartLinkFetch {
    @Volatile private var live = false

    /**
     * Serializes httpRespond against stop(). A fetch that has passed the live
     * check must finish its JNI call before stop() returns, so the engine
     * handle cannot be freed while an answer is still in flight. The network
     * read happens before the lock is taken, so stop() waits milliseconds at
     * most.
     */
    private val respondLock = Any()
    private var engine: Lookout? = null
    private var pool: ExecutorService? = null
    private var poller: Thread? = null

    /**
     * Wakes the frame loop. An answer is adopted at the top of a frame, and the
     * loop stands down when nothing is moving, so a resolve landing with no
     * gesture behind it needs someone to ask for the next frame.
     */
    @Volatile private var wake: (() -> Unit)? = null

    /** In-flight connections by request id, so a cancel can reach one. */
    private val inFlight = ConcurrentHashMap<Long, HttpURLConnection>()

    @Synchronized
    fun start(l: Lookout, wake: () -> Unit) {
        if (live && engine === l) return
        stop()
        engine = l
        this.wake = wake
        live = true
        l.httpProvider(true)
        // A level change asks tens of tiles across several hosts; six workers
        // keep the tail short. No per-host throttle: a couple of slow or dead
        // requests to one host must not hold a lane and starve the rest.
        pool = Executors.newFixedThreadPool(6)
        poller = Thread({
            val ids = LongArray(16)
            val allow = IntArray(16)
            val urls = arrayOfNulls<String>(16)
            val cancelled = LongArray(64)
            while (live) {
                val c = l.httpCancelPoll(cancelled)
                for (i in 0 until c) inFlight.remove(cancelled[i])?.disconnect()
                val n = l.httpPoll(ids, allow, urls)
                if (n == 0 && c == 0) {
                    try { Thread.sleep(POLL_MS) } catch (_: InterruptedException) { break }
                    continue
                }
                for (i in 0 until n) {
                    val id = ids[i]
                    val url = urls[i] ?: ""
                    val allowFile = allow[i] != 0
                    pool?.execute { fetch(l, id, url, allowFile) }
                }
            }
        }, "lookout-chart-links").also { it.start() }
    }

    @Synchronized
    fun stop() {
        val l = engine
        live = false
        poller?.let { p -> p.interrupt(); try { p.join(1_000) } catch (_: InterruptedException) {} }
        poller = null
        pool?.shutdownNow()
        pool = null
        for ((_, conn) in inFlight) conn.disconnect()
        inFlight.clear()
        // After this point no new respond can start, because live is read under
        // the lock, and none is mid-call, because taking the lock waits for the
        // last one to finish.
        synchronized(respondLock) {}
        l?.httpProvider(false)
        engine = null
        wake = null
    }

    /** Every answer funnels through here; see respondLock. */
    private fun respond(l: Lookout, id: Long, bytes: ByteArray?, status: Int) {
        synchronized(respondLock) {
            if (!live) return
            l.httpRespond(id, bytes, status)
        }
        wake?.invoke()
    }

    private fun fetch(l: Lookout, id: Long, url: String, allowFile: Boolean) {
        // The file:// boundary. lookout says when a url may be read off disk
        // (see lookout_http_get): the link the mariner typed, and what a
        // document already read from disk names inside that link's directory. A
        // style that arrived over the network never gets it, so it cannot make
        // this read arbitrary local files as its "TileJSON".
        val path = localPath(url)
        if (path != null) {
            if (!allowFile) {
                respond(l, id, null, 0)
                return
            }
            val bytes = try { File(path).readBytes() } catch (e: Exception) {
                Log.w(TAG, "chart link $url: $e")
                respond(l, id, null, 0)
                return
            }
            respond(l, id, bytes, 200)
            return
        }
        var conn: HttpURLConnection? = null
        try {
            conn = URL(url).openConnection() as HttpURLConnection
            conn.setRequestProperty("User-Agent", USER_AGENT)
            conn.setRequestProperty("Referer", REFERER)
            // Short timeouts: the chart is drawn from whatever HAS landed, and
            // a style that asks a base map past the zoom it actually serves
            // must fail fast rather than hold a worker.
            conn.connectTimeout = 8_000
            conn.readTimeout = 8_000
            inFlight[id] = conn
            val code = conn.responseCode
            val body = if (code in 200..299) {
                conn.inputStream.use { it.readBytes() }
            } else {
                null
            }
            respond(l, id, body, code)
        } catch (e: Exception) {
            respond(l, id, null, 0)
        } finally {
            inFlight.remove(id)
            conn?.disconnect()
        }
    }

    /** The path a local url names, or null when it names a host. */
    private fun localPath(url: String): String? = when {
        url.startsWith("file://") -> url.removePrefix("file://")
        url.startsWith("/") -> url
        else -> null
    }

    companion object {
        private const val TAG = "lookout"

        /** How long the poller waits on an empty ring. Fast enough that a
         *  resolve does not feel stepped through, cheap enough to leave
         *  running while a link is up. */
        private const val POLL_MS = 16L

        /**
         * Say who is asking, on every chart-link request. Public tile hosts
         * serve "access blocked" placeholder tiles to anonymous or
         * platform-default agents — openstreetmap.org's tile usage policy
         * (osm.wiki/Blocked_tiles) wants a unique, identifiable User-Agent
         * with a way to reach the developer, and the Referer names the app's
         * home for hosts that key on it.
         */
        const val USER_AGENT =
            "LookoutMarine/1.0 (Android; org.beetlebug.lookout; contact jeremy.collins@beetlebug.org)"
        const val REFERER = "https://beetlebug.org/"
    }
}
