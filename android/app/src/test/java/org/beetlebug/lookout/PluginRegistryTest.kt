package org.beetlebug.lookout

import org.beetlebug.lookout.plugins.PluginField
import org.beetlebug.lookout.plugins.PluginRegistry
import org.beetlebug.lookout.plugins.PluginStatusItem

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * The settings registry, as the core states it.
 *
 * The shell renders a whole settings pane from this and knows nothing about
 * what any plugin does, so every derivation here is load-bearing: which section
 * a control lands in, which column of a connection row is the address, which
 * toggle is the row's switch. A plugin author changes a manifest and expects the
 * pane to follow with no shell change, which only holds if these hold.
 */
@RunWith(RobolectricTestRunner::class)
class PluginRegistryTest {

    private val reg = PluginRegistry.parse(Fixtures.registry)

    private fun plugin(id: String) =
        reg.plugins.first { it.id == id }

    // ---- the plugins --------------------------------------------------------

    @Test fun everyPluginIsRead() {
        assertEquals(
            listOf(
                "org.beetlebug.nmea0183",
                "org.beetlebug.signalk",
                "org.beetlebug.ais",
                "org.example.grib",
                "org.example.routes",
            ),
            reg.plugins.map { it.id },
        )
    }

    /**
     * The management section lists what the mariner installed and any developer
     * override, never the bundled set: those ids belong to the application and
     * cannot be uninstalled.
     */
    @Test fun onlyTheNonBundledPluginsAreManaged() {
        assertEquals(listOf("org.example.grib", "org.example.routes"), reg.managed.map { it.id })
        assertTrue(plugin("org.beetlebug.ais").bundled)
        assertFalse(plugin("org.example.grib").bundled)
    }

    @Test fun aPluginWithNoOriginIsTreatedAsBundled() {
        val one = PluginRegistry.parse("""{"plugins":[{"id":"x","name":"X"}]}""").plugins.single()
        assertEquals("bundled", one.origin)
        assertTrue(one.bundled)
    }

    // ---- the sections -------------------------------------------------------

    /**
     * The core sections are always listed; the rest appear only while a schema
     * fills them, so a build whose AIS plugin never came up shows no empty
     * Vessels section. The order is the product's, shared with every shell.
     */
    @Test fun theSectionsAreTheCoreOnesPlusWhateverIsFilled() {
        assertEquals(
            listOf("display", "depths", "text", "charts", "vessels", "alarms",
                   "connections", "plugins", "advanced"),
            reg.sections.map { it.id },
        )
    }

    @Test fun anEmptyRegistryStillListsTheCoreSections() {
        assertEquals(
            listOf("display", "depths", "text", "charts", "plugins", "advanced"),
            PluginRegistry().sections.map { it.id },
        )
    }

    @Test fun theFilledSectionsComeFromBothFieldsAndLists() {
        assertEquals(setOf("alarms", "vessels", "advanced", "connections"), reg.populatedTabs)
    }

    // ---- the field groups ---------------------------------------------------

    /** A plugin's fields for one section, under the heading its manifest gave
     *  them, in the order the manifest declared them. */
    @Test fun fieldsGatherUnderTheirHeadingInDeclarationOrder() {
        val groups = reg.groups("alarms")
        assertEquals(1, groups.size)
        assertEquals("Collision alarm", groups[0].title)
        assertEquals("org.beetlebug.ais", groups[0].pluginId)
        assertEquals(listOf("cpa_limit", "tcpa_limit", "cpa_alarm"), groups[0].fields.map { it.key })
    }

    @Test fun eachHeadingIsItsOwnGroup() {
        val groups = reg.groups("vessels")
        assertEquals(1, groups.size)
        assertEquals("AIS targets", groups[0].title)
        assertEquals(listOf("vector_min", "min_sog"), groups[0].fields.map { it.key })
    }

    /** A field whose manifest names no heading falls under the plugin's name,
     *  so it is never orphaned under a blank title. */
    @Test fun aGrouplessFieldTakesThePluginsName() {
        val groups = reg.groups("advanced")
        assertEquals(listOf("GRIB weather", "Routes"), groups.map { it.title })
    }

    /** The value in force is what the core says it is, not the default. */
    @Test fun aFieldCarriesBothItsDefaultAndTheValueInForce() {
        val minSog = reg.groups("vessels").single().fields.first { it.key == "min_sog" }
        assertEquals(PluginField.Kind.NUMBER, minSog.kind)
        assertEquals(0.0, minSog.defaultValue, 0.0)
        assertEquals(0.5, minSog.value, 0.0)
        assertEquals("kn", minSog.unit)
        assertEquals(0.0, minSog.min, 0.0)
        assertEquals(5.0, minSog.max, 0.0)
    }

    /** A toggle crosses as a JSON boolean and lands as 1 or 0. */
    @Test fun aToggleReadsAsOneOrZero() {
        val alarm = reg.groups("alarms").single().fields.first { it.key == "cpa_alarm" }
        assertEquals(PluginField.Kind.TOGGLE, alarm.kind)
        assertTrue(alarm.on)
        assertEquals(1.0, alarm.value, 0.0)

        val legs = reg.groups("advanced").first { it.title == "Routes" }.fields.single()
        assertFalse(legs.on)
        assertEquals(0.0, legs.value, 0.0)
        assertEquals(1.0, legs.defaultValue, 0.0)
    }

