// The raster underlay: the pill in the readout capsule, its menu, the add
// flow, and the re-install of the stored list at every chart open. Mirrors
// the macOS shell (HUDOverlay.swift rasterPill / AppModel.addRasterCharts).
#include "pch.h"
#include "MainWindow.xaml.h"

#include <shobjidl.h>

#include <algorithm>
#include <cwctype>
#include <filesystem>

#include "lk_paths.h"
#include "lk_store.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;

namespace
{
    // The pill reports the raster chart, never the ENC: amber only while the
    // set is switched off; hiding the ENC keeps it blue (the picture is still
    // drawn). Matches the macOS Chrome.amber / Chrome.accent.
    constexpr winrt::Windows::UI::Color kAmber{ 0xFF, 0xF5, 0x9E, 0x0B };
    constexpr winrt::Windows::UI::Color kAccent{ 0xFF, 0x1B, 0x49, 0xC4 };

    winrt::Windows::UI::Color WithAlpha(winrt::Windows::UI::Color c, double a)
    {
        c.A = (uint8_t)(a * 255.0 + 0.5);
        return c;
    }
}

namespace winrt::LookoutMarine::implementation
{
    // ---- the pill -----------------------------------------------------------

    // The pill names the set drawn over this view when one is, else the first
    // set covering the view. Naming one set and reporting the state of another
    // is how a pill comes to read "NAVIONICS | OFF" while Navionics is drawn.
    void MainWindow::UpdateRasterPill(lk_readout const &r)
    {
        int pill = -1;
        bool drawn = false;
        if (lk_controller_is_open(controller))
        {
            int count = lk_controller_raster_set_count(controller);
            int active = lk_controller_raster_active_index(controller);
            for (int i = 0; i < count; ++i)
            {
                if (!lk_controller_raster_set_in_view(controller, (unsigned)i))
                    continue;
                if (pill < 0)
                    pill = i;
                if (i == active)
                {
                    pill = i;
                    break;
                }
            }
            drawn = pill >= 0 && pill == active;
        }

        if (pill < 0)
        {
            if (!raster_pill_shown.empty())
            {
                raster_pill_shown.clear();
                RasterPillSep().Visibility(Visibility::Collapsed);
                RasterPill().Visibility(Visibility::Collapsed);
            }
            return;
        }

        char name[96];
        lk_controller_raster_set_name(controller, (unsigned)pill, name, sizeof name);
        std::wstring text = winrt::to_hstring(name).c_str();
        for (auto &c : text)
            c = (wchar_t)std::towupper(c);
        if (!drawn)
            text += L" | OFF";
        else if (r.chart_hidden)
            text += L" | ENC OFF";

        if (text == raster_pill_shown)
            return;
        raster_pill_shown = text;

        auto tint = drawn ? kAccent : kAmber;
        RasterPillText().Text(text);
        RasterPillText().Foreground(Media::SolidColorBrush{ tint });
        RasterPillChevron().Foreground(Media::SolidColorBrush{ tint });
        RasterPill().Background(Media::SolidColorBrush{ WithAlpha(tint, drawn ? 0.18 : 0.28) });
        RasterPillSep().Visibility(Visibility::Visible);
        RasterPill().Visibility(Visibility::Visible);
    }

