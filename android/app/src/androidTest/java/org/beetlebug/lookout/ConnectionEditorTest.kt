package org.beetlebug.lookout

import org.beetlebug.lookout.engine.EngineAccess
import org.beetlebug.lookout.hud.LookoutTheme
import org.beetlebug.lookout.plugins.PluginGroups
import org.beetlebug.lookout.plugins.PluginLists
import org.beetlebug.lookout.plugins.PluginRegistry
import org.beetlebug.lookout.plugins.PluginSettingsController
import org.beetlebug.lookout.plugins.PluginsManageSection

import android.content.Context
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The plugin-declared settings: a gateway list, a field group, and the section
 * that talks about plugins.
 *
 * EVERY WORD IS THE MANIFEST'S. The heading, the sentence under the rows, what
 * an empty list says and what the add button is called all come from the
 * plugin, so a plugin collecting something other than gateways reads correctly
 * with no shell change. That is what these check: the shell renders a schema
 * it has never seen and puts nothing of its own in the words.
 */
@RunWith(AndroidJUnit4::class)
class ConnectionEditorTest {

    @get:Rule val compose = createComposeRule()

    private val ctx: Context
        get() = InstrumentationRegistry.getInstrumentation().targetContext

    /** A gateway list and an alarm group, as the core states them. */
    private val json = """
    {"plugins":[
     {"id":"org.beetlebug.nmea0183","name":"NMEA 0183","version":"1.0","origin":"bundled",
      "status":"{\"state\":\"running\",\"items\":[{\"id\":\"row-a\",\"state\":\"connected\",\"detail\":\"44 msg/s\"},{\"id\":\"row-b\",\"state\":\"unreachable\",\"detail\":\"no route to host\"}]}",
      "capabilities":[],"settings":[],
      "lists":[{"key":"connections","group":"Connections",
        "footer":"Give the address of your instrument network's gateway.",
        "empty":"No connections yet.","add_label":"Add Connection","switch_key":"enabled",
        "tab":"connections","max_rows":2,
        "item_fields":[
         {"key":"name","label":"Name","kind":"text","optional":true,"default":"","max_len":120},
         {"key":"host","label":"Address","kind":"text","default":"","max_len":120},
         {"key":"port","label":"Port","kind":"number","min":1,"max":65535,"default":10110},
         {"key":"enabled","label":"On","kind":"toggle","default":true}],
        "rows":[
         {"id":"row-a","name":"Masthead","host":"192.168.1.50","port":10110,"enabled":true},
         {"id":"row-b","name":"","host":"nav.local","port":10111,"enabled":false}]}]},
     {"id":"org.beetlebug.ais","name":"AIS targets","version":"1.0","origin":"bundled",
      "status":"Tracking 14 targets","capabilities":[],
      "settings":[
       {"key":"cpa_limit","label":"Closest approach (CPA)","desc":"Alarm when a vessel will pass closer than this.","kind":"number","unit":"m","min":93,"max":9260,"default":926,"group":"Collision alarm","tab":"alarms","value":926},
       {"key":"cpa_alarm","label":"Collision alarm","desc":"Sound the alarm and colour the vessel red.","kind":"toggle","default":true,"group":"Collision alarm","tab":"alarms","value":true}]},
     {"id":"org.example.grib","name":"GRIB weather","version":"0.4.1","origin":"installed",
      "status":"{\"state\":\"degraded\",\"detail\":\"no file loaded\"}",
      "capabilities":[{"cap":"net.http","sentence":"Fetch forecasts from the internet.","granted":false}],
      "settings":[]}]}
    """.trimIndent()

    private val registry get() = PluginRegistry.parse(json)

    private fun plugins() = PluginSettingsController(ctx, EngineAccess()) {}

