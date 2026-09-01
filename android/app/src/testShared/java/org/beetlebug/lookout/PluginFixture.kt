package org.beetlebug.lookout

import org.beetlebug.lookout.plugins.PluginCapability
import org.beetlebug.lookout.plugins.PluginDiscover
import org.beetlebug.lookout.plugins.PluginField
import org.beetlebug.lookout.plugins.PluginInfo
import org.beetlebug.lookout.plugins.PluginListSchema
import org.beetlebug.lookout.plugins.PluginRow
import org.beetlebug.lookout.plugins.PluginStatusItem

/**
 * The shipped plugin set, as values.
 *
 * The core hands the registry over as structs, so a JVM test has no core to
 * read one from. These are the same five plugins the captured registry was
 * taken from, built directly. What the CORE puts in a read is checked in Zig,
 * over the shipped manifests; what the SHELL does with one is checked here.
 *
 * The macOS counterpart is PluginFixture.swift, built from the same set.
 */
object PluginFixture {

    // ---- builders -----------------------------------------------------------

    fun number(
        key: String,
        label: String,
        unit: String = "",
        group: String = "",
        tab: String,
        min: Double,
        max: Double,
        value: Double,
        default: Double = value,
        desc: String = "",
    ) = PluginField(
        key = key, label = label, desc = desc, kind = PluginField.Kind.NUMBER,
        unit = unit, group = group, tab = tab, min = min, max = max,
        defaultValue = default, defaultText = "", optional = false, value = value,
    )

    fun toggle(
        key: String,
        label: String,
        group: String = "",
        tab: String,
        on: Boolean,
        default: Boolean = on,
        desc: String = "",
    ) = PluginField(
        key = key, label = label, desc = desc, kind = PluginField.Kind.TOGGLE,
        unit = "", group = group, tab = tab, min = 0.0, max = 0.0,
        defaultValue = if (default) 1.0 else 0.0, defaultText = "", optional = false,
        value = if (on) 1.0 else 0.0,
    )

    fun text(
        key: String,
        label: String,
        optional: Boolean = false,
        default: String = "",
        desc: String = "",
    ) = PluginField(
        key = key, label = label, desc = desc, kind = PluginField.Kind.TEXT,
        unit = "", group = "", tab = "connections", min = 0.0, max = 0.0,
        defaultValue = 0.0, defaultText = default, optional = optional, value = 0.0,
    )

    fun list(
        pluginId: String,
        key: String,
        group: String,
        tab: String = "connections",
        fields: List<PluginField>,
        footer: String = "",
        empty: String = "",
        addLabel: String,
        switchKey: String = "enabled",
        services: List<String> = emptyList(),
        discover: List<PluginDiscover> = services.map { PluginDiscover(it, emptyMap()) },
        maxRows: Int = 8,
    ) = PluginListSchema(
        pluginId = pluginId, key = key, group = group, tab = tab,
        itemFields = fields, footer = footer, empty = empty, addLabel = addLabel,
        switchKey = switchKey, discover = discover, maxRows = maxRows,
    )

    fun row(id: String, cells: Map<String, String>) = PluginRow(id, cells)

    fun cap(name: String, sentence: String, hosts: List<String> = emptyList(), granted: Boolean = true) =
        PluginCapability(cap = name, sentence = sentence, hosts = hosts, granted = granted)

    fun plugin(
        id: String,
        name: String,
        status: String = "",
        origin: String = "bundled",
        capabilities: List<PluginCapability> = emptyList(),
        fields: List<PluginField> = emptyList(),
        lists: List<PluginListSchema> = emptyList(),
        rows: Map<String, List<PluginRow>> = emptyMap(),
    ) = PluginInfo(
        id = id, name = name, version = "", origin = origin, status = status,
        capabilities = capabilities, fields = fields, lists = lists, rows = rows,
        statusItems = statusItemsOf(status),
    )

    /** The same decode PluginRegistry does on a status the plugin wrote. */
    private fun statusItemsOf(status: String): Map<String, PluginStatusItem> {
        if (!status.startsWith("{")) return emptyMap()
        return try {
            val items = org.json.JSONObject(status).optJSONArray("items") ?: return emptyMap()
            (0 until items.length()).mapNotNull { k ->
                val o = items.optJSONObject(k) ?: return@mapNotNull null
                val id = o.optString("id").ifEmpty { return@mapNotNull null }
                id to PluginStatusItem(id, o.optString("state"), o.optString("detail"))
            }.toMap()
        } catch (e: Exception) {
            emptyMap()
        }
    }

    // ---- the set ------------------------------------------------------------
    //
    // Three bundled plugins, one installed and one developer override. The
    // bundled three are the shipped manifests; the other two are invented,
    // because the shipped set has no installed or developer copy to read.

    val nmeaConnections = list(
        "org.beetlebug.nmea0183", "connections", group = "Connections",
        fields = listOf(
            text("name", "Name", optional = true,
                desc = "What you call this source. Leave it empty to show the address."),
            text("host", "Address",
                desc = "The name or IP address of the instrument network's gateway."),
            number("port", "Port", tab = "connections", min = 1.0, max = 65535.0, value = 10110.0,
                desc = "Most WiFi gateways serve NMEA 0183 on port 10110."),
            toggle("enabled", "On", tab = "connections", on = true,
                desc = "Off closes the connection and stops reconnecting."),
        ),
        footer = "Give the address of your instrument network's gateway.",
        empty = "No connections yet.",
        addLabel = "Add Connection",
        services = listOf("_nmea-0183._tcp"),
    )

