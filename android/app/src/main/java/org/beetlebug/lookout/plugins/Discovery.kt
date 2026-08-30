package org.beetlebug.lookout.plugins

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.net.Inet4Address

/**
 * What is already answering on the boat's network.
 *
 * A Signal K server announces itself over DNS-SD, and so do some NMEA
 * gateways. A connection list declares the service types it accepts, and this
 * browses for them so a source can be added without anyone typing an address.
 *
 * THE ADDRESS IS KEPT HERE, not the host name, which is the one place this
 * shell differs from the others. [NsdServiceInfo] never exposes the SRV
 * target's name, and bionic's resolver would not resolve a `.local` name if it
 * did: Android expects an app to reach the network through this service. So a
 * row added from a find carries the address the service answered on, and a
 * lease that turns over is fixed by discovering it again.
 */
data class DiscoveredService(
    /** The service type it answered for, which is what ties it to a list. */
    val service: String,
    /** What the server calls itself. It becomes the row's name. */
    val name: String,
    val host: String,
    val port: Int,
) {
    val id: String get() = "$service/$name"
}

class Discovery(context: Context) {
    /** Everything resolved so far, for the composable that shows it. */
    var found by mutableStateOf<List<DiscoveredService>>(emptyList())
        private set

    private val nsd = context.applicationContext.getSystemService(NsdManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private val browsers = mutableMapOf<String, NsdManager.DiscoveryListener>()

    /**
     * Resolves run ONE AT A TIME. A second resolveService while one is in
     * flight answers FAILURE_ALREADY_ACTIVE and the service is lost, so what
     * the browse finds waits here for its turn.
     *
     * Each entry carries the type of the BROWSER that found it. A resolved
     * NsdServiceInfo reports its own service type inconsistently across
     * releases, and reading it back would drop every find whose spelling did
     * not match what was asked for.
     */
    private val waiting = ArrayDeque<Pair<String, NsdServiceInfo>>()
    private var resolving = false

    /** Browse for exactly these service types. Idempotent. */
    fun browse(services: List<String>) {
        val want = services.map(::normalize).toSet()
        for (type in browsers.keys.toList()) {
            if (type in want) continue
            stopBrowser(type)
            found = found.filterNot { it.service == type }
        }
        for (type in want) {
            if (browsers.containsKey(type)) continue
            val listener = browserFor(type)
            browsers[type] = listener
            // NsdManager wants the type with its trailing dot.
            nsd.discoverServices("$type.", NsdManager.PROTOCOL_DNS_SD, listener)
        }
    }

    /** Stop looking, and forget what was found. */
    fun stop() {
        for (type in browsers.keys.toList()) stopBrowser(type)
        waiting.clear()
        found = emptyList()
    }

    private fun stopBrowser(type: String) {
        val listener = browsers.remove(type) ?: return
        // A browser already torn down by the framework throws rather than
        // answering, and there is nothing left to stop in that case.
        runCatching { nsd.stopServiceDiscovery(listener) }
    }

    private fun browserFor(type: String) = object : NsdManager.DiscoveryListener {
        override fun onServiceFound(info: NsdServiceInfo) {
            main.post { enqueue(type, info) }
        }

        override fun onServiceLost(info: NsdServiceInfo) {
            val name = info.serviceName
            main.post { found = found.filterNot { it.service == type && it.name == name } }
        }

        override fun onDiscoveryStarted(serviceType: String) {}
        override fun onDiscoveryStopped(serviceType: String) {}
        override fun onStartDiscoveryFailed(serviceType: String, error: Int) {
            main.post { browsers.remove(type) }
        }

        override fun onStopDiscoveryFailed(serviceType: String, error: Int) {}
    }

    private fun enqueue(type: String, info: NsdServiceInfo) {
        waiting.addLast(type to info)
        resolveNext()
    }

    private fun resolveNext() {
        if (resolving) return
        val (type, next) = waiting.removeFirstOrNull() ?: return
        resolving = true
        @Suppress("DEPRECATION") // registerServiceInfoCallback is API 34; this app runs from 24.
        nsd.resolveService(next, object : NsdManager.ResolveListener {
            override fun onServiceResolved(info: NsdServiceInfo) {
                main.post {
                    resolving = false
                    keep(type, info)
                    resolveNext()
                }
            }

            override fun onResolveFailed(info: NsdServiceInfo, error: Int) {
                main.post {
                    resolving = false
                    resolveNext()
                }
            }
        })
    }

    private fun keep(type: String, info: NsdServiceInfo) {
        // Nothing is browsing for this any more: the pane went away while the
        // resolve was in flight.
        if (!browsers.containsKey(type)) return
        @Suppress("DEPRECATION") // getHostAddresses is API 34; see resolveNext.
        val address = info.host
        // IPv4 only. A link-local IPv6 address carries the interface it was
        // seen on (fe80::1%wlan0), which is not something a row can hold or
        // the core can dial.
        if (address !is Inet4Address) return
        val host = address.hostAddress ?: return
        val entry = DiscoveredService(type, info.serviceName, host, info.port)
        if (entry.port <= 0) return
        // One server answers on every interface it holds. The second answer is
        // the same machine, so it replaces the first.
        found = found.filterNot { it.id == entry.id } + entry
    }

    /** A service type as this compares them: no trailing dot. */
    private fun normalize(type: String): String = type.trimEnd('.')
}
