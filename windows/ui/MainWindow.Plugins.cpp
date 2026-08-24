// The mariner's controls over the wasm plugins.
//
// A plugin declares a settings schema in its manifest; the core hands the whole
// registry over as JSON through lookout_plugins_json, and this turns that into
// WinUI controls. The shell knows nothing about what any plugin does — a number
// with a unit and a range, a toggle, a text box, and a list the mariner adds
// rows to, is the whole vocabulary.
//
// The mariner never meets the plugin system. A field names the SECTION of the
// settings pane it belongs in ("alarms", "vessels", "connections", …) and the
// heading it sits under, so an AIS setting reads as a chart setting that happens
// to come from a plugin. The section ids are the core's (src/plugin/host.zig,
// `Tab`), so every shell agrees.
//
// Edits auto-apply on the same 60 ms debounce the mariner settings use, through
// lookout_plugin_config_set, which the plugin handles live: no restart. They are
// saved as the config object the plugin last accepted (see lk_store.h).
//
// A LIST is a setting the mariner adds ROWS to — the NMEA connections are the
// first. The rows are the shell's: it assigns each one an id when it is added,
// keeps the id for the row's whole life, and sends the whole array on every
// edit. The plugin reports each row's state back under the same id, which is how
// "Connected · 44 msg/s" finds its way to the right line on screen.
#include "pch.h"
#include "MainWindow.xaml.h"

#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>

#include "lk_store.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace winrt::Windows::Data::Json;

namespace
{
    winrt::hstring Wide(std::string const &s) { return winrt::to_hstring(s); }

    // A number with no trailing ".0": the core takes either, and a settings line
    // in a log reads better without it.
    std::string Trimmed(double v)
    {
        if (v == std::floor(v) && std::fabs(v) < 1e15)
        {
            char buf[32];
            snprintf(buf, sizeof buf, "%lld", (long long)v);
            return buf;
        }
        char buf[32];
        snprintf(buf, sizeof buf, "%g", v);
        return buf;
    }

    // A quoted, escaped JSON string. A host name is whatever was typed.
    std::string Quoted(std::string const &s)
    {
        std::string out = "\"";
        for (unsigned char c : s)
        {
            switch (c)
            {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20)
                {
                    char esc[8];
                    snprintf(esc, sizeof esc, "\\u%04x", c);
                    out += esc;
                }
                else
                {
                    out += (char)c;
                }
            }
        }
        return out + "\"";
    }

    std::string Utf8(winrt::hstring const &h) { return winrt::to_string(h); }

    std::string Str(JsonObject const &o, wchar_t const *key, std::string const &fallback = {})
    {
        if (!o.HasKey(key))
            return fallback;
        auto v = o.GetNamedValue(key);
        if (v.ValueType() != JsonValueType::String)
            return fallback;
        return Utf8(v.GetString());
    }

    double Num(JsonObject const &o, wchar_t const *key, double fallback)
    {
        if (!o.HasKey(key))
            return fallback;
        auto v = o.GetNamedValue(key);
        return v.ValueType() == JsonValueType::Number ? v.GetNumber() : fallback;
    }

    bool Bool(JsonObject const &o, wchar_t const *key, bool fallback)
    {
        if (!o.HasKey(key))
            return fallback;
        auto v = o.GetNamedValue(key);
        return v.ValueType() == JsonValueType::Boolean ? v.GetBoolean() : fallback;
    }

    JsonArray Arr(JsonObject const &o, wchar_t const *key)
    {
        if (o.HasKey(key) && o.GetNamedValue(key).ValueType() == JsonValueType::Array)
            return o.GetNamedArray(key);
        return JsonArray{};
    }

    // The section anything that names none lands in, which is the core's own
    // fallback.
    constexpr char const *kDefaultTab = "advanced";

    // A spin step that suits the range: metres of CPA move in tens, minutes and
    // knots one at a time.
    double StepFor(lkw::PluginField const &f)
    {
        double span = f.max - f.min;
        if (span > 100)
            return 10;
        if (span > 10)
            return 1;
        return 0.5;
    }

    // The core's state words, in the mariner's language, and the brush each
    // reads in: green while it works, amber while it is trying, red when it has
    // given up, grey while it is switched off. A state this shell does not know
    // is shown as the core wrote it rather than hidden.
    std::string StateWord(std::string const &state)
    {
        if (state == "running") return "Running";
        if (state == "starting") return "Starting";
        if (state == "degraded") return "Degraded";
        if (state == "disabled") return "Disabled";
        if (state == "stopped") return "Stopped";
        if (state == "connected") return "Connected";
        if (state == "paused") return "Paused";
        if (state == "reconnecting") return "Reconnecting";
        if (state == "unreachable") return "Unreachable";
        if (state == "no_address") return "No address";
        return state;
    }

    winrt::Windows::UI::Color StateColor(std::string const &state)
    {
        if (state == "running" || state == "connected")
            return { 0xFF, 0x3F, 0xB9, 0x50 };
        if (state == "reconnecting" || state == "degraded")
            return { 0xFF, 0xE0, 0x9B, 0x2A };
        if (state == "paused" || state == "stopped" || state == "starting" || state == "disabled")
            return { 0xFF, 0x8A, 0x8A, 0x8A };
        return { 0xFF, 0xD1, 0x40, 0x38 };
    }

    // "Connected · 44 msg/s" out of a {"state":…,"detail":…} object.
    std::string Line(JsonObject const &o, std::string *out_state)
    {
        std::string state = Str(o, L"state", "running");
        std::string detail = Str(o, L"detail");
        if (out_state != nullptr)
            *out_state = state;
        return detail.empty() ? StateWord(state) : StateWord(state) + " · " + detail;
    }

    lkw::PluginField ReadField(JsonObject const &o, bool *ok)
    {
        lkw::PluginField f;
        std::string kind = Str(o, L"kind");
        f.key = Str(o, L"key");
        *ok = !f.key.empty() && (kind == "number" || kind == "toggle" || kind == "text");
        if (!*ok)
            return f;

        f.kind = kind == "toggle" ? lkw::PluginKind::Toggle
               : kind == "text"   ? lkw::PluginKind::Text
                                  : lkw::PluginKind::Number;
        f.label = Str(o, L"label", f.key);
        f.desc = Str(o, L"desc");
        f.unit = Str(o, L"unit");
        f.min = Num(o, L"min", 0);
        f.max = Num(o, L"max", 1);
        f.optional = Bool(o, L"optional", false);

        switch (f.kind)
        {
        case lkw::PluginKind::Toggle: f.fallback = Bool(o, L"default", false) ? 1 : 0; break;
        case lkw::PluginKind::Text:   f.fallback_text = Str(o, L"default"); break;
        default:                      f.fallback = Num(o, L"default", 0); break;
        }
        return f;
    }

    lkw::PluginCell ReadCell(JsonObject const &row, lkw::PluginField const &f)
    {
        lkw::PluginCell cell;
        cell.kind = f.kind;
        switch (f.kind)
        {
        case lkw::PluginKind::Toggle: cell.toggle = Bool(row, Wide(f.key).c_str(), f.fallback != 0); break;
        case lkw::PluginKind::Text:   cell.text = Str(row, Wide(f.key).c_str(), f.fallback_text); break;
        default:                      cell.number = Num(row, Wide(f.key).c_str(), f.fallback); break;
        }
        return cell;
    }
}

