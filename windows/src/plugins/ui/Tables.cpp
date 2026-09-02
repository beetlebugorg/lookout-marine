// Plugin tables: the AIS Targets list and whatever else a plugin declares.
//
// A declaration names a menu ("Vessels"), a title, typed columns and a default
// sort; the rows arrive already ordered by the core, band first — an alarmed
// vessel holds the top line whatever column the mariner sorted by. The shell's
// jobs are the window, the mariner's units (the plugin sends SI), and the
// open/closed mark that tells the plugin somebody is looking.
//
// One window per declaration: a second Open brings the existing one forward.
// The rows reload on a 1 s timer and rebuild only when the core's seq moves,
// else a table nobody feeds flickers once a second.
#include "pch.h"
#include "MainWindow.xaml.h"

#include <microsoft.ui.xaml.window.h> // IWindowNative, for the window's icon

#include <array>
#include <cmath>
#include <map>

#include "lk_store.h"
#include "lk_table.h"
#include "lk_format.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;

namespace lkw
{
    using winrt::Microsoft::UI::Xaml::ElementTheme;
    using winrt::Windows::UI::Color;

    /* Alarm and warning keep their colours at night: they are the one thing
     * on this window that has to mean the same in any light. */
    static constexpr Color kAlarmText{ 0xFF, 0xD1, 0x40, 0x38 };
    static constexpr Color kWarnText{ 0xFF, 0xE0, 0x9B, 0x2A };
    static constexpr Color kAlarmRow{ 0x38, 0xD1, 0x40, 0x38 };
    static constexpr Color kWarnRow{ 0x33, 0xE0, 0x9B, 0x2A };
    /* 18 % of the shell accent: the selected row, over any flag tint. */
    static constexpr Color kSelectRow{ 0x2E, 0x1B, 0x49, 0xC4 };

    /* Everything else follows the chart's scheme, out of the one palette
     * (lk_format.h) the rest of the shell draws from. */
    static Color TableInk(bool dark) { return Rgb(chrome::Ink(dark)); }
    static Color TableMuted(bool dark) { return Rgb(chrome::Muted(dark)); }
    static Color TableRule(bool dark) { return Rgb(chrome::Rule(dark)); }
    /* A cell nobody has heard is fainter than muted, either way round. */
    static Color TableFaint(bool dark) { return Rgb(dark ? 0xFF6E7C88u : 0xFF9A9A9Au); }

    Color TableGround(ElementTheme theme)
    {
        return Rgb(theme == ElementTheme::Dark ? 0xFF1B2126u : 0xFFF8F8F8u);
    }

    // The columns, the units and the row model are lk_table.h's; what is left
    // in this file is the window they are laid out in.

    // One open table window and everything it needs to reload itself. All UI
    // thread; the timer is stopped before the entry leaves the map.
    struct VesselTableWin
    {
        winrt::Microsoft::UI::Xaml::Window window{ nullptr };
        winrt::Microsoft::UI::Xaml::Controls::StackPanel rows{ nullptr };
        winrt::Microsoft::UI::Xaml::Controls::StackPanel header{ nullptr };
        winrt::Microsoft::UI::Xaml::Controls::TextBlock empty{ nullptr };
        winrt::Microsoft::UI::Xaml::DispatcherTimer timer{ nullptr };
        lk_controller *controller{ nullptr };
        winrt::LookoutMarine::implementation::MainWindow *owner{ nullptr };
        TableSpec spec;
        std::string sort_key;
        bool ascending{ true };
        long long seq{ -1 };
        /* The mariner's place in the table is theirs: kept by index across
         * the 1 s rebuilds (the core's band-stable sort keeps rows put), and
         * what Return activates. */
        int selected{ -1 };
        /* Per built row: the position a reveal centres on (when the row
         * carries one) and the flag that tints it — kept so a selection
         * change restyles in place and Return activates without re-reading
         * the core. */
        std::vector<std::array<double, 2>> row_at;
        std::vector<uint8_t> row_has_at;
        std::vector<std::string> row_flags;
    };