    // The list the pill opens: every set covering this view with the drawn one
    // marked, None, the ENC switch, and the way to more charts.
    void MainWindow::ShowRasterMenu()
    {
        if (!lk_controller_is_open(controller))
            return;

        Controls::MenuFlyout menu;
        int count = lk_controller_raster_set_count(controller);
        int active = lk_controller_raster_active_index(controller);
        for (int i = 0; i < count; ++i)
        {
            if (!lk_controller_raster_set_in_view(controller, (unsigned)i))
                continue;
            char name[96];
            lk_controller_raster_set_name(controller, (unsigned)i, name, sizeof name);
            Controls::ToggleMenuFlyoutItem it;
            it.Text(winrt::to_hstring(name));
            it.IsChecked(i == active);
            it.Click([this, i](auto &&, auto &&) {
                lk_controller_raster_select(controller, i);
                SaveRasterShown();
                UpdateReadouts(true);
            });
            menu.Items().Append(it);
        }

        Controls::ToggleMenuFlyoutItem none;
        none.Text(L"None");
        none.IsChecked(active < 0);
        none.Click([this](auto &&, auto &&) {
            lk_controller_raster_select(controller, -1);
            SaveRasterShown();
            UpdateReadouts(true);
        });
        menu.Items().Append(none);

        menu.Items().Append(Controls::MenuFlyoutSeparator{});

        Controls::MenuFlyoutItem enc;
        enc.Text(lk_controller_chart_hidden(controller) ? L"Show ENC Over Raster"
                                                        : L"Hide ENC Over Raster");
        enc.Click([this](auto &&, auto &&) {
            lk_controller_toggle_chart(controller);
            lk_store_set_chart_hidden(lk_controller_chart_hidden(controller));
            UpdateReadouts(true);
        });
        menu.Items().Append(enc);

        Controls::MenuFlyoutItem add;
        add.Text(L"Add Raster Charts…");
        add.Click([this](auto &&, auto &&) { AddRasterFiles(); });
        menu.Items().Append(add);

        menu.ShowAt(RasterPill());
    }

    // Ctrl+I. With nothing installed the step means "I want a picture here" —
    // open the picker instead of doing nothing.
    void MainWindow::CycleRaster()
    {
        if (raster_paths.empty())
        {
            AddRasterFiles();
            return;
        }
        lk_controller_raster_cycle(controller);
        SaveRasterShown();
    }

    // ---- adding -------------------------------------------------------------

    void MainWindow::AddRasterPaths(std::vector<std::string> const &paths)
    {
        if (paths.empty() || !lk_controller_is_open(controller))
            return;

        /* A BSB/KAP sheet is a picture of a chart, not a chart the engine can
         * serve tiles from: it bakes first (decode and warp, tile57), and the
         * baked output comes back through this function. Ready files carry on
         * below in the same call — picking a mixed folder must add what can be
         * added and bake the rest, not fail half of it. */
        std::vector<std::string> ready;
        std::vector<std::string> sources;
        for (auto const &p : paths)
            (lkw::IsRasterSource(p) ? sources : ready).push_back(p);
        if (!sources.empty())
            BakeRasterSources(sources);
        if (ready.empty())
            return;

        std::vector<std::string> failed;
        std::vector<std::string> added;
        std::string last_added;
        for (auto const &p : ready)
        {
            if (std::find(raster_paths.begin(), raster_paths.end(), p) != raster_paths.end())
                continue;
            if (lk_controller_raster_add(controller, p.c_str()))
            {
                raster_paths.push_back(p);
                added.push_back(p);
                last_added = p;
            }
            else
            {
                failed.push_back(std::filesystem::path(p).filename().string());
            }
        }
        // One store write for the whole batch: a baked bundle is hundreds of
        // sheets, and a per-file write rewrites the settings file every time.
        if (!added.empty())
        {
            std::vector<const char *> cps;
            for (auto const &p : added)
                cps.push_back(p.c_str());
            lk_store_note_rasters(cps.data(), (int)cps.size());
        }

        // The chart just added is drawn if it covers the view: the mariner
        // picked those files while looking at this water.
        if (!last_added.empty())
        {
            std::string want = lkw::RasterSetNameFor(last_added);
            int count = lk_controller_raster_set_count(controller);
            for (int i = 0; i < count; ++i)
            {
                char name[96];
                lk_controller_raster_set_name(controller, (unsigned)i, name, sizeof name);
                if (want == name && lk_controller_raster_set_in_view(controller, (unsigned)i))
                {
                    lk_controller_raster_select(controller, i);
                    SaveRasterShown();
                    break;
                }
            }
        }

        UpdateReadouts(true);
        if (SettingsOpen())
            BuildSettingsPage();

        // One batched alert: picking a folder of twenty must not ask twenty times.
        if (failed.size() == 1)
        {
            ShowRasterError(winrt::to_hstring("Couldn't open " + failed.front() +
                                              ".\nIt may not be a raster chart tile57 reads."));
        }
        else if (!failed.empty())
        {
            std::string msg = "Couldn't open " + std::to_string(failed.size()) + " of " +
                              std::to_string(ready.size()) + " files:";
            for (auto const &f : failed)
                msg += "\n" + f;
            ShowRasterError(winrt::to_hstring(msg));
        }
    }