namespace winrt::LookoutMarine::implementation
{
    // ---- reading the registry ---------------------------------------------

    // NULL IS NOT AN EMPTY REGISTRY. lookout_plugins_json answers NULL with no
    // chart open and in a build with no plugin host; a core holding no plugins
    // answers {"plugins":[]} instead. Reading the two the same way would empty
    // the whole pane the moment one read came back short, which looks from the
    // outside like a trapping plugin taking the settings schema with it.
    bool MainWindow::ReadPluginRegistry(std::vector<lkw::PluginInfo> &out)
    {
        char *json = lk_controller_plugins_json(controller);
        if (json == nullptr)
            return false;

        JsonValue root{ nullptr };
        bool parsed = JsonValue::TryParse(winrt::to_hstring(json), root);
        free(json);
        if (!parsed || root.ValueType() != JsonValueType::Object)
            return false;

        JsonObject obj = root.GetObject();
        if (!obj.HasKey(L"plugins"))
            return false;

        for (auto const &entry : Arr(obj, L"plugins"))
        {
            if (entry.ValueType() != JsonValueType::Object)
                continue;
            JsonObject p = entry.GetObject();

            lkw::PluginInfo info;
            info.id = Str(p, L"id");
            if (info.id.empty())
                continue;
            info.name = Str(p, L"name", info.id);
            info.version = Str(p, L"version");
            info.origin = Str(p, L"origin", "bundled");
            info.live = Bool(p, L"live", false);
            info.status = Str(p, L"status");

            for (auto const &ce : Arr(p, L"capabilities"))
            {
                if (ce.ValueType() != JsonValueType::Object)
                    continue;
                JsonObject co = ce.GetObject();
                lkw::PluginCapability cap;
                cap.cap = Str(co, L"cap");
                cap.sentence = Str(co, L"sentence");
                cap.granted = Bool(co, L"granted", true);
                if (!cap.cap.empty())
                    info.capabilities.push_back(std::move(cap));
            }

            for (auto const &fe : Arr(p, L"file_types"))
                if (fe.ValueType() == JsonValueType::String)
                    info.file_types.push_back(Utf8(fe.GetString()));

            for (auto const &fe : Arr(p, L"settings"))
            {
                if (fe.ValueType() != JsonValueType::Object)
                    continue;
                JsonObject fo = fe.GetObject();
                bool ok = false;
                lkw::PluginField f = ReadField(fo, &ok);
                // A text field is only ever a column of a list; the core refuses
                // a scalar one, so there is nothing to draw for it here.
                if (!ok || f.kind == lkw::PluginKind::Text)
                    continue;

                info.values[f.key] = f.kind == lkw::PluginKind::Toggle
                                         ? (Bool(fo, L"value", f.fallback != 0) ? 1 : 0)
                                         : Num(fo, L"value", f.fallback);

                std::string tab = Str(fo, L"tab", kDefaultTab);
                std::string title = Str(fo, L"group", info.name);
                auto it = std::find_if(info.groups.begin(), info.groups.end(),
                                       [&](lkw::PluginGroup const &g) {
                                           return g.tab == tab && g.title == title;
                                       });
                if (it == info.groups.end())
                {
                    info.groups.push_back({ info.id, title, tab, { f } });
                }
                else
                {
                    it->fields.push_back(f);
                }
                info.fields.push_back(f);
            }

            for (auto const &le : Arr(p, L"lists"))
            {
                if (le.ValueType() != JsonValueType::Object)
                    continue;
                JsonObject lo = le.GetObject();

                lkw::PluginList list;
                list.plugin_id = info.id;
                list.key = Str(lo, L"key");
                if (list.key.empty())
                    continue;
                list.tab = Str(lo, L"tab", kDefaultTab);
                list.title = Str(lo, L"group", info.name);
                list.footer = Str(lo, L"footer");
                list.empty = Str(lo, L"empty", "Nothing here yet.");
                list.add_label = Str(lo, L"add_label", "Add");
                list.switch_key = Str(lo, L"switch_key");
                list.max_rows = (int)Num(lo, L"max_rows", 0);

                for (auto const &ce : Arr(lo, L"item_fields"))
                {
                    if (ce.ValueType() != JsonValueType::Object)
                        continue;
                    bool ok = false;
                    lkw::PluginField f = ReadField(ce.GetObject(), &ok);
                    if (ok)
                        list.item_fields.push_back(f);
                }

                // A list with no switch column named takes its first toggle,
                // which is what a list with one toggle wants.
                if (list.switch_key.empty())
                {
                    for (auto const &f : list.item_fields)
                    {
                        if (f.kind == lkw::PluginKind::Toggle)
                        {
                            list.switch_key = f.key;
                            break;
                        }
                    }
                }

                std::vector<lkw::PluginRow> rows;
                for (auto const &re : Arr(lo, L"rows"))
                {
                    if (re.ValueType() != JsonValueType::Object)
                        continue;
                    JsonObject ro = re.GetObject();
                    lkw::PluginRow row;
                    row.id = Str(ro, L"id");
                    if (row.id.empty())
                        continue;
                    for (auto const &f : list.item_fields)
                        row.cells[f.key] = ReadCell(ro, f);
                    rows.push_back(std::move(row));
                }

                info.rows[list.key] = std::move(rows);
                info.lists.push_back(std::move(list));
            }

            out.push_back(std::move(info));
        }
        return true;
    }