    /* The scheme this window is wearing, which is the chart's. */
    static bool DarkOf(VesselTableWin const *t)
    {
        return t->rows != nullptr &&
               t->rows.ActualTheme() == winrt::Microsoft::UI::Xaml::ElementTheme::Dark;
    }

    static winrt::Windows::UI::Color RowTint(VesselTableWin const *t, int idx)
    {
        if (idx == t->selected)
            return kSelectRow;
        auto const &flag = t->row_flags[(size_t)idx];
        if (flag == "alarm")
            return kAlarmRow;
        if (flag == "warning")
            return kWarnRow;
        return winrt::Windows::UI::Color{ 0, 0, 0, 0 };
    }

    /* Repaint row backgrounds in place: the selection moved, nothing else
     * did. Rows sit at even children — a hairline rule follows each. */
    static void RestyleRows(VesselTableWin *t)
    {
        auto kids = t->rows.Children();
        for (uint32_t i = 0; i * 2 < kids.Size() && i < t->row_flags.size(); ++i)
        {
            auto line = kids.GetAt(i * 2).try_as<winrt::Microsoft::UI::Xaml::Controls::Grid>();
            if (line != nullptr)
                line.Background(winrt::Microsoft::UI::Xaml::Media::SolidColorBrush{
                    RowTint(t, (int)i) });
        }
    }

    /* Open one row on the chart, the way a double-click does: centre and pin
     * its bubble. Gated exactly as the double-tap is: the declaration must
     * carry `at`, and this row must have a position somebody heard. */
    static void ActivateRow(VesselTableWin *t, int idx)
    {
        if (!t->spec.locatable || idx < 0 || (size_t)idx >= t->row_has_at.size() ||
            !t->row_has_at[(size_t)idx])
            return;
        t->owner->RevealOnChart(t->row_at[(size_t)idx][0], t->row_at[(size_t)idx][1]);
    }

    static std::wstring WinKey(std::string const &plugin, std::string const &key)
    {
        return winrt::to_hstring(plugin + "|" + key).c_str();
    }

    // Keyed by plugin|key so a second Open finds the first window.
    static std::map<std::wstring, std::shared_ptr<VesselTableWin>> g_tables;

    static void ReloadTable(VesselTableWin *t, bool force);

    static void BuildTableHeader(VesselTableWin *t)
    {
        t->header.Children().Clear();
        for (auto const &col : t->spec.columns)
        {
            Controls::Button hb;
            hb.Padding({ 6, 4, 6, 4 });
            hb.BorderThickness({ 0, 0, 0, 0 });
            hb.Background(Media::SolidColorBrush{ winrt::Windows::UI::Color{ 0, 0, 0, 0 } });
            hb.Width(ColumnWidth(col.type));
            hb.HorizontalContentAlignment(NumericColumn(col.type) ? HorizontalAlignment::Right
                                                                  : HorizontalAlignment::Left);
            Controls::TextBlock label;
            std::wstring text = winrt::to_hstring(col.label).c_str();
            if (col.key == t->sort_key)
                text += t->ascending ? L" \u25B4" : L" \u25BE";
            label.Text(text);
            label.FontSize(12);
            label.FontWeight(winrt::Windows::UI::Text::FontWeights::SemiBold());
            label.Foreground(Media::SolidColorBrush{ TableMuted(DarkOf(t)) });
            hb.Content(label);

            std::string key = col.key;
            hb.Click([t, key](auto &&, auto &&) {
                // Click the sorted column to reverse it; the core does the
                // sort, and never across a band.
                if (t->sort_key == key)
                    t->ascending = !t->ascending;
                else
                {
                    t->sort_key = key;
                    t->ascending = true;
                }
                BuildTableHeader(t);
                ReloadTable(t, true);
            });
            t->header.Children().Append(hb);
        }
    }

