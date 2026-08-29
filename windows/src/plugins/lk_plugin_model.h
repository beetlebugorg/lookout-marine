// lk_plugin_model — the shape the wasm plugin registry takes on this side.
//
// A plugin declares a settings schema in its manifest and the core hands the
// whole registry over as JSON (lookout_plugins_json); plugins/ui/PluginSettings.cpp
// parses it into these and draws a control per field. Mirrors PluginSettings.swift
// (macOS/iOS) and linux/src/lk-plugins.h.
//
// Plain structs and no WinRT: this is the model, and the pane that renders it
// is the only thing that should know about WinUI.
#pragma once

#include <map>
#include <string>
#include <vector>

namespace lkw
{
    enum class PluginKind
    {
        Number,
        Toggle,
        Text,
    };

    // One control, as the manifest declared it.
    struct PluginField
    {
        std::string key;
        std::string label;
        std::string desc; // what it does for the person at the helm; may be empty
        std::string unit; // "m", "kn", "min"; may be empty
        PluginKind kind{ PluginKind::Number };
        double min{ 0 }, max{ 1 };
        double fallback{ 0 };       // the manifest default; a toggle is 0 or 1
        std::string fallback_text;  // a text field's default; only inside a row
        bool optional{ false };     // a text field that may be left empty
    };

    // One heading's worth of controls inside one settings section — the unit the
    // pane draws, and the unit "Reset to defaults" acts on. A plugin whose schema
    // spans sections contributes one of these to each.
    struct PluginGroup
    {
        std::string plugin_id;
        std::string title; // the manifest's group, or the plugin's name
        std::string tab;   // the settings section it lands in
        std::vector<PluginField> fields;
    };

    // One DNS-SD service a connection list is browsed for. `set` is the columns
    // a discovered row takes beyond its name, address and port, as text keyed by
    // column: a Signal K server announces its websocket, so a row added from one
    // arrives with that column on.
    struct PluginDiscover
    {
        std::string service;
        std::map<std::string, std::string> set;
    };

    // A repeating group the mariner adds rows to.
    struct PluginList
    {
        std::string plugin_id;
        std::string key;
        std::string title;
        std::string tab;
        std::string footer; // the plugin's own sentence under its rows
        std::string empty;
        std::string add_label;
        std::string switch_key; // which toggle column is the row's on/off switch
        int max_rows{ 0 };      // how many rows the CORE keeps; 0 = it did not say
        std::vector<PluginField> item_fields;
        // What to browse the boat's network for on this list's behalf.
        std::vector<PluginDiscover> discover;
    };

    // One value in a row. A row is not a settings field: it holds text as well
    // as numbers and toggles.
    struct PluginCell
    {
        PluginKind kind{ PluginKind::Number };
        double number{ 0 };
        bool toggle{ false };
        std::string text;
    };

    // One row of a list. The id is the shell's and never changes once assigned:
    // the plugin echoes it in its status so each row's line finds its row.
    struct PluginRow
    {
        std::string id;
        std::map<std::string, PluginCell> cells;
    };

    // One capability the manifest asked for: the core's consent sentence, and
    // whether the mariner currently grants it. A grant can never exceed the
    // manifest, so the toggles in the Plugins section are the whole surface.
    struct PluginCapability
    {
        std::string cap;      // "ais.read", "net.http", ...
        std::string sentence; // the same words every shell shows
        bool granted{ true };
    };

    // One loaded plugin and the controls it asked for.
    struct PluginInfo
    {
        std::string id;
        std::string name;
        std::string version;
        std::string origin; // "bundled", "installed" or "developer"
        bool live{ false };
        // The plugin's own status line, {"state":…,"detail":…,"items":[…]}. The
        // Plugins section shows the line; the ITEMS go to the list rows.
        std::string status;

        std::vector<PluginField> fields;
        std::map<std::string, double> values; // the value in force, by field key
        std::vector<PluginGroup> groups;
        std::vector<PluginList> lists;
        std::map<std::string, std::vector<PluginRow>> rows; // by list key
        std::vector<PluginCapability> capabilities;
        // The file types this plugin claims, so its row can say what the open
        // panel now accepts. Empty for a plugin that opens no files.
        std::vector<std::string> file_types;
    };

    // One declared plugin table (the AIS Targets list). A column TYPE is the
    // unit contract: distance metres, speed m/s, bearing degrees true,
    // duration seconds, plus number/text/flag — the plugin sends SI and the
    // shell formats for the mariner (plugins/ui/Tables.cpp).
    struct TableColumn
    {
        std::string key;
        std::string label;
        std::string type;
    };
    struct TableSpec
    {
        std::string plugin; // owning plugin id
        std::string key;    // table key within the plugin
        std::string title;  // "AIS Targets"
        std::vector<TableColumn> columns;
        std::string sort_key;       // declared default sort
        bool sort_ascending{ true };
        bool locatable{ false }; // rows carry a position: activate centres the chart
    };
}
