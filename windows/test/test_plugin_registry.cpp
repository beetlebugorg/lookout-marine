/* The wasm plugin registry: what the shell makes of what the core hands over,
 * and what goes back.
 *
 * The shell knows nothing about what any plugin does. A number with a unit
 * and a range, a toggle, a text box, and a list the mariner adds rows to, is
 * the whole vocabulary, so this contract is the whole of what the settings
 * pane can get wrong, and the round trip through it carries a mariner's
 * connections, which there is nothing to get back from once they are lost.
 *
 * Reading the registry is lookout_plugins_read, and a test has no core to take
 * one from, so the two plugins below are built as values the way the walk in
 * plugins/ui/PluginSettings.cpp would leave them.
 */
#include "lk_test.h"

#include "lk_plugin_registry.h"

using namespace lktest;
using namespace lkw;

namespace
{
    PluginField Number(char const *key, char const *label, char const *unit, double min,
                       double max, double fallback)
    {
        PluginField f;
        f.key = key;
        f.label = label;
        f.unit = unit;
        f.kind = LOOKOUT_PLUGIN_SETTING_NUMBER;
        f.min = min;
        f.max = max;
        f.fallback = fallback;
        return f;
    }

    PluginField Toggle(char const *key, char const *label, bool fallback)
    {
        PluginField f;
        f.key = key;
        f.label = label;
        f.kind = LOOKOUT_PLUGIN_SETTING_TOGGLE;
        f.fallback = fallback ? 1 : 0;
        return f;
    }

    PluginField Text(char const *key, char const *label, char const *fallback)
    {
        PluginField f;
        f.key = key;
        f.label = label;
        f.kind = LOOKOUT_PLUGIN_SETTING_TEXT;
        f.fallback_text = fallback;
        return f;
    }

    PluginCell Cell(lookout_plugin_setting_kind kind, double number, char const *text)
    {
        PluginCell c;
        c.kind = kind;
        c.number = number;
        c.toggle = number != 0;
        c.text = text;
        return c;
    }

    /* The AIS plugin: three scalar settings under two headings. */
    PluginInfo Ais()
    {
        PluginInfo p;
        p.id = "org.beetlebug.ais";
        p.name = "AIS";
        p.version = "1.2.0";
        p.origin = LOOKOUT_ORIGIN_BUNDLED;
        p.live = true;
        p.status = R"({"state":"running","detail":"44 msg/s"})";
        p.capabilities.push_back({ "ais.read", "See other vessels", true });
        p.capabilities.push_back({ "net.http", "Reach the internet", false });

        PluginField limit = Number("cpa_limit", "CPA alarm", "m", 0, 2000, 926);
        PluginField alarm = Toggle("cpa_alarm", "Sound the alarm", true);
        PluginField trail = Number("trail", "trail", "", 0, 30, 6);
        p.fields = { limit, alarm, trail };
        p.values["cpa_limit"] = 500;
        p.values["cpa_alarm"] = 0;
        p.values["trail"] = 6;
        p.groups.push_back({ p.id, "Collision", "alarms", { limit, alarm } });
        p.groups.push_back({ p.id, "AIS", "advanced", { trail } });
        return p;
    }