    fire_and_forget MainWindow::AddRasterFiles()
    {
        auto lifetime = get_strong();
        Windows::Storage::Pickers::FileOpenPicker picker;
        picker.as<::IInitializeWithWindow>()->Initialize(top_hwnd);
        // .mbtiles first as the hint; * because the extension is only a hint —
        // the engine decides, and greying out the mariner's own downloads
        // would be worse than letting it say no.
        picker.FileTypeFilter().Append(L".mbtiles");
        picker.FileTypeFilter().Append(L".pmtiles");
        // A paper chart as scanned: bakes on the way in (tile57_bake_rasters).
        picker.FileTypeFilter().Append(L".kap");
        picker.FileTypeFilter().Append(L".bsb");
        picker.FileTypeFilter().Append(L"*");
        auto files = co_await picker.PickMultipleFilesAsync();
        if (files == nullptr || files.Size() == 0)
            co_return;
        std::vector<std::string> paths;
        for (auto const &f : files)
            paths.push_back(winrt::to_string(f.Path()));
        AddRasterPaths(paths);
    }

    fire_and_forget MainWindow::AddRasterFolder()
    {
        auto lifetime = get_strong();
        Windows::Storage::Pickers::FolderPicker picker;
        picker.as<::IInitializeWithWindow>()->Initialize(top_hwnd);
        picker.FileTypeFilter().Append(L"*");
        auto folder = co_await picker.PickSingleFolderAsync();
        if (folder == nullptr)
            co_return;
        auto paths = lkw::CollectRasterCharts(winrt::to_string(folder.Path()));
        if (paths.empty())
        {
            ShowRasterError(L"No raster charts (.mbtiles, baked .pmtiles, or BSB/KAP sheets) in that folder.");
            co_return;
        }
        AddRasterPaths(paths);
    }

    fire_and_forget MainWindow::ShowRasterError(winrt::hstring msg)
    {
        auto lifetime = get_strong();
        Controls::ContentDialog dialog;
        dialog.XamlRoot(DialogRoot());
        dialog.Title(winrt::box_value(L"Raster Charts"));
        dialog.Content(winrt::box_value(msg));
        dialog.CloseButtonText(L"OK");
        co_await dialog.ShowAsync();
    }

    // ---- re-install at every open -------------------------------------------

    // A raster chart is attached to a lookout handle, and the open destroyed
    // the old one — so the stored list is installed again with every chart,
    // which is also what carries it across a restart. Failures are logged,
    // never alerted: a missing SD card must not become a dialog at every
    // launch.
    /* Forget every stored raster chart, and the per-set hidden state with it
     * (the reference's clearRasterCharts). The picture on screen is left
     * alone — the store is what the NEXT open re-installs from, and that is
     * the moment this takes effect. */
    void MainWindow::ForgetRasterCharts()
    {
        lk_store_clear_rasters();
        raster_paths.clear();
    }

    void MainWindow::InstallStoredRasters()
    {
        raster_paths.clear();
        int *enabled = nullptr;
        char **paths = lk_store_load_rasters(&enabled);
        if (paths == nullptr)
            return;

        int ok = 0, total = 0;
        for (int i = 0; paths[i] != nullptr; ++i)
        {
            std::error_code ec;
            if (!std::filesystem::exists(paths[i], ec))
                continue; // stale entry: unplugged drive, deleted download
            ++total;
            raster_paths.push_back(paths[i]);
            if (lk_controller_raster_add(controller, paths[i]))
            {
                ++ok;
                if (!enabled[i])
                    lk_controller_raster_set_enabled(controller, paths[i], 0);
            }
        }
        lk_store_free_rasters(paths, enabled);
        if (total > 0)
            fprintf(stderr, "shell: raster %d/%d source(s) re-installed\n", ok, total);
    }