    void MainWindow::ReloadPlugins()
    {
        std::vector<lkw::PluginInfo> fresh;
        if (ReadPluginRegistry(fresh))
            plugins = std::move(fresh);
        // A read that fails leaves the last good registry on screen, which is
        // the only thing a mariner can act on.
    }

    // Only the STATUS is taken from the poll. The values and rows on screen are
    // the mariner's, and overwriting those mid-edit would fight the keyboard.
    bool MainWindow::RefreshPluginStatus()
    {
        std::vector<lkw::PluginInfo> fresh;
        if (!ReadPluginRegistry(fresh))
            return false;

        bool moved = false;
        for (auto &p : plugins)
        {
            auto it = std::find_if(fresh.begin(), fresh.end(),
                                   [&](lkw::PluginInfo const &f) { return f.id == p.id; });
            if (it == fresh.end() || (it->status == p.status && it->live == p.live))
                continue;
            p.status = it->status;
            p.live = it->live;
            moved = true;
        }
        return moved;
    }

    // ---- applying and saving ----------------------------------------------

    // `{"cpa_limit":926,"cpa_alarm":true,"connections":[…]}` — the object the
    // core takes: a toggle as a JSON bool, which is the only shape it accepts
    // for one, and a list as its whole array of rows, each carrying the id the
    // shell assigned it.
    std::string MainWindow::PluginConfigJson(lkw::PluginInfo const &p)
    {
        std::string out = "{";
        bool first = true;

        for (auto const &f : p.fields)
        {
            if (!first)
                out += ",";
            first = false;
            auto it = p.values.find(f.key);
            double v = it != p.values.end() ? it->second : f.fallback;
            out += Quoted(f.key) + ":";
            out += f.kind == lkw::PluginKind::Toggle ? (v != 0 ? "true" : "false") : Trimmed(v);
        }

        for (auto const &list : p.lists)
        {
            if (!first)
                out += ",";
            first = false;
            out += Quoted(list.key) + ":[";

            auto rows_it = p.rows.find(list.key);
            if (rows_it != p.rows.end())
            {
                bool first_row = true;
                for (auto const &row : rows_it->second)
                {
                    if (!first_row)
                        out += ",";
                    first_row = false;
                    out += "{\"id\":" + Quoted(row.id);
                    for (auto const &f : list.item_fields)
                    {
                        out += "," + Quoted(f.key) + ":";
                        auto cell = row.cells.find(f.key);
                        if (cell == row.cells.end())
                        {
                            out += f.kind == lkw::PluginKind::Toggle
                                       ? (f.fallback != 0 ? "true" : "false")
                                   : f.kind == lkw::PluginKind::Text ? Quoted(f.fallback_text)
                                                                     : Trimmed(f.fallback);
                            continue;
                        }
                        switch (f.kind)
                        {
                        case lkw::PluginKind::Toggle: out += cell->second.toggle ? "true" : "false"; break;
                        case lkw::PluginKind::Text:   out += Quoted(cell->second.text); break;
                        default:                      out += Trimmed(cell->second.number); break;
                        }
                    }
                    out += "}";
                }
            }
            out += "]";
        }
        return out + "}";
    }

    void MainWindow::SchedulePluginApply()
    {
        if (settings_loading)
            return;
        if (plugin_apply_timer == nullptr)
        {
            plugin_apply_timer = DispatcherTimer{};
            plugin_apply_timer.Interval(std::chrono::milliseconds(60));
            plugin_apply_timer.Tick([this](auto &&, auto &&) {
                plugin_apply_timer.Stop();
                for (auto const &p : plugins)
                {
                    if (p.fields.empty() && p.lists.empty())
                        continue;
                    std::string json = PluginConfigJson(p);
                    lk_controller_set_plugin_config(controller, p.id.c_str(), json.c_str());
                    lk_store_save_plugin_config(p.id.c_str(), json.c_str());
                }
            });
        }
        plugin_apply_timer.Stop();
        plugin_apply_timer.Start();
    }

