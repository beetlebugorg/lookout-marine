/* The wasm plugin registry: what the core hands over, and what goes back.
 *
 * The shell knows nothing about what any plugin does. A number with a unit
 * and a range, a toggle, a text box, and a list the mariner adds rows to, is
 * the whole vocabulary — so this contract is the whole of what the settings
 * pane can get wrong, and the round trip through it carries a mariner's
 * connections, which there is nothing to get back from once they are lost.
 */
#include "lk_test.h"

#include "lk_plugin_registry.h"

using namespace lktest;
using namespace lkw;

namespace
{
    char const *kRegistry = R"({"plugins":[
      {
        "id": "org.beetlebug.ais", "name": "AIS", "version": "1.2.0",
        "origin": "bundled", "live": true,
        "status": "{\"state\":\"running\",\"detail\":\"44 msg/s\"}",
        "capabilities": [
          {"cap":"ais.read","sentence":"See other vessels","granted":true},
          {"cap":"net.http","sentence":"Reach the internet","granted":false},
          {"sentence":"a capability with no name"}
        ],
        "settings": [
          {"key":"cpa_limit","kind":"number","label":"CPA alarm","unit":"m",
           "min":0,"max":2000,"default":926,"value":500,"tab":"alarms","group":"Collision"},
          {"key":"cpa_alarm","kind":"toggle","label":"Sound the alarm",
           "default":true,"value":false,"tab":"alarms","group":"Collision"},
          {"key":"trail","kind":"number","min":0,"max":30,"default":6},
          {"key":"","kind":"number"},
          {"key":"bogus","kind":"colour"},
          {"key":"loose_text","kind":"text","default":"nope"}
        ]
      },
      {
        "id": "org.beetlebug.nmea0183", "name": "NMEA 0183", "origin": "installed",
        "live": true, "status": "{\"state\":\"degraded\",\"items\":[{\"id\":\"r1\",\"state\":\"connected\",\"detail\":\"12 msg/s\"},{\"id\":\"r2\",\"state\":\"unreachable\"}]}",
        "file_types": [".nmea", ".log"],
        "lists": [
          {"key":"connections","tab":"connections","group":"Connections",
           "footer":"One line per gateway.","add_label":"Add a gateway",
           "max_rows":8,
           "discover":[{"service":"_signalk-ws._tcp","set":{"ws":true,"port":3000,"path":"/signalk"}}],
           "item_fields":[
             {"key":"host","kind":"text","label":"Host","default":"localhost"},
             {"key":"port","kind":"number","label":"Port","min":1,"max":65535,"default":10110},
             {"key":"on","kind":"toggle","label":"On","default":true}
           ],
           "rows":[
             {"id":"r1","host":"gps.local","port":10110,"on":true},
             {"id":"r2","host":"","on":false},
             {"host":"no id here"}
           ]}
        ]
      },
      {"name":"no id, so no plugin"},
      "not even an object"
    ]})";

    PluginInfo const *Find(std::vector<PluginInfo> const &v, char const *id)
    {
        for (auto const &p : v)
            if (p.id == id)
                return &p;
        return nullptr;
    }
}