    /** A schema that declares no label still renders: the key names it. */
    @Test fun anUnlabelledFieldFallsBackToItsKey() {
        val one = PluginRegistry.parse(
            """{"plugins":[{"id":"x","settings":[{"key":"gain","kind":"number"}]}]}"""
        ).plugins.single().fields.single()
        assertEquals("gain", one.label)
        assertEquals("advanced", one.tab)
    }

    // ---- the connection lists -----------------------------------------------

    @Test fun bothConnectionListsLandOnTheConnectionsSection() {
        assertEquals(listOf("connections", "servers"), reg.lists("connections").map { it.key })
        assertTrue(reg.lists("vessels").isEmpty())
    }

    /**
     * The summary line's three columns are found by what the schema DECLARES,
     * never by name: the optional text column is the mariner's own label, the
     * required one is the address, and the first number is the port.
     */
    @Test fun theSummaryColumnsAreDerivedFromTheSchema() {
        val nmea = reg.lists("connections").first { it.key == "connections" }
        assertEquals("name", nmea.nameField?.key)
        assertEquals("host", nmea.addressField?.key)
        assertEquals("port", nmea.portField?.key)
    }

    /** The switch is the column the manifest named, not merely the first
     *  toggle: Signal K declares `websocket` before `enabled`. */
    @Test fun theSwitchColumnIsTheOneTheManifestNamed() {
        val sk = reg.lists("connections").first { it.key == "servers" }
        assertEquals("enabled", sk.switchField?.key)
    }

    /** Anything the plugin declared beyond the standard four is rendered from
     *  its kind, which is how Signal K's WebSocket flag appears with no shell
     *  change. */
    @Test fun theExtraColumnsAreWhateverIsLeftOver() {
        val sk = reg.lists("connections").first { it.key == "servers" }
        assertEquals(listOf("websocket"), sk.extraFields.map { it.key })

        val nmea = reg.lists("connections").first { it.key == "connections" }
        assertTrue("NMEA declares only the standard four", nmea.extraFields.isEmpty())
    }

    /** With no `switch_key`, the first toggle takes the part. */
    @Test fun withNoNamedSwitchTheFirstToggleIsUsed() {
        val schema = PluginRegistry.parse(
            """{"plugins":[{"id":"x","lists":[{"key":"k","tab":"connections","item_fields":[
               {"key":"on","label":"On","kind":"toggle","default":true}]}]}]}"""
        ).lists("connections").single()
        assertEquals("on", schema.switchField?.key)
    }

    @Test fun theRowCapAndTheWordingComeFromTheCore() {
        val nmea = reg.lists("connections").first { it.key == "connections" }
        assertEquals(8, nmea.maxRows)
        assertEquals("Add Connection", nmea.addLabel)
        assertEquals("No connections yet.", nmea.empty)
        assertEquals("Connections", nmea.group)
        assertTrue(nmea.footer.startsWith("Give the address"))
    }

    @Test fun aListWithNoRowCapTakesTheHostsDefault() {
        val schema = PluginRegistry.parse(
            """{"plugins":[{"id":"x","lists":[{"key":"k","tab":"connections","item_fields":[]}]}]}"""
        ).lists("connections").single()
        assertEquals(8, schema.maxRows)
    }

    // ---- discovery ----------------------------------------------------------

    @Test fun aListSaysWhatToBrowseTheNetworkFor() {
        val nmea = reg.lists("connections").first { it.key == "connections" }
        assertEquals(listOf("_nmea-0183._tcp"), nmea.discover.map { it.service })
        assertTrue("NMEA sets no extra column", nmea.discover.single().set.isEmpty())
    }

    /** A row added from a Signal K find arrives with its WebSocket column on. */
    @Test fun aDiscoveredRowCarriesTheColumnsTheServiceImplies() {
        val sk = reg.lists("connections").first { it.key == "servers" }
        assertEquals(mapOf("websocket" to "true"), sk.discover.single().set)
    }

    // ---- the rows in force --------------------------------------------------

    @Test fun theRowsAreReadWithEveryCellAsText() {
        val nmea = reg.lists("connections").first { it.key == "connections" }
        val rows = reg.rows(nmea)
        assertEquals(listOf("row-a1b2c3d4", "row-deadbeef"), rows.map { it.id })
        assertEquals("Masthead", rows[0].text("name"))
        assertEquals("192.168.1.50", rows[0].text("host"))
        assertEquals("10110", rows[0].text("port"))
        assertTrue(rows[0].on("enabled"))
        assertFalse(rows[1].on("enabled"))
        assertEquals("", rows[1].text("name"))
    }

    @Test fun aListWithNoRowsReadsAsEmptyRatherThanMissing() {
        val schema = PluginRegistry.parse(
            """{"plugins":[{"id":"x","lists":[{"key":"k","tab":"connections","item_fields":[]}]}]}"""
        ).lists("connections").single()
        assertTrue(PluginRegistry.parse(Fixtures.registry).rows(schema).isEmpty())
    }