    // A connection's line has to move on its own: "Reconnecting" that never
    // becomes "Connected" is how a mariner learns the address is wrong.
    //
    // A status that has not moved rebuilds nothing, and one that has moved
    // rebuilds the pane — but NOT while the mariner is in a text box. A
    // gateway that keeps flapping would otherwise take the keyboard away
    // mid-address, which is the one moment the address is being fixed. The line
    // is a second late in that case, and the rebuild happens as soon as the
    // field is left.
    void MainWindow::StartPluginStatusPoll()
    {
        if (plugin_poll_timer != nullptr)
            return;
        plugin_poll_timer = DispatcherTimer{};
        plugin_poll_timer.Interval(std::chrono::seconds(1));
        plugin_poll_timer.Tick([this](auto &&, auto &&) {
            // In place, never a page rebuild: updating a status TextBlock
            // disturbs no focus and no expander, so a mariner typing an
            // address keeps their field while the line beside it moves.
            if (RefreshPluginStatus())
                UpdatePluginStatusUi();
        });
        plugin_poll_timer.Start();
    }

    void MainWindow::StopPluginStatusPoll()
    {
        if (plugin_poll_timer == nullptr)
            return;
        plugin_poll_timer.Stop();
        plugin_poll_timer = nullptr;
    }

    // ---- the sections a plugin filed under one tab -------------------------

    bool MainWindow::PluginTabPopulated(std::string const &tab)
    {
        for (auto const &p : plugins)
        {
            for (auto const &g : p.groups)
                if (g.tab == tab)
                    return true;
            for (auto const &l : p.lists)
                if (l.tab == tab)
                    return true;
        }
        return false;
    }

    // One row of a list: what it is called and what it is doing, a switch that
    // pauses it, and — folded away until it is wanted — the address behind it.
    // The mariner reads the first line and touches nothing else most days.
    void MainWindow::BuildPluginRow(Controls::StackPanel const &stack,
                                    lkw::PluginInfo &p,
                                    lkw::PluginList const &list,
                                    std::string const &row_id)
    {
        auto rows_it = p.rows.find(list.key);
        if (rows_it == p.rows.end())
            return;
        auto row_it = std::find_if(rows_it->second.begin(), rows_it->second.end(),
                                   [&](lkw::PluginRow const &r) { return r.id == row_id; });
        if (row_it == rows_it->second.end())
            return;

        std::string plugin_id = p.id;
        std::string list_key = list.key;

        // What the mariner named it, or the address it dials.
        std::string title;
        {
            auto name = row_it->cells.find("name");
            auto host = row_it->cells.find("host");
            auto port = row_it->cells.find("port");
            if (name != row_it->cells.end() && !name->second.text.empty())
                title = name->second.text;
            else if (host != row_it->cells.end() && !host->second.text.empty())
                title = host->second.text +
                        (port != row_it->cells.end() ? ":" + Trimmed(port->second.number) : "");
            else
                title = "New connection";
        }

        Controls::Grid header;
        Controls::ColumnDefinition c0, c1;
        c0.Width({ 1, GridUnitType::Star });
        c1.Width({ 0, GridUnitType::Auto });
        header.ColumnDefinitions().ReplaceAll({ c0, c1 });
        header.Margin({ 0, 6, 0, 0 });

        Controls::StackPanel summary;
        Controls::TextBlock name_tb;
        name_tb.Text(Wide(title));
        name_tb.FontWeight(winrt::Windows::UI::Text::FontWeights::Medium());
        name_tb.TextTrimming(TextTrimming::CharacterEllipsis);
        summary.Children().Append(name_tb);

        // What the plugin says about THIS row, found by the id the shell minted.
        Controls::TextBlock status_tb;
        status_tb.FontSize(11);
        {
            std::string line, state;
            if (PluginItemStatusLine(p, row_id, &line, &state))
            {
                status_tb.Text(Wide(line));
                status_tb.Foreground(Media::SolidColorBrush{ StateColor(state) });
            }
        }
        summary.Children().Append(status_tb);
        plugin_status_ui.push_back({ p.id, row_id, status_tb, Shapes::Ellipse{ nullptr } });

        Controls::Expander expander;
        expander.Header(summary);
        expander.HorizontalAlignment(HorizontalAlignment::Stretch);
        expander.HorizontalContentAlignment(HorizontalAlignment::Stretch);
        // A row with no address cannot work yet, so it opens itself: the mariner
        // has to type one, and hunting for a chevron to find that out is not a
        // task.
        {
            auto host = row_it->cells.find("host");
            expander.IsExpanded(host == row_it->cells.end() || host->second.text.empty());
        }
        header.Children().Append(expander);

        // The row's own on/off switch stands OUTSIDE the expander, on the line
        // where it is read at a glance: pausing a connection must not need it
        // opened.
        if (!list.switch_key.empty())
        {
            auto sw_cell = row_it->cells.find(list.switch_key);
            Controls::ToggleSwitch sw;
            sw.OnContent(nullptr);
            sw.OffContent(nullptr);
            sw.MinWidth(0);
            sw.VerticalAlignment(VerticalAlignment::Center);
            sw.IsOn(sw_cell != row_it->cells.end() && sw_cell->second.toggle);
            std::string key = list.switch_key;
            sw.Toggled([this, plugin_id, list_key, row_id, key](auto &&s, auto &&) {
                if (settings_loading)
                    return;
                SetPluginCellToggle(plugin_id, list_key, row_id, key,
                                    s.template as<Controls::ToggleSwitch>().IsOn());
            });
            Controls::Grid::SetColumn(sw, 1);
            header.Children().Append(sw);
        }
        stack.Children().Append(header);

        Controls::StackPanel fields;
        fields.Spacing(6);
        fields.Margin({ 0, 4, 0, 0 });
        expander.Content(fields);

        for (auto const &f : list.item_fields)
        {
            // Every column but the one already drawn on the row's line.
            if (f.key == list.switch_key)
                continue;

            Controls::TextBlock label;
            label.Text(Wide(f.label));
            label.FontSize(12);
            fields.Children().Append(label);

            std::string key = f.key;
            switch (f.kind)
            {
            case lkw::PluginKind::Text:
            {
                Controls::TextBox box;
                auto cell = row_it->cells.find(f.key);
                box.Text(Wide(cell != row_it->cells.end() ? cell->second.text : f.fallback_text));
                if (f.optional)
                    box.PlaceholderText(L"Optional");
                /* Commits on Enter or focus loss, never per keystroke: an
                 * address pushed letter-by-letter dials "1", "10", "10.0"…
                 * and the plugin churns through partial hosts while the
                 * mariner is mid-word (the reference's CommitTextField rule). */
                auto commit = [this, plugin_id, list_key, row_id, key](Controls::TextBox const &b) {
                    if (settings_loading)
                        return;
                    SetPluginCellText(plugin_id, list_key, row_id, key,
                                      winrt::to_string(b.Text()));
                };
                box.LostFocus([commit](auto &&s, auto &&) {
                    commit(s.template as<Controls::TextBox>());
                });
                box.KeyDown([commit](auto &&s, auto &&e) {
                    if (e.Key() == Windows::System::VirtualKey::Enter)
                        commit(s.template as<Controls::TextBox>());
                });
                fields.Children().Append(box);
                break;
            }
            case lkw::PluginKind::Number:
            {
                Controls::NumberBox nb;
                auto cell = row_it->cells.find(f.key);
                nb.Value(cell != row_it->cells.end() ? cell->second.number : f.fallback);
                nb.Minimum(f.min);
                nb.Maximum(f.max);
                nb.SmallChange(StepFor(f));
                nb.SpinButtonPlacementMode(Controls::NumberBoxSpinButtonPlacementMode::Compact);
                nb.ValueChanged([this, plugin_id, list_key, row_id, key](auto &&, auto &&e) {
                    if (settings_loading || std::isnan(e.NewValue()))
                        return;
                    SetPluginCellNumber(plugin_id, list_key, row_id, key, e.NewValue());
                });
                fields.Children().Append(nb);
                break;
            }
            default:
            {
                Controls::ToggleSwitch ts;
                auto cell = row_it->cells.find(f.key);
                ts.IsOn(cell != row_it->cells.end() ? cell->second.toggle : f.fallback != 0);
                ts.Toggled([this, plugin_id, list_key, row_id, key](auto &&s, auto &&) {
                    if (settings_loading)
                        return;
                    SetPluginCellToggle(plugin_id, list_key, row_id, key,
                                        s.template as<Controls::ToggleSwitch>().IsOn());
                });
                fields.Children().Append(ts);
                break;
            }
            }

            if (!f.desc.empty())
            {
                Controls::TextBlock desc;
                desc.Text(Wide(f.desc));
                desc.FontSize(11);
                desc.Opacity(0.7);
                desc.TextWrapping(TextWrapping::Wrap);
                fields.Children().Append(desc);
            }
        }

        Controls::Button remove;
        remove.Content(winrt::box_value(L"Remove"));
        remove.Margin({ 0, 8, 0, 0 });
        remove.Click([this, plugin_id, list_key, row_id](auto &&, auto &&) {
            RemovePluginRow(plugin_id, list_key, row_id);
        });
        fields.Children().Append(remove);
    }

