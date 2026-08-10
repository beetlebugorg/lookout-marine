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

#include <cmath>
#include <map>

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace winrt::Windows::Data::Json;

namespace lkw
{
    // The dash for a cell the plugin did not send: never heard and heard as
    // zero are different values.
    static constexpr wchar_t const *kMissing = L"\u2014"; /* em dash */

    static constexpr winrt::Windows::UI::Color kInk{ 0xFF, 0x1A, 0x1A, 0x1A };
    static constexpr winrt::Windows::UI::Color kMuted{ 0xFF, 0x6B, 0x6B, 0x6B };
    static constexpr winrt::Windows::UI::Color kFaint{ 0xFF, 0x9A, 0x9A, 0x9A };
    static constexpr winrt::Windows::UI::Color kRule{ 0xFF, 0xDD, 0xDD, 0xDD };
    static constexpr winrt::Windows::UI::Color kAlarmText{ 0xFF, 0xD1, 0x40, 0x38 };
    static constexpr winrt::Windows::UI::Color kWarnText{ 0xFF, 0xE0, 0x9B, 0x2A };
    static constexpr winrt::Windows::UI::Color kAlarmRow{ 0x38, 0xD1, 0x40, 0x38 };
    static constexpr winrt::Windows::UI::Color kWarnRow{ 0x33, 0xE0, 0x9B, 0x2A };

    static bool NumericColumn(std::string const &type)
    {
        return type != "text" && type != "flag";
    }

    static double ColumnWidth(std::string const &type)
    {
        return type == "text" ? 150.0 : 84.0;
    }

    // The units are the shell's: the plugin sends SI and a table converts for
    // the mariner — the reverse of the pick report, which arrives formatted.
    static std::wstring FormatCell(std::string const &type, IJsonValue const &v)
    {
        if (v == nullptr || v.ValueType() == JsonValueType::Null)
            return kMissing;

        wchar_t buf[48];
        if (type == "text" || type == "flag")
        {
            std::wstring s{ v.ValueType() == JsonValueType::String ? v.GetString() : L"" };
            if (type == "flag")
                for (auto &c : s)
                    c = (wchar_t)std::towupper(c);
            return s;
        }

        double n = v.ValueType() == JsonValueType::Number ? v.GetNumber() : 0.0;
        if (type == "distance")
        {
            if (n < 185.2)
                swprintf_s(buf, L"%.0f m", n);
            else
                swprintf_s(buf, L"%.2f nm", n / 1852.0);
        }
        else if (type == "speed")
        {
            swprintf_s(buf, L"%.1f kn", n * 3600.0 / 1852.0);
        }
        else if (type == "bearing")
        {
            double b = std::fmod(n, 360.0);
            if (b < 0)
                b += 360.0;
            swprintf_s(buf, L"%03.0f\u00B0", b);
        }
        else if (type == "duration")
        {
            long long t = (long long)std::llround(std::fabs(n));
            wchar_t const *sign = n < 0 ? L"-" : L"";
            if (t >= 3600)
                swprintf_s(buf, L"%s%lld:%02lld:%02lld", sign, t / 3600, (t / 60) % 60, t % 60);
            else
                swprintf_s(buf, L"%s%lld:%02lld", sign, t / 60, t % 60);
        }
        else
        {
            swprintf_s(buf, L"%g", n);
        }
        return buf;
    }

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
    };

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
            label.Foreground(Media::SolidColorBrush{ kMuted });
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
        char *json = lk_controller_table_rows(t->controller, t->spec.plugin.c_str(),
                                              t->spec.key.c_str(), t->sort_key.c_str(),
                                              t->ascending ? 1 : 0);
        if (json == nullptr)
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

        try
        {
            auto root = JsonObject::Parse(winrt::to_hstring(json));
            long long seq = (long long)root.GetNamedNumber(L"seq", 0);
            if (!force && seq == t->seq)
            {
                free(json);
                return;
            }
            t->seq = seq;

            t->rows.Children().Clear();
            auto arr = root.GetNamedArray(L"rows", JsonArray{});
            for (auto const &rv : arr)
            {
                auto row = rv.GetObject();
                auto cells = row.GetNamedArray(L"cells", JsonArray{});

                // The flag cell tints the whole row.
                std::wstring flag;
                for (uint32_t i = 0; i < cells.Size() && i < t->spec.columns.size(); ++i)
                    if (t->spec.columns[i].type == "flag" &&
                        cells.GetAt(i).ValueType() == JsonValueType::String)
                        flag = cells.GetAt(i).GetString();

                Controls::Grid line;
                // A background always: a null brush is not hit-testable and
                // the row must take a double-tap even with nothing wrong.
                if (flag == L"alarm")
                    line.Background(Media::SolidColorBrush{ kAlarmRow });
                else if (flag == L"warning")
                    line.Background(Media::SolidColorBrush{ kWarnRow });
                else
                    line.Background(Media::SolidColorBrush{ winrt::Windows::UI::Color{ 0, 0, 0, 0 } });

                Controls::StackPanel cellrow;
                cellrow.Orientation(Controls::Orientation::Horizontal);
                for (uint32_t i = 0; i < (uint32_t)t->spec.columns.size(); ++i)
                {
                    auto const &col = t->spec.columns[i];
                    IJsonValue v = i < cells.Size() ? cells.GetAt(i) : nullptr;
                    bool missing = v == nullptr || v.ValueType() == JsonValueType::Null;

                    Controls::TextBlock cell;
                    cell.Text(FormatCell(col.type, v));
                    cell.FontSize(12);
                    cell.Width(ColumnWidth(col.type) - 12);
                    cell.Margin({ 6, 4, 6, 4 });
                    cell.TextTrimming(TextTrimming::CharacterEllipsis);
                    cell.TextAlignment(NumericColumn(col.type) ? TextAlignment::Right
                                                               : TextAlignment::Left);
                    auto color = missing ? kFaint
                        : col.type == "flag" && flag == L"alarm" ? kAlarmText
                        : col.type == "flag" && flag == L"warning" ? kWarnText
                        : kInk;
                    cell.Foreground(Media::SolidColorBrush{ color });
                    cellrow.Children().Append(cell);
                }
                line.Children().Append(cellrow);

                // Activate a row: centre the chart on the vessel. Gated on the
                // declaration carrying "at" and the row carrying a position.
                if (t->spec.locatable && row.HasKey(L"at"))
                {
                    auto at = row.GetNamedArray(L"at", JsonArray{});
                    if (at.Size() >= 2)
                    {
                        double lon = at.GetAt(0).GetNumber();
                        double lat = at.GetAt(1).GetNumber();
                        line.DoubleTapped([t, lon, lat](auto &&, auto &&) {
                            t->owner->RevealOnChart(lon, lat);
                        });
                    }
                }

                t->rows.Children().Append(line);

                Controls::Border rule;
                rule.Height(1);
                rule.Background(Media::SolidColorBrush{ kRule });
                t->rows.Children().Append(rule);
            }
            t->empty.Visibility(arr.Size() == 0 ? Visibility::Visible : Visibility::Collapsed);
        }
        catch (winrt::hresult_error const &)
        {
            // A malformed batch changes nothing; the next second answers again.
        }
        free(json);
    }
}

