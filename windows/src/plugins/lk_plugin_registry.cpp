/* lk_plugin_registry — see lk_plugin_registry.h. */
#include "lk_plugin_registry.h"

#include <algorithm>
#include <cmath>
#include <cstdio>

#include "lk_json.h"

namespace
{
    using lkw::json::Kind;
    using lkw::json::Value;

    lkw::PluginField ReadField(Value const &o, bool *ok)
    {
        lkw::PluginField f;
        std::string kind = o.MemberString("kind");
        f.key = o.MemberString("key");
        *ok = !f.key.empty() && (kind == "number" || kind == "toggle" || kind == "text");
        if (!*ok)
            return f;

        f.kind = kind == "toggle" ? lkw::PluginKind::Toggle
               : kind == "text"   ? lkw::PluginKind::Text
                                  : lkw::PluginKind::Number;
        f.label = o.MemberString("label", f.key);
        f.desc = o.MemberString("desc");
        f.unit = o.MemberString("unit");
        f.min = o.MemberNumber("min", 0);
        f.max = o.MemberNumber("max", 1);
        f.optional = o.MemberBool("optional", false);

        switch (f.kind)
        {
        case lkw::PluginKind::Toggle: f.fallback = o.MemberBool("default", false) ? 1 : 0; break;
        case lkw::PluginKind::Text:   f.fallback_text = o.MemberString("default"); break;
        default:                      f.fallback = o.MemberNumber("default", 0); break;
        }
        return f;
    }

    lkw::PluginCell ReadCell(Value const &row, lkw::PluginField const &f)
    {
        lkw::PluginCell cell;
        cell.kind = f.kind;
        switch (f.kind)
        {
        case lkw::PluginKind::Toggle:
            cell.toggle = row.MemberBool(f.key, f.fallback != 0);
            break;
        case lkw::PluginKind::Text:
        {
            /* A cell the mariner CLEARED is empty, not defaulted: an optional
             * address left blank has to survive the round trip, or the
             * manifest's default reappears in the field every time. */
            Value const &v = row.Member(f.key);
            cell.text = v.kind() == Kind::String ? v.String() : f.fallback_text;
            break;
        }
        default:
            cell.number = row.MemberNumber(f.key, f.fallback);
            break;
        }
        return cell;
    }

    /* "Connected · 44 msg/s" out of a {"state":…,"detail":…} object. */
    std::string Line(Value const &o, std::string *out_state)
    {
        std::string state = o.MemberString("state", "running");
        std::string detail = o.MemberString("detail");
        if (out_state != nullptr)
            *out_state = state;
        return detail.empty() ? lkw::StateWord(state)
                              : lkw::StateWord(state) + " \xc2\xb7 " + detail;
    }
}

namespace lkw
{
    std::string Trimmed(double v)
    {
        char buf[32];
        if (v == std::floor(v) && std::fabs(v) < 1e15)
            std::snprintf(buf, sizeof buf, "%lld", (long long)v);
        else
            std::snprintf(buf, sizeof buf, "%g", v);
        return buf;
    }

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
                    std::snprintf(esc, sizeof esc, "\\u%04x", c);
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

    double StepFor(PluginField const &f)
    {
        double span = f.max - f.min;
        if (span > 100)
            return 10;
        if (span > 10)
            return 1;
        return 0.5;
    }

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

    StateTone ToneFor(std::string const &state)
    {
        if (state == "running" || state == "connected")
            return StateTone::Good;
        if (state == "reconnecting" || state == "degraded")
            return StateTone::Trying;
        if (state == "paused" || state == "stopped" || state == "starting" || state == "disabled")
            return StateTone::Idle;
        return StateTone::Bad;
    }

    /* ---- reading the registry --------------------------------------------- */