    void MainWindow::BuildPluginSections(std::string const &tab)
    {
        auto stack = SettingsContent();

        auto header = [&](std::string const &text) {
            Controls::TextBlock tb;
            tb.Text(Wide(text));
            tb.FontWeight(winrt::Windows::UI::Text::FontWeights::SemiBold());
            tb.Margin({ 0, 10, 0, 0 });
            stack.Children().Append(tb);
        };
        auto footnote = [&](std::string const &text) {
            Controls::TextBlock tb;
            tb.Text(Wide(text));
            tb.FontSize(11);
            tb.Opacity(0.7);
            tb.TextWrapping(TextWrapping::Wrap);
            stack.Children().Append(tb);
        };

        for (auto &p : plugins)
        {
            std::string plugin_id = p.id;

            for (auto const &group : p.groups)
            {
                if (group.tab != tab)
                    continue;
                header(group.title);

                for (auto const &f : group.fields)
                {
                    std::string key = f.key;
                    auto it = p.values.find(f.key);
                    double value = it != p.values.end() ? it->second : f.fallback;

                    if (f.kind == lkw::PluginKind::Toggle)
                    {
                        Controls::ToggleSwitch ts;
                        ts.Header(winrt::box_value(Wide(f.label)));
                        ts.IsOn(value != 0);
                        ts.Toggled([this, plugin_id, key](auto &&s, auto &&) {
                            if (settings_loading)
                                return;
                            SetPluginValue(plugin_id, key,
                                           s.template as<Controls::ToggleSwitch>().IsOn() ? 1 : 0);
                        });
                        stack.Children().Append(ts);
                    }
                    else
                    {
                        Controls::TextBlock label;
                        // The unit rides in the label, which is where the range
                        // the manifest set is legible beside what it means.
                        label.Text(Wide(f.unit.empty() ? f.label : f.label + " (" + f.unit + ")"));
                        label.FontSize(12);
                        stack.Children().Append(label);

                        Controls::NumberBox nb;
                        nb.Value(value);
                        nb.Minimum(f.min);
                        nb.Maximum(f.max);
                        nb.SmallChange(StepFor(f));
                        nb.SpinButtonPlacementMode(
                            Controls::NumberBoxSpinButtonPlacementMode::Compact);
                        nb.ValueChanged([this, plugin_id, key](auto &&, auto &&e) {
                            if (settings_loading || std::isnan(e.NewValue()))
                                return;
                            SetPluginValue(plugin_id, key, e.NewValue());
                        });
                        stack.Children().Append(nb);
                    }

                    if (!f.desc.empty())
                        footnote(f.desc);
                }

                // Reset acts on the GROUP, which is what the mariner sees:
                // resetting the collision alarm must not move the target vectors
                // in another section. It is offered only while something is off
                // its manifest default.
                bool changed = false;
                for (auto const &f : group.fields)
                {
                    auto it = p.values.find(f.key);
                    if ((it != p.values.end() ? it->second : f.fallback) != f.fallback)
                        changed = true;
                }
                if (changed)
                {
                    std::vector<std::string> keys;
                    std::vector<double> defaults;
                    for (auto const &f : group.fields)
                    {
                        keys.push_back(f.key);
                        defaults.push_back(f.fallback);
                    }
                    Controls::Button reset;
                    reset.Content(winrt::box_value(L"Reset to defaults"));
                    reset.Margin({ 0, 6, 0, 0 });
                    reset.Click([this, plugin_id, keys, defaults](auto &&, auto &&) {
                        ResetPluginGroup(plugin_id, keys, defaults);
                    });
                    stack.Children().Append(reset);
                }
            }

            for (auto const &list : p.lists)
            {
                if (list.tab != tab)
                    continue;
                header(list.title);

                std::string list_key = list.key;
                auto rows_it = p.rows.find(list.key);
                size_t count = rows_it != p.rows.end() ? rows_it->second.size() : 0;

                if (count == 0)
                {
                    footnote(list.empty);
                }
                else
                {
                    std::vector<std::string> ids;
                    for (auto const &r : rows_it->second)
                        ids.push_back(r.id);
                    for (auto const &id : ids)
                        BuildPluginRow(stack, p, list, id);
                }

                // AT THE CAP THERE IS NOTHING TO ADD: the core keeps max_rows
                // and drops the rest, so a mariner who typed a ninth gateway
                // address would be left with a row that looks like the other
                // eight and never connects.
                bool full = list.max_rows > 0 && (int)count >= list.max_rows;
                Controls::Button add;
                add.Content(winrt::box_value(Wide(list.add_label)));
                add.Margin({ 0, 8, 0, 0 });
                add.IsEnabled(!full);
                add.Click([this, plugin_id, list_key](auto &&, auto &&) {
                    AddPluginRow(plugin_id, list_key);
                });
                stack.Children().Append(add);

                if (full)
                    footnote(std::to_string(list.max_rows) +
                             " is the most this list holds. Remove one to add another.");
                // The plugin's own sentence, never the pane's. Connections holds
                // two lists — NMEA gateways and Signal K servers — and a line
                // about WiFi gateways under a list of Signal K servers sends the
                // mariner to the wrong port.
                if (!list.footer.empty())
                    footnote(list.footer);
            }
        }
    }