    /* The NMEA 0183 plugin: one list of connections, two rows. */
    PluginInfo Nmea()
    {
        PluginInfo p;
        p.id = "org.beetlebug.nmea0183";
        p.name = "NMEA 0183";
        p.origin = LOOKOUT_ORIGIN_INSTALLED;
        p.live = true;
        p.status = R"({"state":"degraded","items":[)"
                   R"({"id":"r1","state":"connected","detail":"12 msg/s"},)"
                   R"({"id":"r2","state":"unreachable"}]})";
        p.file_types = { ".nmea", ".log" };

        PluginList list;
        list.plugin_id = p.id;
        list.key = "connections";
        list.tab = "connections";
        list.title = "Connections";
        list.footer = "One line per gateway.";
        list.empty = "Nothing here yet.";
        list.add_label = "Add a gateway";
        list.switch_key = "on";
        list.max_rows = 8;
        list.item_fields = { Text("host", "Host", "localhost"),
                             Number("port", "Port", "", 1, 65535, 10110),
                             Toggle("on", "On", true) };

        PluginDiscover want;
        want.service = "_signalk-ws._tcp";
        want.set.emplace("ws", Cell(LOOKOUT_PLUGIN_SETTING_TOGGLE, 1, ""));
        want.set.emplace("port", Cell(LOOKOUT_PLUGIN_SETTING_NUMBER, 3000, ""));
        want.set.emplace("path", Cell(LOOKOUT_PLUGIN_SETTING_TEXT, 0, "/signalk"));
        list.discover.push_back(want);

        PluginRow r1;
        r1.id = "r1";
        r1.cells.emplace("host", Cell(LOOKOUT_PLUGIN_SETTING_TEXT, 0, "gps.local"));
        r1.cells.emplace("port", Cell(LOOKOUT_PLUGIN_SETTING_NUMBER, 10110, ""));
        r1.cells.emplace("on", Cell(LOOKOUT_PLUGIN_SETTING_TOGGLE, 1, ""));
        PluginRow r2;
        r2.id = "r2";
        r2.cells.emplace("host", Cell(LOOKOUT_PLUGIN_SETTING_TEXT, 0, ""));
        r2.cells.emplace("port", Cell(LOOKOUT_PLUGIN_SETTING_NUMBER, 10110, ""));
        r2.cells.emplace("on", Cell(LOOKOUT_PLUGIN_SETTING_TOGGLE, 0, ""));

        p.rows["connections"] = { r1, r2 };
        p.lists.push_back(std::move(list));
        return p;
    }

    lookout_plugin_setting Declared(char const *key, char const *label,
                                    lookout_plugin_setting_kind kind)
    {
        lookout_plugin_setting s{};
        s.key = key;
        s.label = label;
        s.desc = "";
        s.group = "";
        s.kind = kind;
        s.section = LOOKOUT_SECTION_ALARMS;
        s.unit = "m";
        s.min = 0;
        s.max = 2000;
        s.default_number = 926;
        s.default_text = "";
        s.placeholder = "";
        s.footer = "";
        s.empty = "";
        s.add_label = "";
        s.switch_key = "";
        s.value = 500;
        return s;
    }
}