void TestPluginRegistry()
{
    Suite("lk_plugin_registry: reading");

    /* Reading "no registry" and "a registry of nothing" the same way empties
     * the pane the moment one read comes back short. */
    LK_CASE("nothing is not an empty registry");
    {
        LK_CHECK(!ReadRegistry("").has_value());
        LK_CHECK(!ReadRegistry("not json").has_value());
        LK_CHECK(!ReadRegistry("{}").has_value());        /* no "plugins" key */
        LK_CHECK(!ReadRegistry("[]").has_value());
        auto empty = ReadRegistry(R"({"plugins":[]})");
        LK_CHECK(empty.has_value());
        if (empty)
            LK_EQ(empty->size(), (size_t)0);
    }

    LK_CASE("a plugin with no id is not a plugin");
    {
        auto v = ReadRegistry(kRegistry);
        LK_CHECK(v.has_value());
        if (!v)
            return;
        LK_EQ(v->size(), (size_t)2);
    }

    LK_CASE("what the core said about each copy");
    {
        auto v = *ReadRegistry(kRegistry);
        auto const *ais = Find(v, "org.beetlebug.ais");
        LK_CHECK(ais != nullptr);
        if (ais == nullptr)
            return;
        LK_EQ(ais->name, std::string("AIS"));
        LK_EQ(ais->version, std::string("1.2.0"));
        LK_EQ(ais->origin, std::string("bundled"));
        LK_EQ(ais->live, true);
    }

    LK_CASE("a copy that names no origin is bundled, and one with no name is its id");
    {
        auto v = *ReadRegistry(R"({"plugins":[{"id":"x"}]})");
        LK_EQ(v[0].name, std::string("x"));
        LK_EQ(v[0].origin, std::string("bundled"));
        LK_EQ(v[0].live, false);
    }

    LK_CASE("capabilities, and the grants over them");
    {
        auto v = *ReadRegistry(kRegistry);
        auto const &caps = Find(v, "org.beetlebug.ais")->capabilities;
        LK_EQ(caps.size(), (size_t)2); /* the nameless one is dropped */
        LK_EQ(caps[0].cap, std::string("ais.read"));
        LK_EQ(caps[0].granted, true);
        LK_EQ(caps[1].cap, std::string("net.http"));
        LK_EQ(caps[1].granted, false);
    }

    /* A grant not stated is granted: the manifest is the ceiling, and a copy
     * the mariner has not touched runs as its manifest asked. */
    LK_CASE("a capability that says nothing about its grant is granted");
    {
        auto v = *ReadRegistry(R"({"plugins":[{"id":"x","capabilities":[{"cap":"c"}]}]})");
        LK_EQ(v[0].capabilities[0].granted, true);
    }

    LK_CASE("the file types a plugin claims");
    {
        auto v = *ReadRegistry(kRegistry);
        auto const &types = Find(v, "org.beetlebug.nmea0183")->file_types;
        LK_EQ(types.size(), (size_t)2);
        LK_EQ(types[0], std::string(".nmea"));
    }

    LK_CASE("a field the shell has no control for is skipped");
    {
        auto v = *ReadRegistry(kRegistry);
        auto const *ais = Find(v, "org.beetlebug.ais");
        /* cpa_limit, cpa_alarm and trail — not the keyless one, not the
         * unknown kind, and not the loose text field (a text field is only
         * ever a column of a list). */
        LK_EQ(ais->fields.size(), (size_t)3);
        LK_EQ(ais->fields[0].key, std::string("cpa_limit"));
        LK_EQ(ais->fields[1].key, std::string("cpa_alarm"));
        LK_EQ(ais->fields[2].key, std::string("trail"));
    }

    LK_CASE("a field's declaration, and its label falling back to its key");
    {
        auto v = *ReadRegistry(kRegistry);
        auto const &f = Find(v, "org.beetlebug.ais")->fields[0];
        LK_EQ(f.label, std::string("CPA alarm"));
        LK_EQ(f.unit, std::string("m"));
        LK_NEAR(f.min, 0, 0);
        LK_NEAR(f.max, 2000, 0);
        LK_NEAR(f.fallback, 926, 0);
        LK_CHECK(f.kind == PluginKind::Number);

        auto const &unlabelled = Find(v, "org.beetlebug.ais")->fields[2];
        LK_EQ(unlabelled.label, std::string("trail"));
    }

    /* The VALUE in force is what the core says it is, not the manifest
     * default: the mariner's setting has to survive a reload. */
    LK_CASE("the value in force, and the default behind it");
    {
        auto v = *ReadRegistry(kRegistry);
        auto const *ais = Find(v, "org.beetlebug.ais");
        LK_NEAR(ais->values.at("cpa_limit"), 500, 0);
        LK_NEAR(ais->values.at("cpa_alarm"), 0, 0); /* "value": false */
        LK_NEAR(ais->values.at("trail"), 6, 0);     /* no value; the default */
    }

    LK_CASE("fields group by section and heading, in declaration order");
    {
        auto v = *ReadRegistry(kRegistry);
        auto const &groups = Find(v, "org.beetlebug.ais")->groups;
        LK_EQ(groups.size(), (size_t)2);
        LK_EQ(groups[0].tab, std::string("alarms"));
        LK_EQ(groups[0].title, std::string("Collision"));
        LK_EQ(groups[0].fields.size(), (size_t)2); /* both alarm fields */
        /* A field that names no section lands in the core's own fallback, and
         * a group that names no heading takes the plugin's name. */
        LK_EQ(groups[1].tab, std::string(kDefaultTab));
        LK_EQ(groups[1].title, std::string("AIS"));
    }

    Suite("lk_plugin_registry: lists");

    LK_CASE("a list's declaration");
    {
        auto v = *ReadRegistry(kRegistry);
        auto const &list = Find(v, "org.beetlebug.nmea0183")->lists.at(0);
        LK_EQ(list.key, std::string("connections"));
        LK_EQ(list.tab, std::string("connections"));
        LK_EQ(list.title, std::string("Connections"));
        LK_EQ(list.footer, std::string("One line per gateway."));
        LK_EQ(list.add_label, std::string("Add a gateway"));
        LK_EQ(list.max_rows, 8);
        LK_EQ(list.item_fields.size(), (size_t)3);
    }

    LK_CASE("a list that says nothing takes the shell's own words");
    {
        auto v = *ReadRegistry(R"({"plugins":[{"id":"x","lists":[{"key":"k"}]}]})");
        auto const &list = v[0].lists.at(0);
        LK_EQ(list.empty, std::string("Nothing here yet."));
        LK_EQ(list.add_label, std::string("Add"));
        LK_EQ(list.tab, std::string(kDefaultTab));
        LK_EQ(list.title, std::string("x"));
        LK_EQ(list.max_rows, 0); /* the core did not say */
    }

    LK_CASE("a list with no key is not a list");
    {
        auto v = *ReadRegistry(R"({"plugins":[{"id":"x","lists":[{"group":"G"}]}]})");
        LK_EQ(v[0].lists.size(), (size_t)0);
    }

    /* A list with one toggle wants that toggle as its switch. */
    LK_CASE("a list with no switch named takes its first toggle");
    {
        auto v = *ReadRegistry(kRegistry);
        LK_EQ(Find(v, "org.beetlebug.nmea0183")->lists.at(0).switch_key, std::string("on"));

        auto named = *ReadRegistry(R"({"plugins":[{"id":"x","lists":[{"key":"k",
            "switch_key":"b","item_fields":[{"key":"a","kind":"toggle"},
                                            {"key":"b","kind":"toggle"}]}]}]})");
        LK_EQ(named[0].lists.at(0).switch_key, std::string("b"));

        auto none = *ReadRegistry(R"({"plugins":[{"id":"x","lists":[{"key":"k",
            "item_fields":[{"key":"a","kind":"text"}]}]}]})");
        LK_EQ(none[0].lists.at(0).switch_key, std::string(""));
    }

    LK_CASE("the rows, and their cells");
    {
        auto v = *ReadRegistry(kRegistry);
        auto const &rows = Find(v, "org.beetlebug.nmea0183")->rows.at("connections");
        LK_EQ(rows.size(), (size_t)2); /* the row with no id is not a row */
        LK_EQ(rows[0].id, std::string("r1"));
        LK_EQ(rows[0].cells.at("host").text, std::string("gps.local"));
        LK_NEAR(rows[0].cells.at("port").number, 10110, 0);
        LK_EQ(rows[0].cells.at("on").toggle, true);
    }

    /* An optional address left blank has to survive the round trip, or the
     * manifest's default reappears in the field every time. */
    LK_CASE("a cell the mariner cleared stays cleared; one never sent takes the default");
    {
        auto v = *ReadRegistry(kRegistry);
        auto const &rows = Find(v, "org.beetlebug.nmea0183")->rows.at("connections");
        LK_EQ(rows[1].cells.at("host").text, std::string(""));    /* "host": "" */
        LK_NEAR(rows[1].cells.at("port").number, 10110, 0);       /* absent: the default */
        LK_EQ(rows[1].cells.at("on").toggle, false);
    }

    LK_CASE("what to browse the network for, with the columns a find fills in");
    {
        auto v = *ReadRegistry(kRegistry);
        auto const &discover = Find(v, "org.beetlebug.nmea0183")->lists.at(0).discover;
        LK_EQ(discover.size(), (size_t)1);
        LK_EQ(discover[0].service, std::string("_signalk-ws._tcp"));
        LK_EQ(discover[0].set.size(), (size_t)3);
        LK_EQ(discover[0].set.at("ws"), std::string("true"));
        LK_EQ(discover[0].set.at("port"), std::string("3000")); /* no trailing .0 */
        LK_EQ(discover[0].set.at("path"), std::string("/signalk"));
    }

    LK_CASE("a browse with no service type is not a browse");
    {
        auto v = *ReadRegistry(R"({"plugins":[{"id":"x","lists":[{"key":"k",
            "discover":[{"set":{"a":1}}]}]}]})");
        LK_EQ(v[0].lists.at(0).discover.size(), (size_t)0);
    }

    Suite("lk_plugin_registry: writing the config");

    LK_CASE("the object the core is handed");
    {
        auto v = *ReadRegistry(kRegistry);
        LK_EQ(PluginConfigJson(*Find(v, "org.beetlebug.ais")),
              std::string(R"({"cpa_limit":500,"cpa_alarm":false,"trail":6})"));
    }

    /* A toggle goes as a JSON bool, which is the only shape the core accepts
     * for one — a 1 or a 0 is refused. */
    LK_CASE("a toggle is a bool, and a whole number carries no decimal point");
    {
        auto v = *ReadRegistry(R"({"plugins":[{"id":"x","settings":[
            {"key":"on","kind":"toggle","default":false,"value":true},
            {"key":"n","kind":"number","default":0,"value":926},
            {"key":"f","kind":"number","default":0,"value":2.5}]}]})");
        LK_EQ(PluginConfigJson(v[0]), std::string(R"({"on":true,"n":926,"f":2.5})"));
    }

    LK_CASE("a list goes as its whole array, each row keeping the id the shell gave it");
    {
        auto v = *ReadRegistry(kRegistry);
        LK_EQ(PluginConfigJson(*Find(v, "org.beetlebug.nmea0183")),
              std::string(R"({"connections":[)"
                          R"({"id":"r1","host":"gps.local","port":10110,"on":true},)"
                          R"({"id":"r2","host":"","port":10110,"on":false}]})"));
    }

    LK_CASE("a plugin with nothing declared writes an empty object");
    {
        auto v = *ReadRegistry(R"({"plugins":[{"id":"x"}]})");
        LK_EQ(PluginConfigJson(v[0]), std::string("{}"));
    }

    LK_CASE("an empty list still goes, so clearing the last row is heard");
    {
        auto v = *ReadRegistry(R"({"plugins":[{"id":"x","lists":[{"key":"k",
            "item_fields":[{"key":"h","kind":"text"}]}]}]})");
        LK_EQ(PluginConfigJson(v[0]), std::string(R"({"k":[]})"));
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

    LK_CASE("a typed host survives the round trip");
    {
        auto v = *ReadRegistry(R"({"plugins":[{"id":"x","lists":[{"key":"k",
            "item_fields":[{"key":"h","kind":"text"}],
            "rows":[{"id":"r1","h":"say \"hi\"\n"}]}]}]})");
        std::string config = PluginConfigJson(v[0]);
        LK_EQ(config, std::string(R"({"k":[{"id":"r1","h":"say \"hi\"\n"}]})"));

        /* The rows out of that config, read back as a registry: what the
         * plugin was handed is what comes back. */
        size_t open = config.find('[');
        std::string rows = config.substr(open, config.rfind(']') - open + 1);
        auto back = ReadRegistry(R"({"plugins":[{"id":"x","lists":[{"key":"k",
            "item_fields":[{"key":"h","kind":"text"}],"rows":)" +
                                 rows + R"(}]}]})");
        LK_CHECK(back.has_value());
        if (back && !(*back)[0].rows.at("k").empty())
            LK_EQ((*back)[0].rows.at("k")[0].cells.at("h").text, std::string("say \"hi\"\n"));
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
        auto v = *ReadRegistry(kRegistry);
        std::string state;
        LK_EQ(PluginStatusLine(*Find(v, "org.beetlebug.ais"), &state),
              std::string("Running \xc2\xb7 44 msg/s"));
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

    /* Which is how "Connected · 12 msg/s" finds its way to the right line. */
    LK_CASE("a row's line is found by the id the shell minted");
    {
        auto v = *ReadRegistry(kRegistry);
        auto const &nmea = *Find(v, "org.beetlebug.nmea0183");
        std::string line, state;
        LK_EQ(PluginItemStatusLine(nmea, "r1", &line, &state), true);
        LK_EQ(line, std::string("Connected \xc2\xb7 12 msg/s"));
        LK_EQ(state, std::string("connected"));

        LK_EQ(PluginItemStatusLine(nmea, "r2", &line, &state), true);
        LK_EQ(line, std::string("Unreachable")); /* no detail, just the word */
        LK_EQ(state, std::string("unreachable"));

        LK_EQ(PluginItemStatusLine(nmea, "r9", &line, &state), false);
        LK_EQ(PluginItemStatusLine(*Find(v, "org.beetlebug.ais"), "r1", &line, &state), false);
    }
}
