// The development and screenshot hooks: the LOOKOUT_* environment variables
// that drive the app with nobody clicking.
//
// These are how a capture is made reproducible on any machine, and how the
// paths a mariner reaches by hand get exercised where nobody can click — an
// import, a chart set added and then removed while its own charts are still
// baking, a pick at a fixed point of the view.
//
// They belong to the app, not to the open. About a hundred lines of them
// had grown inside chart/ui/Open.cpp, which left the function that opens a
// chart mostly not about opening a chart.
//
// Every one is read ONCE, just after the first chart comes up. README.md
// lists what each does.
#include "pch.h"
#include "MainWindow.xaml.h"

#include <cstdio>
#include <cstdlib>
#include <string>

using namespace winrt;
using namespace Microsoft::UI::Xaml;

namespace winrt::LookoutMarine::implementation
{
    // Run once, from chart/ui/Open.cpp, after the first chart is up.
    void MainWindow::ApplyDevHooks()
    {
        // $LOOKOUT_WINDOW="1400x900": the client size in logical points,
        // so a screenshot frame is the same on any machine (the
        // reference's hook).
        {
            char ws[32];
            DWORD ws_n = GetEnvironmentVariableA("LOOKOUT_WINDOW", ws, sizeof ws);
            if (ws_n > 0 && ws_n < sizeof ws && ws[0] != '\0')
            {
                double w = 0, h = 0;
                if (sscanf_s(ws, "%lfx%lf", &w, &h) == 2 && w > 100 && h > 100)
                {
                    double density = Density();
                    AppWindow().ResizeClient({ (int32_t)(w * density), (int32_t)(h * density) });
                }
                else
                {
                    fprintf(stderr, "shell: ignoring malformed LOOKOUT_WINDOW '%s' (want WIDTHxHEIGHT)\n", ws);
                }
            }
        }
        // Screenshot/dev hooks: the pane, and the section it opens on.
        // LOOKOUT_OPEN_SETTINGS=1 opens Display; LOOKOUT_OPEN_SETTINGS=
        // connections opens the section a plugin filled, which is where
        // a gateway is added.
        char pane[32];
        DWORD pane_n = GetEnvironmentVariableA("LOOKOUT_OPEN_SETTINGS", pane, sizeof pane);
        if (pane_n > 0 && pane_n < sizeof pane)
        {
            std::string tab = pane;
            if (tab.empty() || tab == "1")
                ToggleSettings();
            else
                OpenSettingsTab(tab);
        }

        // Dev hooks: LOOKOUT_ADD=PATH adds that folder as a chart set
        // once the window is up — the Add Charts… panel without the
        // panel; raw cells bake, so it also drives the bake pill.
        // LOOKOUT_REMOVE=PATH takes one off, as the Charts list does;
        // "PATH@8" waits eight seconds first, which is the only way to
        // run the case that matters — a set removed while its own charts
        // are still baking (the reference's hooks, delay for delay).
        {
            char add[1024];
            DWORD add_n = GetEnvironmentVariableA("LOOKOUT_ADD", add, sizeof add);
            if (add_n > 0 && add_n < sizeof add && add[0] != '\0')
            {
                std::string path = add;
                Microsoft::UI::Xaml::DispatcherTimer timer;
                timer.Interval(std::chrono::milliseconds(2000));
                timer.Tick([this, path, timer](auto &&, auto &&) {
                    timer.Stop();
                    ImportCharts(path);
                });
                timer.Start();
            }
            char rem[1024];
            DWORD rem_n = GetEnvironmentVariableA("LOOKOUT_REMOVE", rem, sizeof rem);
            if (rem_n > 0 && rem_n < sizeof rem && rem[0] != '\0')
            {
                std::string spec = rem;
                double after = 0;
                if (size_t at2 = spec.rfind('@'); at2 != std::string::npos)
                {
                    after = atof(spec.c_str() + at2 + 1);
                    spec = spec.substr(0, at2);
                }
                Microsoft::UI::Xaml::DispatcherTimer timer;
                timer.Interval(std::chrono::milliseconds(2000 + (int64_t)(after * 1000)));
                timer.Tick([this, spec, timer](auto &&, auto &&) {
                    timer.Stop();
                    RemoveChartSet(spec);
                });
                timer.Start();
            }
        }

        // The cross-host screenshot protocol's LOOKOUT_SHOW: "pick" or
        // "pick:0.5x0.85" (a view fraction; 'x' because commas split the
        // list elsewhere), "scale",
        // "table[:key[:sort[:asc|desc[:activate]]]]", "licenses[:id]" (an
        // id opens on one component's entry) or "about". Applied after the
        // first scenes settle, like the macOS shell's 3 s delay.
        char show[64];
        DWORD show_n = GetEnvironmentVariableA("LOOKOUT_SHOW", show, sizeof show);
        if (show_n > 0 && show_n < sizeof show)
        {
            bool pick = strncmp(show, "pick", 4) == 0;
            bool scale = strcmp(show, "scale") == 0;
            bool table = strncmp(show, "table", 5) == 0;
            bool licenses = strncmp(show, "licenses", 8) == 0;
            bool about = strcmp(show, "about") == 0;
            double fx = 0.5, fy = 0.5;
            if (pick && show[4] == ':')
                sscanf_s(show + 5, "%lfx%lf", &fx, &fy);
            std::string license_id;
            if (licenses && show[8] == ':')
                license_id = show + 9;
            if (pick || scale || table || licenses || about)
            {
                std::string spec = show;
                Microsoft::UI::Xaml::DispatcherTimer timer;
                timer.Interval(std::chrono::milliseconds(3000));
                timer.Tick([this, pick, table, licenses, about, fx, fy, spec, license_id,
                            timer](auto &&, auto &&) {
                    timer.Stop();
                    if (pick)
                        ShowPick(Root().ActualWidth() * fx, Root().ActualHeight() * fy);
                    else if (table)
                        ShowTableHook(spec);
                    else if (licenses)
                        ShowLicenses(license_id);
                    else if (about)
                        ShowAbout();
                    else
                        ToggleScalePanel();
                });
                timer.Start();
            }
        }
    }
}