    static void ReloadTable(VesselTableWin *t, bool force)
    {
        lookout_table_rows *read =
            lk_controller_table_rows_read(t->controller, t->spec.plugin.c_str(),
                                          t->spec.key.c_str(), t->sort_key.c_str(),
                                          t->ascending ? 1 : 0);
        if (read == nullptr)
        {
            // The plugin has gone; the table empties rather than lying.
            if (t->seq != -1)
            {
                t->seq = -1;
                t->rows.Children().Clear();
                t->empty.Visibility(Visibility::Visible);
            }
            return;
        }

        // A batch whose seq has not moved is the same rows, and rebuilding for
        // it flickers a table nobody is feeding once a second.
        long long seq = (long long)lookout_table_rows_seq(read);
        if (!force && seq == t->seq)
        {
            lookout_table_rows_free(read);
            return;
        }
        t->seq = seq;

        std::vector<TableRow> batch_rows;
        size_t row_n = 0;
        lookout_table_row const *const *all = lookout_table_rows_all(read, &row_n);
        for (size_t i = 0; i < row_n; ++i)
        {
            size_t cell_n = 0;
            auto cells = lookout_table_row_cells(all[i], &cell_n);
            batch_rows.emplace_back(*all[i], t->spec, cells, cell_n);
        }
        lookout_table_rows_free(read);

        t->rows.Children().Clear();
        t->row_at.clear();
        t->row_has_at.clear();
        t->row_flags.clear();
        bool const dark = DarkOf(t); // one read for the whole batch
        for (auto const &row : batch_rows)
        {
            t->row_flags.push_back(row.flag);
            t->row_at.push_back({ row.lon, row.lat });
            t->row_has_at.push_back(row.has_at ? 1 : 0);
            int idx = (int)t->row_flags.size() - 1;

            Controls::Grid line;
            // A background always: a null brush is not hit-testable and the
            // row must take a tap even with nothing wrong. RowTint layers
            // the selection over the flag.
            line.Background(Media::SolidColorBrush{ RowTint(t, idx) });
            line.Tapped([t, idx](auto &&, auto &&) {
                t->selected = idx;
                RestyleRows(t);
            });

            Controls::StackPanel cellrow;
            cellrow.Orientation(Controls::Orientation::Horizontal);
            for (size_t i = 0; i < t->spec.columns.size(); ++i)
            {
                auto const &col = t->spec.columns[i];
                auto const &value = row.cells[i];

                Controls::TextBlock cell;
                cell.Text(winrt::to_hstring(value.text));
                cell.FontSize(12);
                cell.Width(ColumnWidth(col.type) - 12);
                cell.Margin({ 6, 4, 6, 4 });
                cell.TextTrimming(TextTrimming::CharacterEllipsis);
                cell.TextAlignment(NumericColumn(col.type) ? TextAlignment::Right
                                                           : TextAlignment::Left);
                auto color = value.missing ? TableFaint(dark)
                    : col.type == LOOKOUT_COLUMN_FLAG && row.flag == "alarm" ? kAlarmText
                    : col.type == LOOKOUT_COLUMN_FLAG && row.flag == "warning" ? kWarnText
                    : TableInk(dark);
                cell.Foreground(Media::SolidColorBrush{ color });
                cellrow.Children().Append(cell);
            }
            line.Children().Append(cellrow);

            // Activate a row: centre the chart on the vessel and pin its
            // bubble. Gated on the declaration carrying "at" and the row
            // carrying a position. Return takes the same path through the
            // selection (ActivateRow).
            if (row.has_at)
            {
                line.DoubleTapped([t, idx](auto &&, auto &&) {
                    t->selected = idx;
                    RestyleRows(t);
                    ActivateRow(t, idx);
                });
            }

            t->rows.Children().Append(line);

            Controls::Border rule;
            rule.Height(1);
            rule.Background(Media::SolidColorBrush{ TableRule(dark) });
            t->rows.Children().Append(rule);
        }
        // The selection survives a rebuild by index; a shrunk table clamps it
        // rather than leaving it pointing past the end.
        if (t->selected >= (int)t->row_flags.size())
            t->selected = (int)t->row_flags.size() - 1;
        t->empty.Visibility(batch_rows.empty() ? Visibility::Visible : Visibility::Collapsed);
    }
}

