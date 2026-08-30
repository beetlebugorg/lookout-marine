package org.beetlebug.lookout

import org.beetlebug.lookout.plugins.newRow
import org.beetlebug.lookout.plugins.rowFrom
import org.beetlebug.lookout.plugins.rowsJson

import org.beetlebug.lookout.plugins.DiscoveredService
import org.beetlebug.lookout.plugins.PluginListSchema
import org.beetlebug.lookout.plugins.PluginRegistry
import org.beetlebug.lookout.plugins.PluginRow
import org.beetlebug.lookout.plugins.trimmed

import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Writing a connection list back to the core.
 *
 * A list is replaced WHOLE on every edit — that is the core's contract, see
 * `normalizeRows` in src/plugin/host.zig — so an add, a remove, a committed
 * keystroke and a flipped switch all send the entire array. What the core does
 * with a cell depends on its JSON type, so the shell has to type each one back
 * from the schema on the way out: it holds every cell as text while it is being
 * edited, because a row editor binds them to text controls.
 */
@RunWith(RobolectricTestRunner::class)
class PluginListWriteTest {

    private val registry = PluginRegistry.parse(Fixtures.registry)
    private val nmea = registry.lists("connections").first { it.key == "connections" }
    private val signalk = registry.lists("connections").first { it.key == "servers" }

    private fun written(schema: PluginListSchema, rows: List<PluginRow>) =
        JSONArray(schema.rowsJson(rows))

    // ---- a fresh row --------------------------------------------------------

    @Test fun aFreshRowStartsOnTheSchemasOwnDefaults() {
        val row = nmea.newRow()
        assertEquals("", row.text("name"))
        assertEquals("", row.text("host"))
        assertEquals("10110", row.text("port"))
        assertTrue("the switch column defaults on", row.on("enabled"))
    }

    /**
     * The id is minted here and never changes: it is what ties "connected,
     * 44 msg/s" to the line the mariner is looking at. The host keeps 32 bytes
     * of it and it only has to be distinct within one plugin's list.
     */
    @Test fun aFreshRowCarriesAShortUniqueId() {
        val a = nmea.newRow()
        val b = nmea.newRow()
        assertTrue(a.id.startsWith("row-"))
        assertTrue("the id must fit the host's 32 bytes", a.id.length <= 32)
        assertNotEquals(a.id, b.id)
    }

    @Test fun aFreshSignalKRowTakesItsOwnDefaults() {
        val row = signalk.newRow()
        assertEquals("8375", row.text("port"))
        assertTrue(row.on("enabled"))
        assertTrue("WebSocket is off by default", !row.on("websocket"))
    }

    // ---- a row filled in from the network -----------------------------------

    @Test fun aDiscoveredRowTakesTheAddressNameAndPortThatAnswered() {
        val found = DiscoveredService("_nmea-0183._tcp", "Masthead", "192.168.1.50", 10110)
        val row = nmea.rowFrom(found)
        assertEquals("192.168.1.50", row.text("host"))
        assertEquals("10110", row.text("port"))
        assertEquals("Masthead", row.text("name"))
        assertTrue(row.on("enabled"))
    }

    /** A Signal K find arrives with the column its service type implies. */
    @Test fun aDiscoveredRowTakesTheColumnsItsServiceSets() {
        val found = DiscoveredService("_signalk-ws._tcp", "boat", "10.0.0.4", 3000)
        val row = signalk.rowFrom(found)
        assertTrue("the service says this is the WebSocket stream", row.on("websocket"))
        assertEquals("10.0.0.4", row.text("host"))
        assertEquals("3000", row.text("port"))
    }

    /** A `set` naming a column the schema does not declare is ignored rather
     *  than written into a cell nothing will read. */
    @Test fun aSetForAnUndeclaredColumnIsIgnored() {
        val schema = PluginRegistry.parse(
            """{"plugins":[{"id":"x","lists":[{"key":"k","tab":"connections",
               "discover":[{"service":"_s._tcp","set":{"nosuch":true}}],
               "item_fields":[{"key":"host","label":"H","kind":"text","default":""}]}]}]}"""
        ).lists("connections").single()
        val row = schema.rowFrom(DiscoveredService("_s._tcp", "n", "h", 1))
        assertTrue("nosuch" !in row.cells)
    }

