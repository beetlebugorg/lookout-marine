/* lk_plugin_registry — see lk_plugin_registry.h. */
#include "lk_plugin_registry.h"

#include <cmath>
#include <cstdio>

#include "lk_json.h"

namespace
{
    using lkw::json::Kind;
    using lkw::json::Value;

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

    /* ---- the model, out of the core's read --------------------------------- */

    char const *SectionId(lookout_section section)
    {
        switch (section)
        {
        case LOOKOUT_SECTION_DISPLAY:     return "display";
        case LOOKOUT_SECTION_DEPTHS:      return "depths";
        case LOOKOUT_SECTION_TEXT:        return "text";
        case LOOKOUT_SECTION_CHARTS:      return "charts";
        case LOOKOUT_SECTION_VESSELS:     return "vessels";
        case LOOKOUT_SECTION_ALARMS:      return "alarms";
        case LOOKOUT_SECTION_CONNECTIONS: return "connections";
        default:                          return "advanced";
        }
    }

    PluginField::PluginField(lookout_plugin_setting const &s)
        : key{ s.key }, label{ s.label }, desc{ s.desc }, unit{ s.unit }, kind{ s.kind },
          min{ s.min }, max{ s.max }, fallback{ s.default_number },
          fallback_text{ s.default_text }, optional{ s.optional != 0 }
    {
        /* The manifest may name no label, and a control with no name on it is
         * unusable. */
        if (label.empty())
            label = key;
    }

    PluginCell::PluginCell(lookout_plugin_value const &v)
        : kind{ v.kind }, number{ v.number }, toggle{ v.number != 0 },
          text{ v.text != nullptr ? v.text : "" }
    {
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
            out += f.kind == LOOKOUT_PLUGIN_SETTING_TOGGLE ? (v != 0 ? "true" : "false") : Trimmed(v);
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
                            out += f.kind == LOOKOUT_PLUGIN_SETTING_TOGGLE
                                       ? (f.fallback != 0 ? "true" : "false")
                                   : f.kind == LOOKOUT_PLUGIN_SETTING_TEXT ? Quoted(f.fallback_text)
                                                                : Trimmed(f.fallback);
                            continue;
                        }
                        switch (f.kind)
                        {
                        case LOOKOUT_PLUGIN_SETTING_TOGGLE: out += cell->second.toggle ? "true" : "false"; break;
                        case LOOKOUT_PLUGIN_SETTING_TEXT:   out += Quoted(cell->second.text); break;
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