namespace winrt::LookoutMarine::implementation
{
    // Reveal a table row's vessel on the chart: follow comes off first, or
    // the camera snaps straight back to own ship. The symbol lands at the
    // view centre and its bubble pins there — a reveal SHOWS the vessel, not
    // merely the water it is in (the reference's reveal).
    void MainWindow::RevealOnChart(double lon, double lat)
    {
        lk_controller_follow_set(controller, 0);
        lk_controller_set_center(controller, lon, lat);
        UpdateReadouts();
        if (!TryPinOverlayAt(Root().ActualWidth() / 2, Root().ActualHeight() / 2))
            CloseOverlayBubble();
    }

    // Re-read the table declarations (at open, and when the registry moves).
    void MainWindow::RefreshPluginTables()
    {
        tables.clear();
        lookout_tables *read = lk_controller_tables_read(controller);
        if (read == nullptr)
            return;

        size_t table_n = 0;
        lookout_table const *const *all = lookout_tables_all(read, &table_n);
        for (size_t i = 0; i < table_n; ++i)
        {
            size_t col_n = 0;
            auto cols = lookout_table_columns(all[i], &col_n);
            std::vector<lkw::TableColumn> columns;
            for (size_t c = 0; c < col_n; ++c)
                columns.emplace_back(*cols[c]);
            tables.emplace_back(*all[i], std::move(columns));
        }
        lookout_tables_free(read);
    }