    // Put back which raster sets the mariner had drawn, then the saved
    // ENC-hidden switch. Adding a source draws its set, which is right for a
    // chart just picked and wrong for one being re-installed at launch, so
    // every open has to correct it — before the first frame, or a set the
    // mariner switched off flashes on screen.
    //
    // Two passes. Hiding first and showing second is what keeps the election:
    // where two providers cover one coast, the sources were added in an order
    // that drew the first of them, so showing the mariner's pick before
    // hiding its rival would leave the rival to turn the pick straight back
    // off.
    void MainWindow::RestoreRasterShown()
    {
        raster_hidden.clear();
        if (char **names = lk_store_load_hidden_sets())
        {
            for (int i = 0; names[i] != nullptr; ++i)
                raster_hidden.insert(names[i]);
            lk_store_free_recents(names);
        }

        int count = lk_controller_raster_set_count(controller);
        if (count > 0)
        {
            char name[192];
            for (int i = 0; i < count; ++i)
            {
                lk_controller_raster_set_name(controller, (unsigned)i, name, sizeof name);
                if (raster_hidden.count(name))
                    lk_controller_raster_set_shown(controller, (unsigned)i, 0);
            }
            for (int i = 0; i < count; ++i)
            {
                lk_controller_raster_set_name(controller, (unsigned)i, name, sizeof name);
                if (!raster_hidden.count(name))
                    lk_controller_raster_set_shown(controller, (unsigned)i, 1);
            }

            // With no survey open, the imagery IS the chart, and switching a
            // set off no longer means what it meant when it was said: the
            // mariner hid it to see the ENC underneath, and obeying that now
            // leaves a blank sea. The set covering this water comes back on —
            // named in the pill and one click from off again, which a blank
            // screen is not. What they SAVED is not rewritten; add ENC charts
            // back and the set they hid is hidden again.
            if (lk_controller_charts_count(controller) == 0)
            {
                bool any_shown = false;
                int first_here = -1;
                for (int i = 0; i < count; ++i)
                {
                    if (!lk_controller_raster_set_in_view(controller, (unsigned)i))
                        continue;
                    if (first_here < 0)
                        first_here = i;
                    if (lk_controller_raster_shown(controller, (unsigned)i))
                        any_shown = true;
                }
                if (!any_shown && first_here >= 0)
                    lk_controller_raster_set_shown(controller, (unsigned)first_here, 1);
            }
        }

        if (lk_store_chart_hidden())
            lk_controller_set_chart_hidden(controller, 1);
    }

    // Record the engine's per-set drawn state, by name. Read back from the
    // engine rather than tracked here: it owns the election — showing one set
    // turns off the sets covering the same water — so what it says after the
    // change is the only account that can be right.
    void MainWindow::SaveRasterShown()
    {
        int count = lk_controller_raster_set_count(controller);
        if (count <= 0)
            return;
        auto hidden = raster_hidden;
        char name[192];
        for (int i = 0; i < count; ++i)
        {
            lk_controller_raster_set_name(controller, (unsigned)i, name, sizeof name);
            if (name[0] == '\0')
                continue;
            if (lk_controller_raster_shown(controller, (unsigned)i))
                hidden.erase(name);
            else
                hidden.insert(name);
        }
        if (hidden == raster_hidden)
            return;
        raster_hidden = std::move(hidden);
        std::vector<const char *> cps;
        for (auto const &n : raster_hidden)
            cps.push_back(n.c_str());
        lk_store_save_hidden_sets(cps.data(), (int)cps.size());
    }
}
