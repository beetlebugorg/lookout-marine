package org.beetlebug.lookout

import org.beetlebug.lookout.engine.ChartEngine
import org.beetlebug.lookout.plugins.PluginField
import org.beetlebug.lookout.plugins.PluginRegistry
import org.beetlebug.lookout.plugins.SettingsSection
import org.beetlebug.lookout.plugins.parseTableSpecs

import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The plugin layer as it actually comes up, on a device, with the wasm host
 * linked and the five bundled modules loaded out of the APK.
 *
 * Everything else that reads the registry is driven from a fixture, because a
 * fixture can be shaped for the case under test. What a fixture cannot do is
 * disagree with the core: it is transcribed from the shipped manifests, and it
 * keeps agreeing with itself after either one changes. This is the test that
 * fails instead.
 *
 * It needs the real Activity, because the registry belongs to an open engine
 * and the engine wants a Surface. That makes it the slowest test here and the
 * only one that opens a chart.
 */
@RunWith(AndroidJUnit4::class)
class LivePluginsTest {

    /** The five modules the APK carries under assets/plugins. */
    private val bundled = listOf(
        "org.beetlebug.ais",
        "org.beetlebug.laylines",
        "org.beetlebug.nmea0183",
        "org.beetlebug.ownship",
        "org.beetlebug.signalk",
    )

    /**
     * Open the app and wait for the plugin layer. The chart open and the atlas
     * bake come first, so this is seconds rather than milliseconds.
     */
    private fun withRegistry(block: (PluginRegistry, Lookout) -> Unit) {
        ActivityScenario.launch(LookoutActivity::class.java).use {
            // The chart open and the atlas bake come first, so the engine is
            // seconds away even on the bundled cell.
            val open = waitFor(ENGINE_TIMEOUT_MS) { ChartEngine.get().lookout != null }
            assertTrue("the engine never opened", open)

            // Fail on the spot when the host is not linked. Polling for a
            // layer that will never arrive turns one missing archive into
            // eleven minutes of timeouts.
            assertTrue(
                "this build has no wasm plugin host: build-libs.sh could not find " +
                    "vendor/wamr-dist-android-arm64/lib/libvmlib.a",
                ChartEngine.get().lookout!!.pluginsActive(),
            )

            val ready = waitFor(REGISTRY_TIMEOUT_MS) {
                val l = ChartEngine.get().lookout
                l != null && (PluginRegistry.read(l)?.plugins?.size ?: 0) >= bundled.size
            }
            assertTrue("the plugin layer came up short of the bundled set", ready)
            val l = ChartEngine.get().lookout!!
            block(PluginRegistry.read(l)!!, l)
        }
    }