    void MainWindow::OpenPluginTable(lkw::TableSpec const &spec)
    {
        auto key = lkw::WinKey(spec.plugin, spec.key);
        auto found = lkw::g_tables.find(key);
        if (found != lkw::g_tables.end())
        {
            found->second->window.Activate(); // a second Open brings it forward
            return;
        }

        auto t = std::make_shared<lkw::VesselTableWin>();
        t->controller = controller;
        t->owner = this;
        t->spec = spec;
        t->sort_key = spec.sort_key;
        t->ascending = spec.sort_ascending;

        Controls::Grid root;
        // The chart's scheme, not the system's: this window sits beside the
        // chart and has to be readable in the same light. ApplyTableTheme
        // below moves it when the scheme does.
        root.RequestedTheme(ChromeTheme());
        root.Background(Media::SolidColorBrush{ lkw::TableGround(ChromeTheme()) });
        Controls::RowDefinition r0, r1;
        r0.Height({ 0, GridUnitType::Auto });
        r1.Height({ 1, GridUnitType::Star });
        root.RowDefinitions().ReplaceAll({ r0, r1 });

        t->header = Controls::StackPanel{};
        t->header.Orientation(Controls::Orientation::Horizontal);
        t->header.Padding({ 6, 6, 6, 2 });
        root.Children().Append(t->header);

        Controls::ScrollViewer scroll;
        scroll.VerticalScrollBarVisibility(Controls::ScrollBarVisibility::Auto);
        t->rows = Controls::StackPanel{};
        scroll.Content(t->rows);
        Controls::Grid::SetRow(scroll, 1);
        root.Children().Append(scroll);

        t->empty = Controls::TextBlock{};
        t->empty.Text(L"Nothing to show yet.");
        t->empty.FontSize(13);
        t->empty.Foreground(
            Media::SolidColorBrush{ lkw::TableMuted(ChromeTheme() == ElementTheme::Dark) });
        t->empty.HorizontalAlignment(HorizontalAlignment::Center);
        t->empty.VerticalAlignment(VerticalAlignment::Center);
        Controls::Grid::SetRow(t->empty, 1);
        root.Children().Append(t->empty);

        Window w;
        w.Title(winrt::to_hstring(spec.title));
        w.Content(root);
        t->window = w;

        // Where the mariner left this table is where it opens again (the
        // reference's frame autosave); first open sizes from the columns,
        // height a target list is comfortable in.
        std::string frame_key = "table-" + spec.plugin + "-" + spec.key;
        double density = Density();
        int fw = 0, fh = 0;
        if (lk_store_load_frame(frame_key.c_str(), &fw, &fh))
        {
            w.AppWindow().ResizeClient({ fw, fh });
        }
        else
        {
            double width = 90;
            for (auto const &col : spec.columns)
                width += lkw::ColumnWidth(col.type) + 4;
            width = std::min(std::max(width, 480.0), 1100.0);
            // ResizeClient counts physical pixels, so a layout width has to
            // be scaled or the window opens narrower than its own columns.
            w.AppWindow().ResizeClient({ (int32_t)(width * density), (int32_t)(420 * density) });
        }
        HWND hwnd = nullptr;
        if (auto native = w.try_as<::IWindowNative>())
            if (SUCCEEDED(native->get_WindowHandle(&hwnd)))
                ApplyWindowIcon(hwnd);

        lkw::BuildTableHeader(t.get());

        // Tell the plugin somebody is looking BEFORE the first read: it
        // builds no rows until then.
        lk_controller_table_open(controller, spec.plugin.c_str(), spec.key.c_str(), 1);
        lkw::ReloadTable(t.get(), true);

        t->timer = DispatcherTimer{};
        t->timer.Interval(std::chrono::seconds(1));
        auto raw = t.get();
        t->timer.Tick([raw](auto &&, auto &&) { lkw::ReloadTable(raw, false); });
        t->timer.Start();

        // The keyboard mirrors the mouse: Return opens the selected row the
        // way a double-click does, the arrows move the selection.
        // Accelerators, not KeyDown — a panel of plain rows holds no focus
        // for key events to route through.
        {
            Input::KeyboardAccelerator enter;
            enter.Key(Windows::System::VirtualKey::Enter);
            enter.Invoked([raw](auto &&, Input::KeyboardAcceleratorInvokedEventArgs const &e) {
                e.Handled(true);
                lkw::ActivateRow(raw, raw->selected);
            });
            root.KeyboardAccelerators().Append(enter);

            Input::KeyboardAccelerator up;
            up.Key(Windows::System::VirtualKey::Up);
            up.Invoked([raw](auto &&, Input::KeyboardAcceleratorInvokedEventArgs const &e) {
                e.Handled(true);
                if (raw->row_flags.empty())
                    return;
                raw->selected = raw->selected <= 0 ? 0 : raw->selected - 1;
                lkw::RestyleRows(raw);
            });
            root.KeyboardAccelerators().Append(up);

            Input::KeyboardAccelerator down;
            down.Key(Windows::System::VirtualKey::Down);
            down.Invoked([raw](auto &&, Input::KeyboardAcceleratorInvokedEventArgs const &e) {
                e.Handled(true);
                if (raw->row_flags.empty())
                    return;
                if (raw->selected + 1 < (int)raw->row_flags.size())
                    raw->selected++;
                else if (raw->selected < 0)
                    raw->selected = 0;
                lkw::RestyleRows(raw);
            });
            root.KeyboardAccelerators().Append(down);
        }

        w.Closed([this, key, frame_key](auto &&, auto &&) {
            auto it = lkw::g_tables.find(key);
            if (it == lkw::g_tables.end())
                return;
            // Saved once, at close: the size is not worth an INI write per
            // drag, and where it closes is where it opens next time.
            auto size = it->second->window.AppWindow().ClientSize();
            lk_store_save_frame(frame_key.c_str(), size.Width, size.Height);
            it->second->timer.Stop(); // no tick can land after this, same thread
            lk_controller_table_open(controller, it->second->spec.plugin.c_str(),
                                     it->second->spec.key.c_str(), 0);
            lkw::g_tables.erase(it);
        });

        lkw::g_tables[key] = t;
        w.Activate();
    }

