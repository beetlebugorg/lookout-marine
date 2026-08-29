/* lk_plugin_registry — the wasm plugin registry, read and written.
 *
 * A plugin declares a settings schema in its manifest; the core hands the
 * whole registry over as JSON (lookout_plugins_json) and takes a config
 * object back (lookout_plugin_config_set). Between those two calls is a
 * contract with no UI in it at all: what a field is, which section it lands
 * in, what a list row carries, what the plugin's status line says. That
 * contract lives here, so it can be checked without a settings window.
 *
 * The pane that draws it is plugins/PluginSettings.cpp, and it is the only thing
 * that should know about WinUI. Model types are in lk_plugin_model.h.
 */
#pragma once

#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "lk_plugin_model.h"

namespace lkw
{
    /* NULL IS NOT AN EMPTY REGISTRY. lookout_plugins_json answers nothing with
     * no chart open and in a build with no plugin host; a core holding no
     * plugins answers {"plugins":[]} instead. Reading the two the same way
     * empties the whole pane the moment one read comes back short, which looks
     * from the outside like a trapping plugin taking the settings schema with
     * it. So: nothing when the document is not a registry, an empty vector
     * when it is a registry of nothing. */
    std::optional<std::vector<PluginInfo>> ReadRegistry(std::string_view json);

    /* The config object to hand the plugin: every scalar field by key, and
     * every list as its whole array of rows, each carrying the id the shell
     * assigned it. A toggle goes as a JSON bool, which is the only shape the
     * core accepts for one. */
    std::string PluginConfigJson(PluginInfo const &p);

    /* The section anything that names none lands in — the core's own fallback. */
    inline constexpr char const *kDefaultTab = "advanced";

    /* A spin step that suits the range: metres of CPA move in tens, minutes
     * and knots one at a time. */
    double StepFor(PluginField const &f);

    /* A number with no trailing ".0": the core takes either, and a settings
     * line in a log reads better without it. */
    std::string Trimmed(double v);

    /* A quoted, escaped JSON string. A host name is whatever was typed. */
    std::string Quoted(std::string const &s);

    /* The core's state words in the mariner's language. A state this shell
     * does not know is shown as the core wrote it rather than hidden. */
    std::string StateWord(std::string const &state);

    /* How a state reads: green while it works, amber while it is trying, grey
     * while it is switched off, red when it has given up. The colours are the
     * chrome's; which of the four a state is, is the model's. */
    enum class StateTone
    {
        Good,   /* running, connected */
        Trying, /* reconnecting, degraded */
        Idle,   /* paused, stopped, starting, disabled */
        Bad,    /* everything else, including a word this shell does not know */
    };
    StateTone ToneFor(std::string const &state);

    /* The plugin's own status line and the state behind it — "Stopped" for a
     * dead one whatever its last words were. */
    std::string PluginStatusLine(PluginInfo const &p, std::string *state_out);

    /* What the plugin says about one list row, found by the id the shell
     * minted. False when the status names no such item. */
    bool PluginItemStatusLine(PluginInfo const &p, std::string const &row_id,
                              std::string *line_out, std::string *state_out);
}