    private fun waitFor(timeoutMs: Long, ready: () -> Boolean): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (ready()) return true
            Thread.sleep(200)
        }
        return ready()
    }

    private companion object {
        const val ENGINE_TIMEOUT_MS = 40_000L

        /** The layer starts right after the open, so this is a settling wait
         *  and not a bake. */
        const val REGISTRY_TIMEOUT_MS = 5_000L
    }

    // ---- the layer itself ---------------------------------------------------

    /**
     * An APK without the wasm host loads nothing and says so in the log rather
     * than failing to build, so this is the check that the host is linked at
     * all. `build-libs.sh` builds the WAMR archive when it is missing.
     */
    @Test fun theWasmHostIsLinkedAndTheBundledSetComesUp() {
        withRegistry { reg, _ ->
            assertTrue("no plugin host in this build", ChartEngine.get().lookout!!.pluginsActive())
            assertEquals(bundled, reg.plugins.map { it.id }.sorted())
        }
    }

    /** The bundled ids belong to the application: none is manageable. */
    @Test fun nothingBundledIsOfferedForRemoval() {
        withRegistry { reg, _ ->
            assertTrue(reg.plugins.all { it.bundled })
            assertTrue("a bundled plugin was listed as managed", reg.managed.isEmpty())
        }
    }

    /**
     * A schema that names no label still renders: the key names the control.
     * The fixture cannot show this, because a fixture sets a label.
     */
    @Test fun everySettingHasALabelAndASection() {
        withRegistry { reg, _ ->
            val fields = reg.plugins.flatMap { it.fields } +
                reg.plugins.flatMap { p -> p.lists.flatMap { it.itemFields } }
            assertTrue("no settings were read", fields.isNotEmpty())
            assertTrue("a setting read with no label", fields.all { it.label.isNotEmpty() })
            assertTrue(
                "a setting landed outside the known sections",
                fields.all { f -> SettingsSection.all.any { it.id == f.tab } },
            )
        }
    }

    /** The consent wording is the core's, so every shell says the same thing. */
    @Test fun everyCapabilityHasTheCoresOwnSentence() {
        withRegistry { reg, _ ->
            val caps = reg.plugins.flatMap { it.capabilities }
            assertTrue("no capabilities were read", caps.isNotEmpty())
            assertTrue("a capability read with no sentence", caps.all { it.sentence.isNotEmpty() })
        }
    }

    // ---- what the shell renders from it -------------------------------------

    /**
     * The sections the plugins fill. Without a plugin layer the settings sheet
     * shows the core's six; with one it shows nine, and this is where the other
     * three come from.
     */
    @Test fun thePluginsFillTheVesselsAlarmsAndConnectionsSections() {
        withRegistry { reg, _ ->
            assertEquals(
                listOf("display", "depths", "text", "charts", "vessels", "alarms",
                       "connections", "plugins", "advanced"),
                reg.sections.map { it.id },
            )
        }
    }

    /** AIS declares the collision alarm, so the Alarms section has controls. */
    @Test fun theAlarmsSectionHasTheCollisionControls() {
        withRegistry { reg, _ ->
            val group = reg.groups("alarms").firstOrNull { it.pluginId == "org.beetlebug.ais" }
            assertNotNull("AIS declares no alarm group", group)
            val keys = group!!.fields.map { it.key }
            assertTrue("cpa_limit is missing: $keys", "cpa_limit" in keys)
            assertTrue("cpa_alarm is missing: $keys", "cpa_alarm" in keys)
        }
    }

    /**
     * The two source plugins each declare a connection list, and the editor is
     * rendered entirely from what they declare. Every column the summary line
     * needs has to be derivable, or a row shows nothing about itself.
     */
    @Test fun everyConnectionListDeclaresTheColumnsTheEditorNeeds() {
        withRegistry { reg, _ ->
            val lists = reg.lists("connections")
            assertEquals(
                listOf("org.beetlebug.nmea0183", "org.beetlebug.signalk"),
                lists.map { it.pluginId }.sorted(),
            )
            for (l in lists) {
                assertNotNull("${l.pluginId}/${l.key} has no address column", l.addressField)
                assertNotNull("${l.pluginId}/${l.key} has no port column", l.portField)
                assertNotNull("${l.pluginId}/${l.key} has no on/off column", l.switchField)
                assertTrue("${l.pluginId}/${l.key} names no add button", l.addLabel.isNotEmpty())
                assertTrue("${l.pluginId}/${l.key} caps at ${l.maxRows}", l.maxRows > 0)
            }
        }
    }

    /** Signal K announces itself over DNS-SD, which is what the nearby rows
     *  under the list are browsed from. */
    @Test fun signalKSaysWhatToBrowseTheNetworkFor() {
        withRegistry { reg, _ ->
            val sk = reg.lists("connections").first { it.pluginId == "org.beetlebug.signalk" }
            assertEquals(listOf("_signalk-ws._tcp"), sk.discover.map { it.service })
        }
    }

    /** Every field the core publishes is one the shell knows how to draw. */
    @Test fun everyDeclaredFieldIsAKindTheShellRenders() {
        withRegistry { reg, _ ->
            for (p in reg.plugins) {
                for (f in p.fields) {
                    assertTrue(
                        "${p.id}/${f.key} is a loose text field, which belongs in a list",
                        f.kind != PluginField.Kind.TEXT,
                    )
                    assertTrue("${p.id}/${f.key} has no label", f.label.isNotEmpty())
                }
            }
        }
    }

    /** Capabilities carry the core's own consent wording, which is what the
     *  grants list and the install sheet show. */
    @Test fun everyCapabilityCarriesASentence() {
        withRegistry { reg, _ ->
            val caps = reg.plugins.flatMap { it.capabilities }
            assertTrue("no plugin asked for anything", caps.isNotEmpty())
            for (c in caps) {
                assertTrue("${c.cap} has no sentence", c.sentence.isNotEmpty())
                assertTrue("${c.cap}'s sentence is just its name", c.sentence != c.cap)
            }
        }
    }

    // ---- the declared tables ------------------------------------------------

    /** AIS declares the Vessels table, and it has to be locatable or a row's
     *  tap reveals nothing. */
    @Test fun theAisTableIsDeclaredAndLocatable() {
        withRegistry { _, _ ->
            val specs = parseTableSpecs(ChartEngine.get().lookout?.pluginTables())
            val ais = specs.firstOrNull { it.plugin == "org.beetlebug.ais" }
            assertNotNull("AIS declares no table: ${specs.map { it.id }}", ais)
            assertTrue("the AIS table has no position", ais!!.locatable)
            assertTrue("the AIS table lands on no section", ais.menu.isNotEmpty())
            assertTrue("the AIS table has no columns", ais.columns.isNotEmpty())
        }
    }

    // ---- the alerts ---------------------------------------------------------

    /** Nothing is alarming at the dock, and the read still has to come back:
     *  null means the core said nothing, which is a different state. */
    @Test fun theAlertsReadAsAnEmptySetRatherThanAsSilence() {
        withRegistry { _, l ->
            val set = org.beetlebug.lookout.plugins.PluginAlertSet.read(l)
            assertNotNull("the alerts did not read", set)
            assertTrue("something is alarming with no instruments installed", set!!.alerts.isEmpty())
        }
    }

    /** With nothing plugged in, nothing is connected and nothing is being
     *  dialled but the gateway row the developer override seeds. */
    @Test fun theConnectionStateReadsWithNoGatewayAboard() {
        withRegistry { _, _ ->
            val bits = ChartEngine.get().lookout!!.pluginsConnectionState()
            assertEquals("something reported a live session at the dock", 0, bits and 1)
        }
    }
}