    // ---- what a plugin says about each row ----------------------------------

    @Test fun theStatusItemsAreKeyedByTheRowIdTheShellMinted() {
        val nmea = reg.lists("connections").first { it.key == "connections" }
        val good = reg.status(nmea, "row-a1b2c3d4")!!
        assertEquals("connected", good.state)
        assertEquals("Connected · 44 msg/s", good.line)
        assertEquals(PluginStatusItem.Tone.GOOD, good.tone)

        val bad = reg.status(nmea, "row-deadbeef")!!
        assertEquals("Unreachable · no route to host", bad.line)
        assertEquals(PluginStatusItem.Tone.BAD, bad.tone)
    }

    @Test fun aRowNobodyHasReportedOnHasNoStatus() {
        val nmea = reg.lists("connections").first { it.key == "connections" }
        assertNull(reg.status(nmea, "row-never-seen"))
    }

    /** A plugin may write a plain sentence instead of the status line; the
     *  shell must show it rather than fall over on it. */
    @Test fun aPlainSentenceStatusYieldsNoItemsAndDoesNotThrow() {
        val ais = plugin("org.beetlebug.ais")
        assertEquals("Tracking 14 targets", ais.status)
        assertTrue(ais.statusItems.isEmpty())
    }

    @Test fun aStatusObjectWithNoItemsYieldsNone() {
        assertTrue(plugin("org.example.grib").statusItems.isEmpty())
    }

    @Test fun everyToneIsMappedAndAnUnknownStateReadsAsBad() {
        fun tone(state: String) = PluginStatusItem("r", state, "").tone
        assertEquals(PluginStatusItem.Tone.GOOD, tone("connected"))
        assertEquals(PluginStatusItem.Tone.TRYING, tone("reconnecting"))
        assertEquals(PluginStatusItem.Tone.OFF, tone("paused"))
        assertEquals(PluginStatusItem.Tone.OFF, tone(""))
        assertEquals(PluginStatusItem.Tone.BAD, tone("refused"))
        assertEquals(PluginStatusItem.Tone.BAD, tone("no_address"))
        assertEquals(PluginStatusItem.Tone.BAD, tone("something_new"))
    }

    /** An unknown state still reads as words rather than as a token. */
    @Test fun aStatusWithNoDetailIsJustTheWord() {
        assertEquals("Paused", PluginStatusItem("r", "paused", "").line)
        assertEquals("Waiting", PluginStatusItem("r", "", "").line)
    }

    // ---- capabilities -------------------------------------------------------

    @Test fun aCapabilityCarriesTheCoresOwnSentenceAndItsGrant() {
        val caps = plugin("org.beetlebug.nmea0183").capabilities
        assertEquals(
            listOf("net.tcp-client", "vessel.publish", "ais.publish", "bus.publish"),
            caps.map { it.cap },
        )
        assertEquals("Connect to devices on your boat's own network.", caps[0].sentence)
        assertTrue(caps[0].granted)
        assertFalse("the mariner revoked this one", caps[3].granted)
    }

    /** Absent means granted: a manifest's capability is in force until the
     *  mariner switches it off. */
    @Test fun aCapabilityWithNoGrantFlagIsGranted() {
        val cap = PluginRegistry.parse(
            """{"plugins":[{"id":"x","capabilities":[{"cap":"overlay.draw"}]}]}"""
        ).plugins.single().capabilities.single()
        assertTrue(cap.granted)
        assertEquals("the sentence falls back to the name", "overlay.draw", cap.sentence)
    }

    // ---- what it refuses to fall over on ------------------------------------

    @Test fun nothingAtAllIsAnEmptyRegistry() {
        assertTrue(PluginRegistry.parse(null).plugins.isEmpty())
        assertTrue(PluginRegistry.parse("").plugins.isEmpty())
    }

    /** A null read is the plugin layer mid-restart. It must not throw. */
    @Test fun malformedJsonIsAnEmptyRegistry() {
        assertTrue(PluginRegistry.parse("{").plugins.isEmpty())
        assertTrue(PluginRegistry.parse("not json at all").plugins.isEmpty())
        assertTrue(PluginRegistry.parse("""{"plugins":"nope"}""").plugins.isEmpty())
    }

    /** A plugin with no id is not a plugin. */
    @Test fun anEntryWithNoIdIsSkipped() {
        val r = PluginRegistry.parse("""{"plugins":[{"name":"No id"},{"id":"ok"}]}""")
        assertEquals(listOf("ok"), r.plugins.map { it.id })
    }

    /** A field of a kind this build does not know is dropped, not guessed at. */
    @Test fun anUnknownFieldKindIsDropped() {
        val p = PluginRegistry.parse(
            """{"plugins":[{"id":"x","settings":[
               {"key":"a","kind":"colour"},{"key":"b","kind":"toggle","default":false}]}]}"""
        ).plugins.single()
        assertEquals(listOf("b"), p.fields.map { it.key })
    }
}