    val nmea0183 = plugin(
        "org.beetlebug.nmea0183", "NMEA 0183",
        status = """{"state":"running","detail":"1 of 1 connected","items":[""" +
            """{"id":"row-a1b2c3d4","state":"connected","detail":"44 msg/s"},""" +
            """{"id":"row-deadbeef","state":"unreachable","detail":"no route to host"}]}""",
        capabilities = listOf(
            cap("net.tcp-client", "Connect to devices on your boat's own network.", hosts = listOf("local")),
            cap("vessel.publish", "Report your boat's position, course and speed."),
            cap("ais.publish", "Report other vessels it hears."),
            cap("bus.publish", "Hand raw sentences to other plugins.",
                hosts = listOf("nmea0183"), granted = false),
        ),
        lists = listOf(nmeaConnections),
        rows = mapOf("connections" to listOf(
            row("row-a1b2c3d4", mapOf(
                "name" to "Masthead", "host" to "192.168.1.50",
                "port" to "10110", "enabled" to "true",
            )),
            row("row-deadbeef", mapOf(
                "name" to "", "host" to "nav.local",
                "port" to "10111", "enabled" to "false",
            )),
        )),
    )

    val signalkServers = list(
        "org.beetlebug.signalk", "servers", group = "Signal K servers",
        fields = listOf(
            text("name", "Name", optional = true,
                desc = "What you call this server. Leave it empty to show the address."),
            text("host", "Address", desc = "The name or IP address of the Signal K server."),
            number("port", "Port", tab = "connections", min = 1.0, max = 65535.0, value = 8375.0,
                desc = "Most Signal K servers stream on port 8375."),
            toggle("websocket", "WebSocket", tab = "connections", on = false,
                desc = "Read the WebSocket stream instead of the plain one."),
            toggle("enabled", "On", tab = "connections", on = true,
                desc = "Off closes the stream and stops reconnecting."),
        ),
        footer = "A Signal K server sends the whole boat as one stream of updates on port 8375.",
        empty = "No servers yet.",
        addLabel = "Add Server",
        discover = listOf(PluginDiscover("_signalk-ws._tcp", mapOf("websocket" to "true"))),
    )

    val signalk = plugin(
        "org.beetlebug.signalk", "Signal K",
        status = """{"state":"running","detail":"","items":[""" +
            """{"id":"row-5f5f5f5f","state":"reconnecting","detail":"retry in 4 s"}]}""",
        capabilities = listOf(
            cap("net.tcp-client", "Connect to devices on your boat's own network.", hosts = listOf("local")),
            cap("net.ws", "Open a WebSocket to your boat's own network.", hosts = listOf("local")),
        ),
        lists = listOf(signalkServers),
        rows = mapOf("servers" to listOf(
            row("row-5f5f5f5f", mapOf(
                "name" to "", "host" to "signalk.local", "port" to "3000",
                "websocket" to "true", "enabled" to "true",
            )),
        )),
    )

    val ais = plugin(
        "org.beetlebug.ais", "AIS targets",
        status = "Tracking 14 targets",
        capabilities = listOf(
            cap("ais.read", "Read the vessels other plugins report."),
            cap("overlay.draw", "Draw on the chart."),
            cap("alerts.raise", "Raise alarms and warnings."),
        ),
        fields = listOf(
            number("cpa_limit", "Closest approach (CPA)", unit = "m", group = "Collision alarm",
                tab = "alarms", min = 93.0, max = 9260.0, value = 926.0),
            number("tcpa_limit", "Time to closest approach (TCPA)", unit = "min",
                group = "Collision alarm", tab = "alarms", min = 1.0, max = 60.0, value = 10.0),
            toggle("cpa_alarm", "Collision alarm", group = "Collision alarm", tab = "alarms", on = true),
            number("vector_min", "Course vectors", unit = "min", group = "AIS targets",
                tab = "vessels", min = 1.0, max = 24.0, value = 6.0),
            // The value in force differs from the default, which is what tells
            // the two apart in a test.
            number("min_sog", "Hide targets under", unit = "kn", group = "AIS targets",
                tab = "vessels", min = 0.0, max = 5.0, value = 0.5, default = 0.0),
        ),
    )

    val grib = plugin(
        "org.example.grib", "GRIB weather", origin = "installed",
        status = """{"state":"degraded","detail":"no file loaded"}""",
        capabilities = listOf(
            cap("net.http", "Fetch forecasts from the internet.",
                hosts = listOf("nomads.ncep.noaa.gov"), granted = false),
            cap("overlay.draw", "Draw on the chart."),
        ),
        fields = listOf(
            number("opacity", "Overlay opacity", unit = "%", tab = "advanced",
                min = 10.0, max = 100.0, value = 60.0),
        ),
    )

    val routes = plugin(
        "org.example.routes", "Routes", origin = "developer",
        status = """{"state":"stopped","detail":"module trapped"}""",
        fields = listOf(
            toggle("show_legs", "Show leg distances", tab = "advanced", on = false, default = true),
        ),
    )

    /** The five plugins, in load order. */
    val shipped: List<PluginInfo> = listOf(nmea0183, signalk, ais, grib, routes)
}