    // ---- what crosses to the core -------------------------------------------

    @Test fun everyDeclaredColumnIsWrittenWithTheRowId() {
        val rows = registry.rows(nmea)
        val out = written(nmea, rows)
        assertEquals(2, out.length())
        val first = out.getJSONObject(0)
        assertEquals("row-a1b2c3d4", first.getString("id"))
        assertEquals("Masthead", first.getString("name"))
        assertEquals("192.168.1.50", first.getString("host"))
        assertEquals(10110, first.getInt("port"))
        assertEquals(true, first.getBoolean("enabled"))
    }

    /**
     * A port goes over as an integer. Written as a double it reads "10110.0" in
     * a log, and a mariner reading a log is the reason the log is legible.
     */
    @Test fun aWholeNumberCrossesAsAnInteger() {
        val row = nmea.newRow().copy(cells = nmea.newRow().cells + ("port" to "10110"))
        val out = written(nmea, listOf(row)).getJSONObject(0)
        assertEquals("10110", out.get("port").toString())
    }

    @Test fun aFractionalNumberKeepsItsFraction() {
        val schema = PluginRegistry.parse(
            """{"plugins":[{"id":"x","lists":[{"key":"k","tab":"connections","item_fields":[
               {"key":"gain","label":"G","kind":"number","min":0,"max":10,"default":1}]}]}]}"""
        ).lists("connections").single()
        val row = PluginRow("r", mapOf("gain" to "2.5"))
        assertEquals(2.5, written(schema, listOf(row)).getJSONObject(0).getDouble("gain"), 0.0)
    }

    /**
     * A cell the row does not carry falls back to the schema's default rather
     * than being left out: the core would default it anyway, and sending it
     * keeps what was written and what is in force the same shape.
     */
    @Test fun aMissingCellIsSentAsTheSchemaDefault() {
        val bare = PluginRow("row-bare", emptyMap())
        val out = written(nmea, listOf(bare)).getJSONObject(0)
        assertEquals("row-bare", out.getString("id"))
        assertEquals("", out.getString("host"))
        assertEquals(10110, out.getInt("port"))
        assertEquals(true, out.getBoolean("enabled"))
    }

    /** A number cell the mariner typed nonsense into falls back rather than
     *  crossing as NaN. */
    @Test fun anUnparseableNumberFallsBackToTheDefault() {
        val row = PluginRow("r", mapOf("port" to "ten thousand"))
        assertEquals(10110, written(nmea, listOf(row)).getJSONObject(0).getInt("port"))
    }

    /** The core writes JSON booleans; the shell holds them as text and takes
     *  "1" as well, because an older store wrote it that way. */
    @Test fun aToggleCellIsReadFromEitherSpelling() {
        val yes = PluginRow("r", mapOf("enabled" to "true"))
        val one = PluginRow("r", mapOf("enabled" to "1"))
        val no = PluginRow("r", mapOf("enabled" to "false"))
        assertEquals(true, written(nmea, listOf(yes)).getJSONObject(0).getBoolean("enabled"))
        assertEquals(true, written(nmea, listOf(one)).getJSONObject(0).getBoolean("enabled"))
        assertEquals(false, written(nmea, listOf(no)).getJSONObject(0).getBoolean("enabled"))
    }

    /** Removing the last row sends an empty array, which is how a list is
     *  emptied. It must not send nothing at all. */
    @Test fun anEmptyListIsWrittenAsAnEmptyArray() {
        assertEquals("[]", nmea.rowsJson(emptyList()))
    }

    /** The order the mariner sees is the order the core is given. */
    @Test fun theRowOrderIsPreserved() {
        val rows = registry.rows(nmea).reversed()
        val out = written(nmea, rows)
        assertEquals("row-deadbeef", out.getJSONObject(0).getString("id"))
        assertEquals("row-a1b2c3d4", out.getJSONObject(1).getString("id"))
    }

    /** A number with no fraction reads back without a trailing ".0" when it is
     *  seeded into a text control. */
    @Test fun aDefaultSeededIntoATextControlHasNoTrailingZero() {
        assertEquals("10110", trimmed(10110.0))
        assertEquals("0", trimmed(0.0))
        assertEquals("2.5", trimmed(2.5))
    }
}