void TestPluginRegistry()
{
    Suite("lk_plugin_registry: reading");

    LK_CASE("a setting's declaration reaches the field");
    {
        PluginField f{ Declared("cpa_limit", "CPA alarm", LOOKOUT_PLUGIN_SETTING_NUMBER) };
        LK_EQ(f.key, std::string("cpa_limit"));
        LK_EQ(f.label, std::string("CPA alarm"));
        LK_EQ(f.unit, std::string("m"));
        LK_NEAR(f.min, 0, 0);
        LK_NEAR(f.max, 2000, 0);
        LK_NEAR(f.fallback, 926, 0);
        LK_EQ(f.kind, LOOKOUT_PLUGIN_SETTING_NUMBER);
    }

    /* A control with no name on it is unusable. */
    LK_CASE("a setting with no label is named by its key");
    {
        PluginField f{ Declared("trail", "", LOOKOUT_PLUGIN_SETTING_NUMBER) };
        LK_EQ(f.label, std::string("trail"));
    }

    LK_CASE("a value the core typed keeps its type");
    {
        lookout_plugin_value v{};
        v.key = "host";
        v.kind = LOOKOUT_PLUGIN_SETTING_TEXT;
        v.text = "gps.local";
        PluginCell text{ v };
        LK_EQ(text.kind, LOOKOUT_PLUGIN_SETTING_TEXT);
        LK_EQ(text.text, std::string("gps.local"));

        v.key = "on";
        v.kind = LOOKOUT_PLUGIN_SETTING_TOGGLE;
        v.number = 1;
        v.text = "";
        PluginCell on{ v };
        LK_EQ(on.toggle, true);
    }

    /* The section is what files an AIS alarm under Alarms rather than under a
     * plugin system the mariner never meets. */
    LK_CASE("every section lands in a page this shell has");
    {
        LK_EQ(std::string(SectionId(LOOKOUT_SECTION_DISPLAY)), std::string("display"));
        LK_EQ(std::string(SectionId(LOOKOUT_SECTION_DEPTHS)), std::string("depths"));
        LK_EQ(std::string(SectionId(LOOKOUT_SECTION_TEXT)), std::string("text"));
        LK_EQ(std::string(SectionId(LOOKOUT_SECTION_CHARTS)), std::string("charts"));
        LK_EQ(std::string(SectionId(LOOKOUT_SECTION_VESSELS)), std::string("vessels"));
        LK_EQ(std::string(SectionId(LOOKOUT_SECTION_ALARMS)), std::string("alarms"));
        LK_EQ(std::string(SectionId(LOOKOUT_SECTION_CONNECTIONS)), std::string("connections"));
        LK_EQ(std::string(SectionId(LOOKOUT_SECTION_ADVANCED)), std::string("advanced"));
    }

    Suite("lk_plugin_registry: writing the config");

    LK_CASE("the object the core is handed");
    {
        LK_EQ(PluginConfigJson(Ais()),
              std::string(R"({"cpa_limit":500,"cpa_alarm":false,"trail":6})"));
    }

    /* A toggle goes as a JSON bool, which is the only shape the core accepts
     * for one: a 1 or a 0 is refused. */
    LK_CASE("a toggle is a bool, and a whole number carries no decimal point");
    {
        PluginInfo p;
        p.id = "x";
        p.fields = { Toggle("on", "On", false), Number("n", "N", "", 0, 1000, 0),
                     Number("f", "F", "", 0, 10, 0) };
        p.values["on"] = 1;
        p.values["n"] = 926;
        p.values["f"] = 2.5;
        LK_EQ(PluginConfigJson(p), std::string(R"({"on":true,"n":926,"f":2.5})"));
    }

    LK_CASE("a list goes as its whole array, each row keeping the id the shell gave it");
    {
        LK_EQ(PluginConfigJson(Nmea()),
              std::string(R"({"connections":[)"
                          R"({"id":"r1","host":"gps.local","port":10110,"on":true},)"
                          R"({"id":"r2","host":"","port":10110,"on":false}]})"));
    }

    LK_CASE("a plugin with nothing declared writes an empty object");
    {
        PluginInfo p;
        p.id = "x";
        LK_EQ(PluginConfigJson(p), std::string("{}"));
    }

    LK_CASE("an empty list still goes, so clearing the last row is heard");
    {
        PluginInfo p;
        p.id = "x";
        PluginList list;
        list.key = "k";
        list.item_fields = { Text("h", "H", "") };
        p.lists.push_back(std::move(list));
        LK_EQ(PluginConfigJson(p), std::string(R"({"k":[]})"));
    }

    /* A field the row never carried takes the manifest default rather than
     * dropping out of the object. */
    LK_CASE("a cell the row does not hold writes its default");
    {
        PluginInfo p;
        p.id = "x";
        PluginList list;
        list.key = "k";
        list.item_fields = { Text("h", "H", "localhost"), Toggle("on", "On", true),
                             Number("port", "Port", "", 1, 65535, 10110) };
        p.lists.push_back(std::move(list));
        PluginRow row;
        row.id = "r1";
        p.rows["k"] = { row };
        LK_EQ(PluginConfigJson(p),
              std::string(R"({"k":[{"id":"r1","h":"localhost","on":true,"port":10110}]})"));
    }

    /* A host name is whatever was typed. */
    LK_CASE("a string is quoted and escaped");
    {
        LK_EQ(Quoted("plain"), std::string("\"plain\""));
        LK_EQ(Quoted("say \"hi\""), std::string("\"say \\\"hi\\\"\""));
        LK_EQ(Quoted("a\\b"), std::string("\"a\\\\b\""));
        LK_EQ(Quoted("line\nbreak\ttab\r"), std::string("\"line\\nbreak\\ttab\\r\""));
        LK_EQ(Quoted(std::string("bell\x07")), std::string("\"bell\\u0007\""));
        LK_EQ(Quoted("38\xc2\xb0"), std::string("\"38\xc2\xb0\"")); /* UTF-8 passes through */
    }

    LK_CASE("a typed host crosses back as it was typed");
    {
        PluginInfo p;
        p.id = "x";
        PluginList list;
        list.key = "k";
        list.item_fields = { Text("h", "H", "") };
        p.lists.push_back(std::move(list));
        PluginRow row;
        row.id = "r1";
        row.cells.emplace("h", Cell(LOOKOUT_PLUGIN_SETTING_TEXT, 0, "say \"hi\"\n"));
        p.rows["k"] = { row };
        LK_EQ(PluginConfigJson(p), std::string(R"({"k":[{"id":"r1","h":"say \"hi\"\n"}]})"));
    }

    Suite("lk_plugin_registry: status");

    LK_CASE("the numbers a spin box steps by");
    {
        PluginField wide;
        wide.min = 0;
        wide.max = 2000;
        LK_NEAR(StepFor(wide), 10, 0);
        PluginField mid;
        mid.min = 0;
        mid.max = 30;
        LK_NEAR(StepFor(mid), 1, 0);
        PluginField fine;
        fine.min = 0;
        fine.max = 5;
        LK_NEAR(StepFor(fine), 0.5, 0);
    }

    LK_CASE("the core's state words, in the mariner's language");
    {
        LK_EQ(StateWord("running"), std::string("Running"));
        LK_EQ(StateWord("no_address"), std::string("No address"));
        LK_EQ(StateWord("reconnecting"), std::string("Reconnecting"));
        /* A word this shell does not know is shown as the core wrote it
         * rather than hidden. */
        LK_EQ(StateWord("becalmed"), std::string("becalmed"));
    }

    LK_CASE("how each state reads");
    {
        LK_CHECK(ToneFor("running") == StateTone::Good);
        LK_CHECK(ToneFor("connected") == StateTone::Good);
        LK_CHECK(ToneFor("reconnecting") == StateTone::Trying);
        LK_CHECK(ToneFor("degraded") == StateTone::Trying);
        LK_CHECK(ToneFor("stopped") == StateTone::Idle);
        LK_CHECK(ToneFor("disabled") == StateTone::Idle);
        LK_CHECK(ToneFor("unreachable") == StateTone::Bad);
        LK_CHECK(ToneFor("becalmed") == StateTone::Bad);
    }

    LK_CASE("the plugin's own line");
    {
        std::string state;
        LK_EQ(PluginStatusLine(Ais(), &state), std::string("Running \xc2\xb7 44 msg/s"));
        LK_EQ(state, std::string("running"));
    }

    /* "Stopped" for a dead one whatever its last words were. */
    LK_CASE("a copy that is not live is stopped");
    {
        PluginInfo dead;
        dead.live = false;
        dead.status = R"({"state":"running","detail":"44 msg/s"})";
        std::string state;
        LK_EQ(PluginStatusLine(dead, &state), std::string("Stopped"));
        LK_EQ(state, std::string("stopped"));
    }

    LK_CASE("a live copy that says nothing is running");
    {
        PluginInfo quiet;
        quiet.live = true;
        std::string state;
        LK_EQ(PluginStatusLine(quiet, &state), std::string("Running"));
        LK_EQ(state, std::string("running"));

        PluginInfo garbled;
        garbled.live = true;
        garbled.status = "not json";
        LK_EQ(PluginStatusLine(garbled, &state), std::string("Running"));
    }

    /* Which is how a connected gateway's line finds its way to the right
     * row. */
    LK_CASE("a row's line is found by the id the shell minted");
    {
        PluginInfo nmea = Nmea();
        std::string line, state;
        LK_EQ(PluginItemStatusLine(nmea, "r1", &line, &state), true);
        LK_EQ(line, std::string("Connected \xc2\xb7 12 msg/s"));
        LK_EQ(state, std::string("connected"));

        LK_EQ(PluginItemStatusLine(nmea, "r2", &line, &state), true);
        LK_EQ(line, std::string("Unreachable")); /* no detail, just the word */
        LK_EQ(state, std::string("unreachable"));

        LK_EQ(PluginItemStatusLine(nmea, "r9", &line, &state), false);
        LK_EQ(PluginItemStatusLine(Ais(), "r1", &line, &state), false);
    }
}