    // The plugin's own status line and the brush it reads in — "Stopped" for
    // a dead one whatever its last words were.
    std::string MainWindow::PluginStatusLine(lkw::PluginInfo const &p, std::string *state_out)
    {
        std::string state = "stopped";
        std::string line = "Stopped";
        if (p.live)
        {
            JsonValue st{ nullptr };
            if (!p.status.empty() && JsonValue::TryParse(Wide(p.status), st) &&
                st.ValueType() == JsonValueType::Object)
                line = Line(st.GetObject(), &state);
            else
            {
                line = "Running";
                state = "running";
            }
        }
        if (state_out != nullptr)
            *state_out = state;
        return line;
    }

    // What the plugin says about one list row, found by the id the shell
    // minted. False when the status names no such item.
    bool MainWindow::PluginItemStatusLine(lkw::PluginInfo const &p, std::string const &row_id,
                                          std::string *line_out, std::string *state_out)
    {
        JsonValue st{ nullptr };
        if (p.status.empty() || !JsonValue::TryParse(Wide(p.status), st) ||
            st.ValueType() != JsonValueType::Object)
            return false;
        for (auto const &item : Arr(st.GetObject(), L"items"))
        {
            if (item.ValueType() != JsonValueType::Object)
                continue;
            JsonObject io = item.GetObject();
            if (Str(io, L"id") != row_id)
                continue;
            std::string state;
            *line_out = Line(io, &state);
            *state_out = state;
            return true;
        }
        return false;
    }

    // The registered status texts and dots, updated in place. The status
    // moves once a second while data flows; rebuilding the page for that
    // flickered every control and reset the expanders.
    void MainWindow::UpdatePluginStatusUi()
    {
        for (auto &ui : plugin_status_ui)
        {
            lkw::PluginInfo *p = FindPlugin(ui.plugin_id);
            if (p == nullptr || ui.text == nullptr)
                continue;
            std::string line, state;
            if (ui.row_id.empty())
            {
                line = PluginStatusLine(*p, &state);
                if (p->origin == "developer")
                    line += " · developer copy";
            }
            else if (!PluginItemStatusLine(*p, ui.row_id, &line, &state))
            {
                continue;
            }
            auto text = Wide(line);
            if (ui.text.Text() != text)
                ui.text.Text(text);
            ui.text.Foreground(Media::SolidColorBrush{ StateColor(state) });
            if (ui.dot != nullptr)
                ui.dot.Fill(Media::SolidColorBrush{ StateColor(state) });
        }
    }