    std::optional<std::vector<PluginInfo>> ReadRegistry(std::string_view json)
    {
        auto doc = json::Parse(json);
        if (!doc || doc->kind() != Kind::Object || !doc->Has("plugins"))
            return std::nullopt;

        std::vector<PluginInfo> out;
        for (auto const &entry : (*doc)["plugins"].Items())
        {
            if (entry.kind() != Kind::Object)
                continue;

            PluginInfo info;
            info.id = entry.MemberString("id");
            if (info.id.empty())
                continue;
            info.name = entry.MemberString("name", info.id);
            info.version = entry.MemberString("version");
            info.origin = entry.MemberString("origin", "bundled");
            info.live = entry.MemberBool("live", false);
            info.status = entry.MemberString("status");

            for (auto const &ce : entry["capabilities"].Items())
            {
                if (ce.kind() != Kind::Object)
                    continue;
                PluginCapability cap;
                cap.cap = ce.MemberString("cap");
                cap.sentence = ce.MemberString("sentence");
                cap.granted = ce.MemberBool("granted", true);
                if (!cap.cap.empty())
                    info.capabilities.push_back(std::move(cap));
            }

            for (auto const &fe : entry["file_types"].Items())
                if (fe.kind() == Kind::String)
                    info.file_types.push_back(fe.String());

            for (auto const &fo : entry["settings"].Items())
            {
                if (fo.kind() != Kind::Object)
                    continue;
                bool ok = false;
                PluginField f = ReadField(fo, &ok);
                /* A text field is only ever a column of a list; the core
                 * refuses a scalar one, so there is nothing to draw for it. */
                if (!ok || f.kind == PluginKind::Text)
                    continue;

                info.values[f.key] = f.kind == PluginKind::Toggle
                                         ? (fo.MemberBool("value", f.fallback != 0) ? 1 : 0)
                                         : fo.MemberNumber("value", f.fallback);

                std::string tab = fo.MemberString("tab", kDefaultTab);
                std::string title = fo.MemberString("group", info.name);
                auto it = std::find_if(info.groups.begin(), info.groups.end(),
                                       [&](PluginGroup const &g) {
                                           return g.tab == tab && g.title == title;
                                       });
                if (it == info.groups.end())
                    info.groups.push_back({ info.id, title, tab, { f } });
                else
                    it->fields.push_back(f);
                info.fields.push_back(f);
            }

            for (auto const &lo : entry["lists"].Items())
            {
                if (lo.kind() != Kind::Object)
                    continue;

                PluginList list;
                list.plugin_id = info.id;
                list.key = lo.MemberString("key");
                if (list.key.empty())
                    continue;
                list.tab = lo.MemberString("tab", kDefaultTab);
                list.title = lo.MemberString("group", info.name);
                list.footer = lo.MemberString("footer");
                list.empty = lo.MemberString("empty", "Nothing here yet.");
                list.add_label = lo.MemberString("add_label", "Add");
                list.switch_key = lo.MemberString("switch_key");
                list.max_rows = (int)lo.MemberNumber("max_rows", 0);

                /* What to browse the boat's network for. The core carries the
                 * declaration; finding anything is this shell's own job. */
                for (auto const &dobj : lo["discover"].Items())
                {
                    if (dobj.kind() != Kind::Object)
                        continue;
                    PluginDiscover want;
                    want.service = dobj.MemberString("service");
                    if (want.service.empty())
                        continue;
                    Value const &set = dobj["set"];
                    for (auto const &key : set.MemberNames())
                    {
                        /* Kept as text and typed again when a row takes it,
                         * which is what a cell of a row is here anyway. */
                        Value const &value = set[key];
                        switch (value.kind())
                        {
                        case Kind::Bool:   want.set[key] = value.Bool(false) ? "true" : "false"; break;
                        case Kind::String: want.set[key] = value.String(); break;
                        case Kind::Number: want.set[key] = Trimmed(value.Number(0)); break;
                        default: break;
                        }
                    }
                    list.discover.push_back(std::move(want));
                }

                for (auto const &ce : lo["item_fields"].Items())
                {
                    if (ce.kind() != Kind::Object)
                        continue;
                    bool ok = false;
                    PluginField f = ReadField(ce, &ok);
                    if (ok)
                        list.item_fields.push_back(f);
                }

                /* A list with no switch column named takes its first toggle,
                 * which is what a list with one toggle wants. */
                if (list.switch_key.empty())
                {
                    for (auto const &f : list.item_fields)
                    {
                        if (f.kind == PluginKind::Toggle)
                        {
                            list.switch_key = f.key;
                            break;
                        }
                    }
                }

                std::vector<PluginRow> rows;
                for (auto const &ro : lo["rows"].Items())
                {
                    if (ro.kind() != Kind::Object)
                        continue;
                    PluginRow row;
                    row.id = ro.MemberString("id");
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
        return out;
    }

    /* ---- writing the config ----------------------------------------------- */

    std::string PluginConfigJson(PluginInfo const &p)
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
            out += f.kind == PluginKind::Toggle ? (v != 0 ? "true" : "false") : Trimmed(v);
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
                            out += f.kind == PluginKind::Toggle
                                       ? (f.fallback != 0 ? "true" : "false")
                                   : f.kind == PluginKind::Text ? Quoted(f.fallback_text)
                                                                : Trimmed(f.fallback);
                            continue;
                        }
                        switch (f.kind)
                        {
                        case PluginKind::Toggle: out += cell->second.toggle ? "true" : "false"; break;
                        case PluginKind::Text:   out += Quoted(cell->second.text); break;
                        default:                 out += Trimmed(cell->second.number); break;
                        }
                    }
                    out += "}";
                }
            }
            out += "]";
        }
        return out + "}";
    }

    /* ---- what a plugin says about itself ----------------------------------- */

    std::string PluginStatusLine(PluginInfo const &p, std::string *state_out)
    {
        std::string state = "stopped";
        std::string line = "Stopped";
        if (p.live)
        {
            auto st = p.status.empty() ? std::nullopt : json::Parse(p.status);
            if (st && st->kind() == Kind::Object)
            {
                line = Line(*st, &state);
            }
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

    bool PluginItemStatusLine(PluginInfo const &p, std::string const &row_id,
                              std::string *line_out, std::string *state_out)
    {
        if (p.status.empty())
            return false;
        auto st = json::Parse(p.status);
        if (!st || st->kind() != Kind::Object)
            return false;
        for (auto const &item : (*st)["items"].Items())
        {
            if (item.kind() != Kind::Object || item.MemberString("id") != row_id)
                continue;
            std::string state;
            std::string line = Line(item, &state);
            if (line_out != nullptr)
                *line_out = line;
            if (state_out != nullptr)
                *state_out = state;
            return true;
        }
        return false;
    }
}