namespace winrt::LookoutMarine::implementation
{
    // Reveal a table row's vessel on the chart: follow comes off first, or
    // the camera snaps straight back to own ship.
    void MainWindow::RevealOnChart(double lon, double lat)
    {
        lk_controller_follow_set(controller, 0);
        lk_controller_set_center(controller, lon, lat);
        UpdateReadouts(true);
    }

    // Re-read the table declarations (at open, and when the registry moves).
    void MainWindow::RefreshPluginTables()
    {
        tables.clear();
        char *json = lk_controller_tables_json(controller);
        if (json != nullptr)
        {
            try
            {
                auto root = JsonObject::Parse(winrt::to_hstring(json));
                auto arr = root.GetNamedArray(L"tables", JsonArray{});
                for (auto const &tv : arr)
                {
                    auto o = tv.GetObject();
                    lkw::TableSpec spec;
                    spec.plugin = winrt::to_string(o.GetNamedString(L"plugin", L""));
                    spec.key = winrt::to_string(o.GetNamedString(L"key", L""));
                    spec.title = winrt::to_string(o.GetNamedString(L"title", L""));
                    spec.locatable = o.HasKey(L"at");
                    if (auto sort = o.TryLookup(L"sort"); sort && sort.ValueType() == JsonValueType::Object)
                    {
                        auto so = sort.GetObject();
                        spec.sort_key = winrt::to_string(so.GetNamedString(L"key", L""));
                        spec.sort_ascending = so.GetNamedBoolean(L"ascending", true);
                    }
                    auto cols = o.GetNamedArray(L"columns", JsonArray{});
                    for (auto const &cv : cols)
                    {
                        auto co = cv.GetObject();
                        lkw::TableColumn col;
                        col.key = winrt::to_string(co.GetNamedString(L"key", L""));
                        col.label = winrt::to_string(co.GetNamedString(L"label", L""));
                        col.type = winrt::to_string(co.GetNamedString(L"type", L"text"));
                        spec.columns.push_back(std::move(col));
                    }
                    tables.push_back(std::move(spec));
                }
            }
            catch (winrt::hresult_error const &)
            {
            }
            free(json);
        }
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
        root.Background(Media::SolidColorBrush{ winrt::Windows::UI::Color{ 0xFF, 0xF8, 0xF8, 0xF8 } });
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
        t->empty.Foreground(Media::SolidColorBrush{ lkw::kMuted });
        t->empty.HorizontalAlignment(HorizontalAlignment::Center);
        t->empty.VerticalAlignment(VerticalAlignment::Center);
        Controls::Grid::SetRow(t->empty, 1);
        root.Children().Append(t->empty);

        Window w;
        w.Title(winrt::to_hstring(spec.title));
        w.Content(root);
        t->window = w;

        // Width from the columns, height a target list is comfortable in.
        double width = 90;
        for (auto const &col : spec.columns)
            width += lkw::ColumnWidth(col.type) + 4;
        width = std::min(std::max(width, 480.0), 1100.0);
        // ResizeClient counts physical pixels, so a layout width has to be
        // scaled or the window opens narrower than its own columns.
        double density = Density();
        w.AppWindow().ResizeClient({ (int32_t)(width * density), (int32_t)(420 * density) });
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

        w.Closed([this, key](auto &&, auto &&) {
            auto it = lkw::g_tables.find(key);
            if (it == lkw::g_tables.end())
                return;
            it->second->timer.Stop(); // no tick can land after this, same thread
            lk_controller_table_open(controller, it->second->spec.plugin.c_str(),
                                     it->second->spec.key.c_str(), 0);
            lkw::g_tables.erase(it);
        });

        lkw::g_tables[key] = t;
        w.Activate();
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