    // The one section that talks ABOUT plugins rather than about the chart:
    // what is installed, what each copy may do, and the way to add or remove
    // one. The plugins that ship with the app are not here — their settings
    // are filed under the mariner sections, where they read as chart
    // settings, and there is nothing to install or remove about them.
    //
    // A row wears the disclosure grammar the connection rows wear. Collapsed
    // it is a dot, a name and the live status. Open it adds the grant
    // switches in the core's own consent wording, one quiet line saying where
    // the copy came from, and Uninstall for what install wrote.
    void MainWindow::BuildPluginsPage()
    {
        auto stack = SettingsContent();

        std::vector<lkw::PluginInfo const *> managed;
        for (auto const &p : plugins)
            if (p.origin != "bundled")
                managed.push_back(&p);

        if (managed.empty())
        {
            Controls::TextBlock none;
            none.Text(L"No plugins installed.");
            none.FontSize(12);
            none.Opacity(0.7);
            stack.Children().Append(none);
        }

        for (auto const *p : managed)
        {
            std::string state;
            std::string status_line = PluginStatusLine(*p, &state);
            // The one provenance a mariner must see at rest sits where the
            // status is, not in the name.
            if (p->origin == "developer")
                status_line += " · developer copy";

            Controls::StackPanel header;
            Controls::StackPanel top;
            top.Orientation(Controls::Orientation::Horizontal);
            top.Spacing(8);
            Shapes::Ellipse dot;
            dot.Width(8);
            dot.Height(8);
            dot.Fill(Media::SolidColorBrush{ StateColor(state) });
            dot.VerticalAlignment(VerticalAlignment::Center);
            top.Children().Append(dot);
            Controls::TextBlock name;
            name.Text(Wide(p->name));
            name.FontWeight(winrt::Windows::UI::Text::FontWeights::Medium());
            name.TextTrimming(TextTrimming::CharacterEllipsis);
            top.Children().Append(name);
            header.Children().Append(top);

            Controls::TextBlock status;
            status.Text(Wide(status_line));
            status.FontSize(11);
            status.Foreground(Media::SolidColorBrush{ StateColor(state) });
            status.Margin({ 16, 0, 0, 0 });
            header.Children().Append(status);
            plugin_status_ui.push_back({ p->id, "", status, dot });

            Controls::StackPanel body;
            body.Spacing(8);

            // One toggle per capability, worded by the core so every shell
            // shows the same sentence. Flips are live: the plugin keeps
            // running and the lost call answers it -1.
            if (p->capabilities.empty())
            {
                Controls::TextBlock none;
                none.Text(L"This plugin only draws its own settings pages.");
                none.FontSize(11);
                none.Opacity(0.7);
                none.TextWrapping(TextWrapping::Wrap);
                body.Children().Append(none);
            }
            for (auto const &cap : p->capabilities)
            {
                Controls::ToggleSwitch ts;
                ts.Header(winrt::box_value(Wide(cap.sentence)));
                ts.IsOn(cap.granted);
                ts.MinWidth(0);
                std::string id = p->id, cname = cap.cap;
                ts.Toggled([this, id, cname](auto &&s, auto &&) {
                    if (settings_loading)
                        return;
                    bool on = s.template as<Controls::ToggleSwitch>().IsOn();
                    lk_controller_plugin_grant_set(controller, id.c_str(), cname.c_str(), on ? 1 : 0);
                });
                body.Children().Append(ts);
            }

            // One quiet line about the copy itself: version, where it came
            // from, and the files it reads. Everything that is not a control,
            // in one breath.
            {
                std::string about;
                auto add = [&about](std::string const &part) {
                    if (!part.empty())
                        about += (about.empty() ? "" : " · ") + part;
                };
                if (!p->version.empty())
                    add("Version " + p->version);
                add(p->origin == "developer" ? "developer copy from LOOKOUT_PLUGINS"
                                             : "installed from a plugin file");
                if (!p->file_types.empty())
                {
                    std::string types;
                    for (auto const &t : p->file_types)
                        types += (types.empty() ? "" : ", ") + t;
                    add("reads " + types + " files you open");
                }
                if (!about.empty())
                    about[0] = (char)std::toupper((unsigned char)about[0]);

                Controls::TextBlock line;
                line.Text(Wide(about));
                line.FontSize(11);
                line.Opacity(0.7);
                line.TextWrapping(TextWrapping::Wrap);
                body.Children().Append(line);
            }

            if (p->origin == "installed")
            {
                Controls::Button rm;
                rm.Content(winrt::box_value(L"Uninstall…"));
                rm.FontSize(12);
                rm.HorizontalAlignment(HorizontalAlignment::Left);
                std::string id = p->id, pname = p->name;
                rm.Click([this, id, pname](auto &&, auto &&) {
                    ConfirmUninstallPlugin(id, pname);
                });
                body.Children().Append(rm);
            }

            Controls::Expander ex;
            ex.Header(header);
            ex.Content(body);
            ex.HorizontalAlignment(HorizontalAlignment::Stretch);
            ex.HorizontalContentAlignment(HorizontalAlignment::Stretch);
            Automation::AutomationProperties::SetName(ex, Wide(p->name));
            stack.Children().Append(ex);
        }

        Controls::Button install;
        install.Content(winrt::box_value(L"Install Plugin…"));
        install.HorizontalAlignment(HorizontalAlignment::Stretch);
        install.Margin({ 0, 10, 0, 0 });
        install.Click([this](auto &&, auto &&) { PickPluginFile(); });
        stack.Children().Append(install);

        Controls::TextBlock foot;
        foot.Text(L"A plugin file (.lkplug) can also be dropped on the chart. Nothing is "
                  L"installed before its permissions are shown. Own ship, AIS, NMEA 0183 "
                  L"and Signal K ship with the app: their settings are filed with the "
                  L"chart settings they belong to, not here.");
        foot.FontSize(11);
        foot.Opacity(0.7);
        foot.TextWrapping(TextWrapping::Wrap);
        foot.Margin({ 0, 10, 0, 0 });
        stack.Children().Append(foot);
    }