    // The screenshot protocol's LOOKOUT_SHOW=table[:key[:sort[:asc|desc
    // [:activate]]]]: open one declared table — the first when no key is
    // named — sorted as a mariner would by clicking a heading, and
    // optionally with the top row opened the way a double-click does, so
    // the locate-on-chart path can be photographed.
    void MainWindow::ShowTableHook(std::string const &spec)
    {
        std::vector<std::string> parts;
        size_t at = 0;
        while (at <= spec.size())
        {
            size_t colon = spec.find(':', at);
            if (colon == std::string::npos)
            {
                parts.push_back(spec.substr(at));
                break;
            }
            parts.push_back(spec.substr(at, colon - at));
            at = colon + 1;
        }
        bool activate = !parts.empty() && parts.back() == "activate";
        std::string key = parts.size() > 1 && parts[1] != "activate" ? parts[1] : "";
        std::string sort = parts.size() > 2 && parts[2] != "activate" ? parts[2] : "";
        bool asc = !(parts.size() > 3 && parts[3] == "desc");

        lkw::TableSpec const *found = nullptr;
        for (auto const &t : tables)
            if (key.empty() || t.key == key)
            {
                found = &t;
                break;
            }
        if (found == nullptr)
        {
            fprintf(stderr, "shell: LOOKOUT_SHOW=table: no declared table%s%s\n",
                    key.empty() ? "" : " with key ", key.c_str());
            return;
        }
        OpenPluginTable(*found);
        auto wkey = lkw::WinKey(found->plugin, found->key);
        auto it = lkw::g_tables.find(wkey);
        if (it == lkw::g_tables.end())
            return;
        if (!sort.empty())
        {
            it->second->sort_key = sort;
            it->second->ascending = asc;
        }
        // The plugin builds no rows until somebody is looking, so the top
        // row can only be opened after the first batch lands. Looked up
        // again at fire time — a window closed inside the wait must not be
        // reached through a stale pointer.
        Microsoft::UI::Xaml::DispatcherTimer timer;
        timer.Interval(std::chrono::milliseconds(1000));
        std::wstring wk = wkey;
        bool act = activate;
        timer.Tick([wk, act, timer](auto &&, auto &&) {
            timer.Stop();
            auto it2 = lkw::g_tables.find(wk);
            if (it2 == lkw::g_tables.end())
                return;
            auto *t = it2->second.get();
            lkw::ReloadTable(t, true);
            if (act && !t->row_flags.empty())
            {
                t->selected = 0;
                lkw::RestyleRows(t);
                lkw::ActivateRow(t, 0);
            }
        });
        timer.Start();
    }

    // The chart's scheme moved, so these move with it: the window's own
    // ground, and then a forced reload, because every row's ink was resolved
    // when the row was built (hud/ui/Hud.cpp's ApplyChromeTheme).
    void MainWindow::ApplyTableTheme(ElementTheme want)
    {
        for (auto &[key, t] : lkw::g_tables)
        {
            if (t == nullptr || t->window == nullptr)
                continue;
            if (auto root = t->window.Content().try_as<Controls::Grid>())
            {
                root.RequestedTheme(want);
                root.Background(Media::SolidColorBrush{ lkw::TableGround(want) });
            }
            if (t->empty != nullptr)
                t->empty.Foreground(
                    Media::SolidColorBrush{ lkw::TableMuted(want == ElementTheme::Dark) });
            lkw::BuildTableHeader(t.get());
            lkw::ReloadTable(t.get(), true);
        }
    }

    // The tables belong to the chart handle: a close or re-open retires them.
    void MainWindow::CloseVesselWindows()
    {
        // Close() re-enters the Closed handler, which erases from the map —
        // walk a copy.
        auto copy = lkw::g_tables;
        for (auto &[k, t] : copy)
            t->window.Close();
        lkw::g_tables.clear();
        tables.clear();
    }
}