    private fun showLists() {
        compose.setContent {
            LookoutTheme(dark = false) {
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    PluginLists(registry, "connections", plugins(), first = true)
                }
            }
        }
        compose.waitForIdle()
    }

    // ---- the list, in the plugin's own words --------------------------------

    @Test fun theHeadingFooterAndAddButtonAreTheManifestsWords() {
        showLists()
        compose.onNodeWithText("CONNECTIONS").assertIsDisplayed()
        compose.onNodeWithText("Give the address of your instrument network's gateway.")
            .assertIsDisplayed()
        compose.onNodeWithText("Add Connection").assertIsDisplayed()
    }

    /** A row with a name shows it, with the address beneath. A row without one
     *  shows the address in its place, which is what the footer promises. */
    @Test fun aRowIsNamedOrFallsBackToItsAddress() {
        showLists()
        compose.onNodeWithText("Masthead").assertIsDisplayed()
        compose.onNodeWithText("192.168.1.50:10110").assertIsDisplayed()
        compose.onNodeWithText("nav.local:10111").assertIsDisplayed()
    }

    /**
     * The plugin's line for each row, so a mariner learns from the screen
     * whether the address is right.
     */
    @Test fun eachRowCarriesWhatThePluginSaysAboutIt() {
        showLists()
        compose.onNodeWithText("Connected · 44 msg/s").assertIsDisplayed()
        compose.onNodeWithText("Unreachable · no route to host").assertIsDisplayed()
    }

    /** Tapping the row opens the editor in place rather than a second sheet. */
    @Test fun theRowOpensItsEditorInPlace() {
        showLists()
        compose.onNodeWithText("Masthead").performClick()
        compose.waitForIdle()
        compose.onNodeWithText("Address").assertIsDisplayed()
        compose.onNodeWithText("Port").assertIsDisplayed()
        compose.onNodeWithText("Done").assertIsDisplayed()
        compose.onNodeWithText("Remove").assertIsDisplayed()
    }

    /** The switch lives on the row, where pausing a source needs no editing. */
    @Test fun theSwitchColumnStaysOnTheRow() {
        showLists()
        compose.onNodeWithContentDescription("Edit Masthead").assertIsDisplayed()
    }

    /**
     * The list goes quiet at the host's row cap rather than letting the mariner
     * type a gateway the core will drop on the way in.
     */
    @Test fun addGoesQuietAtTheRowCap() {
        showLists()
        compose.onNodeWithText("Add Connection").assertIsNotEnabled()
        compose.onNodeWithText("2 is all this plugin holds.").assertIsDisplayed()
    }

    /** An empty list says what the plugin says, not what the shell would. */
    @Test fun anEmptyListSaysWhatTheManifestSays() {
        val empty = PluginRegistry.parse(
            """{"plugins":[{"id":"x","name":"X","lists":[{"key":"k","group":"Servers",
               "empty":"No servers yet.","add_label":"Add Server","tab":"connections",
               "max_rows":8,"item_fields":[],"rows":[]}]}]}"""
        )
        compose.setContent {
            LookoutTheme(dark = false) {
                Column { PluginLists(empty, "connections", plugins(), first = true) }
            }
        }
        compose.onNodeWithText("SERVERS").assertIsDisplayed()
        compose.onNodeWithText("No servers yet.").assertIsDisplayed()
        compose.onNodeWithText("Add Server").assertIsDisplayed()
    }

    // ---- a plugin's own controls --------------------------------------------

    @Test fun aFieldGroupIsDrawnUnderTheManifestsHeading() {
        compose.setContent {
            LookoutTheme(dark = false) {
                Column { PluginGroups(registry.groups("alarms"), plugins(), first = true) }
            }
        }
        compose.onNodeWithText("COLLISION ALARM").assertIsDisplayed()
        compose.onNodeWithText("Closest approach (CPA)").assertIsDisplayed()
        compose.onNodeWithText("Alarm when a vessel will pass closer than this.").assertIsDisplayed()
        compose.onNodeWithText("Collision alarm").assertIsDisplayed()
    }

    /** A number shows its value and the unit the manifest gave it. */
    @Test fun aNumberShowsItsValueAndUnit() {
        compose.setContent {
            LookoutTheme(dark = false) {
                Column { PluginGroups(registry.groups("alarms"), plugins(), first = true) }
            }
        }
        compose.onNodeWithText("926").assertIsDisplayed()
        compose.onNodeWithText(" m").assertIsDisplayed()
    }

    // ---- the section that talks about plugins -------------------------------

    /**
     * Only what the mariner installed and any developer override. The bundled
     * set is the product, not something to manage.
     */
    @Test fun onlyTheManagedPluginsAreListed() {
        compose.setContent {
            LookoutTheme(dark = false) {
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    PluginsManageSection(registry, plugins())
                }
            }
        }
        compose.onNodeWithText("GRIB weather").assertIsDisplayed()
        compose.onAllNodes(hasText("NMEA 0183")).assertCountEquals(0)
        compose.onAllNodes(hasText("AIS targets")).assertCountEquals(0)
    }

    /** The status reads as a sentence, never as the JSON a plugin wrote it in. */
    @Test fun aManagedPluginsStatusReadsAsWords() {
        compose.setContent {
            LookoutTheme(dark = false) {
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    PluginsManageSection(registry, plugins())
                }
            }
        }
        compose.onNodeWithText("Degraded · no file loaded").assertIsDisplayed()
        compose.onAllNodes(hasText("{", substring = true)).assertCountEquals(0)
    }

    /** Opening a row shows the grants in the core's own consent wording. */
    @Test fun aPluginsGrantsAreShownInTheCoresWords() {
        compose.setContent {
            LookoutTheme(dark = false) {
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    PluginsManageSection(registry, plugins())
                }
            }
        }
        compose.onNodeWithText("GRIB weather").performClick()
        compose.waitForIdle()
        compose.onNodeWithText("Fetch forecasts from the internet.").assertIsDisplayed()
        compose.onNodeWithText("Uninstall").assertIsDisplayed()
    }

    /** Uninstalling asks first, and says what it takes with it. */
    @Test fun uninstallConfirmsBeforeItRemovesAnything() {
        compose.setContent {
            LookoutTheme(dark = false) {
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    PluginsManageSection(registry, plugins())
                }
            }
        }
        compose.onNodeWithText("GRIB weather").performClick()
        compose.waitForIdle()
        compose.onNodeWithText("Uninstall").performClick()
        compose.waitForIdle()
        compose.onNodeWithText("Uninstall GRIB weather?").assertIsDisplayed()
        compose.onNodeWithText("Removes the plugin and everything it drew.").assertIsDisplayed()
        compose.onNodeWithText("Cancel").assertIsDisplayed()
    }

    /** Nothing is installed before its permissions are shown. */
    @Test fun theInstallRouteSaysConsentComesFirst() {
        compose.setContent {
            LookoutTheme(dark = false) {
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    PluginsManageSection(registry, plugins())
                }
            }
        }
        compose.onNodeWithText("Install plugin…").assertIsDisplayed()
        compose.onNodeWithText("Nothing is installed before its permissions are shown.")
            .assertIsDisplayed()
    }

    @Test fun aPluginWithNoCapabilitiesSaysSo() {
        val plain = PluginRegistry.parse(
            """{"plugins":[{"id":"x","name":"Routes","origin":"installed",
               "status":"","capabilities":[],"settings":[]}]}"""
        )
        compose.setContent {
            LookoutTheme(dark = false) {
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    PluginsManageSection(plain, plugins())
                }
            }
        }
        compose.onNodeWithText("Routes").performClick()
        compose.waitForIdle()
        compose.onNodeWithText("This plugin only draws its own settings pages.").assertIsDisplayed()
    }
}