    fire_and_forget MainWindow::ConfirmUninstallPlugin(std::string id, std::string name)
    {
        auto lifetime = get_strong();
        Controls::ContentDialog dialog;
        dialog.XamlRoot(DialogRoot());
        dialog.Title(winrt::box_value(Wide("Uninstall " + name + "?")));
        dialog.Content(winrt::box_value(L"Removes the plugin and everything it drew."));
        dialog.PrimaryButtonText(L"Uninstall");
        dialog.CloseButtonText(L"Cancel");
        auto result = co_await dialog.ShowAsync();
        if (result != Controls::ContentDialogResult::Primary)
            co_return;
        lk_controller_plugin_uninstall(controller, id.c_str());
        RefreshPluginTables();
        LoadSettings();
    }

    // ---- edits --------------------------------------------------------------

    lkw::PluginInfo *MainWindow::FindPlugin(std::string const &id)
    {
        auto it = std::find_if(plugins.begin(), plugins.end(),
                               [&](lkw::PluginInfo const &p) { return p.id == id; });
        return it == plugins.end() ? nullptr : &*it;
    }

    void MainWindow::SetPluginValue(std::string const &plugin_id, std::string const &key, double v)
    {
        lkw::PluginInfo *p = FindPlugin(plugin_id);
        if (p == nullptr)
            return;
        auto f = std::find_if(p->fields.begin(), p->fields.end(),
                              [&](lkw::PluginField const &x) { return x.key == key; });
        if (f == p->fields.end())
            return;

        // The core clamps too. Doing it here as well keeps the control and the
        // value it shows in step without a round trip.
        double clamped = f->kind == lkw::PluginKind::Toggle ? (v != 0 ? 1 : 0)
                                                            : (std::min)((std::max)(v, f->min), f->max);
        if (p->values[key] == clamped)
            return;
        p->values[key] = clamped;
        SchedulePluginApply();
    }

    void MainWindow::ResetPluginGroup(std::string const &plugin_id,
                                      std::vector<std::string> const &keys,
                                      std::vector<double> const &defaults)
    {
        lkw::PluginInfo *p = FindPlugin(plugin_id);
        if (p == nullptr)
            return;
        for (size_t i = 0; i < keys.size() && i < defaults.size(); ++i)
            p->values[keys[i]] = defaults[i];
        SchedulePluginApply();
        BuildSettingsPage();
    }

    lkw::PluginCell *MainWindow::FindCell(std::string const &plugin_id,
                                          std::string const &list_key,
                                          std::string const &row_id,
                                          std::string const &key)
    {
        lkw::PluginInfo *p = FindPlugin(plugin_id);
        if (p == nullptr)
            return nullptr;
        auto rows = p->rows.find(list_key);
        if (rows == p->rows.end())
            return nullptr;
        auto row = std::find_if(rows->second.begin(), rows->second.end(),
                                [&](lkw::PluginRow const &r) { return r.id == row_id; });
        if (row == rows->second.end())
            return nullptr;
        auto cell = row->cells.find(key);
        return cell == row->cells.end() ? nullptr : &cell->second;
    }

    void MainWindow::SetPluginCellText(std::string const &plugin_id, std::string const &list_key,
                                       std::string const &row_id, std::string const &key,
                                       std::string const &text)
    {
        lkw::PluginCell *cell = FindCell(plugin_id, list_key, row_id, key);
        if (cell == nullptr || cell->text == text)
            return;
        cell->text = text;
        SchedulePluginApply();
    }

    void MainWindow::SetPluginCellNumber(std::string const &plugin_id, std::string const &list_key,
                                         std::string const &row_id, std::string const &key,
                                         double value)
    {
        lkw::PluginCell *cell = FindCell(plugin_id, list_key, row_id, key);
        if (cell == nullptr || cell->number == value)
            return;
        cell->number = value;
        SchedulePluginApply();
    }

    void MainWindow::SetPluginCellToggle(std::string const &plugin_id, std::string const &list_key,
                                         std::string const &row_id, std::string const &key, bool on)
    {
        lkw::PluginCell *cell = FindCell(plugin_id, list_key, row_id, key);
        if (cell == nullptr || cell->toggle == on)
            return;
        cell->toggle = on;
        SchedulePluginApply();
    }

    void MainWindow::AddPluginRow(std::string const &plugin_id, std::string const &list_key)
    {
        lkw::PluginInfo *p = FindPlugin(plugin_id);
        if (p == nullptr)
            return;
        auto list = std::find_if(p->lists.begin(), p->lists.end(),
                                 [&](lkw::PluginList const &l) { return l.key == list_key; });
        if (list == p->lists.end())
            return;

        auto &rows = p->rows[list_key];
        if (list->max_rows > 0 && (int)rows.size() >= list->max_rows)
            return;

        // The id is minted here and never changes again: it is what the plugin's
        // status items point at, and what makes "Connected · 44 msg/s" land on
        // this line and no other.
        GUID guid{};
        (void)CoCreateGuid(&guid);
        char id[32];
        snprintf(id, sizeof id, "row-%08lx", (unsigned long)guid.Data1);

        lkw::PluginRow row;
        row.id = id;
        for (auto const &f : list->item_fields)
        {
            lkw::PluginCell cell;
            cell.kind = f.kind;
            cell.number = f.fallback;
            cell.toggle = f.fallback != 0;
            cell.text = f.fallback_text;
            row.cells[f.key] = cell;
        }
        rows.push_back(std::move(row));

        SchedulePluginApply();
        BuildSettingsPage();
    }

    void MainWindow::RemovePluginRow(std::string const &plugin_id, std::string const &list_key,
                                     std::string const &row_id)
    {
        lkw::PluginInfo *p = FindPlugin(plugin_id);
        if (p == nullptr)
            return;
        auto rows = p->rows.find(list_key);
        if (rows == p->rows.end())
            return;
        rows->second.erase(std::remove_if(rows->second.begin(), rows->second.end(),
                                          [&](lkw::PluginRow const &r) { return r.id == row_id; }),
                           rows->second.end());
        SchedulePluginApply();
        BuildSettingsPage();
    }
}
