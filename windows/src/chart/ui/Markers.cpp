// The chart context menu and the mariner's markers. Mirrors the macOS shell
// (AppModel.openChartMenu / dropMarker / rename): every item acts on the
// POINT the menu was raised at — not the map centre, and not where the cursor
// drifts to afterwards. The core owns the markers, names each drop itself
// ("Mark 1", …) and draws them in mariner magenta; the shell adds no drawing
// and stores nothing.
#include "pch.h"
#include "MainWindow.xaml.h"

#include "lk_format.h"
#include "lk_text.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;

namespace winrt::LookoutMarine::implementation
{
    // Right-click on the water. A pinned bubble goes first: one thing at a
    // time over the chart.
    void MainWindow::ShowChartMenu(double x, double y)
    {
        if (!lk_controller_is_open(controller))
            return;
        double lon = 0, lat = 0;
        if (!lk_controller_geo_at(controller, x, y, &lon, &lat))
            return;
        CloseOverlayBubble();

        lk_marker mark{};
        bool on_marker = lk_controller_marker_at(controller, x, y, &mark) != 0;

        Controls::MenuFlyout menu;

        Controls::MenuFlyoutItem pick;
        pick.Text(L"What's Here?");
        pick.Click([this, x, y](auto &&, auto &&) { ShowPick(x, y); });
        menu.Items().Append(pick);

        if (on_marker)
        {
            Controls::MenuFlyoutItem rename;
            rename.Text(winrt::hstring{ L"Rename " } + winrt::to_hstring(mark.name) + L"…");
            uint64_t id = mark.id;
            winrt::hstring current = winrt::to_hstring(mark.name);
            rename.Click([this, id, current](auto &&, auto &&) { RenameMarkerDialog(id, current); });
            menu.Items().Append(rename);

            Controls::MenuFlyoutItem remove;
            remove.Text(winrt::hstring{ L"Remove " } + winrt::to_hstring(mark.name));
            remove.Click([this, id](auto &&, auto &&) {
                lk_controller_marker_remove(controller, id);
                UpdateReadouts(true);
            });
            menu.Items().Append(remove);
        }
        else
        {
            // Placed at once, named by the core. The drop never waits for
            // typing: a mariner drops a mark one-handed on a moving boat,
            // often to record something they have just seen.
            Controls::MenuFlyoutItem drop;
            drop.Text(L"Drop Marker");
            drop.Click([this, lon, lat](auto &&, auto &&) {
                if (lk_controller_marker_add(controller, lon, lat) == 0)
                    fprintf(stderr, "shell: marker could not be stored\n");
                UpdateReadouts(true);
            });
            menu.Items().Append(drop);
        }

        menu.Items().Append(Controls::MenuFlyoutSeparator{});

        // The point's coordinates in the mariner's own format — the one the
        // readout, the deck log and the radio all use.
        Controls::MenuFlyoutItem copy;
        copy.Text(L"Copy Position");
        copy.Click([lat, lon](auto &&, auto &&) {
            Windows::ApplicationModel::DataTransfer::DataPackage pkg;
            pkg.SetText(winrt::to_hstring(lkw::FormatCoord(lat, lon)));
            Windows::ApplicationModel::DataTransfer::Clipboard::SetContent(pkg);
        });
        menu.Items().Append(copy);

        menu.ShowAt(Root(), { (float)x, (float)y });
    }

    // Rename is the separate, unhurried action. Enter commits (the dialog's
    // primary button is the default); an EMPTY field keeps the old name — the
    // core decides that, so every shell agrees on what an emptied field means.
    fire_and_forget MainWindow::RenameMarkerDialog(uint64_t id, winrt::hstring current)
    {
        auto lifetime = get_strong();

        Controls::TextBox box;
        box.Text(current);
        box.SelectAll();
        // The core cuts at 32 characters on a character boundary; the field
        // says so up front rather than silently trimming later.
        box.MaxLength(32);

        Controls::ContentDialog dialog;
        dialog.XamlRoot(DialogRoot());
        dialog.Title(winrt::box_value(L"Rename Marker"));
        dialog.Content(box);
        dialog.PrimaryButtonText(L"Rename");
        dialog.CloseButtonText(L"Cancel");
        dialog.DefaultButton(Controls::ContentDialogButton::Primary);

        auto result = co_await dialog.ShowAsync();
        if (result != Controls::ContentDialogResult::Primary)
            co_return;
        auto name = winrt::to_string(box.Text());
        lk_controller_marker_rename(controller, id, name.c_str());
        UpdateReadouts(true);
    }
}
