// The About window and the licenses screen.
//
// lookout_licenses_json carries the list, baked in from
// vendor/licenses/licenses.json, so nothing here needs a connection.
//
// Search and the group headings appear above twelve entries and not below:
// under that the headings outnumber the rows.
//
// A license text is never truncated or reflowed by anything but the width of
// the view. The app's own entry is not a component and stays out of the count.
#include "pch.h"
#include "MainWindow.xaml.h"

#include <microsoft.ui.xaml.window.h> // IWindowNative, for the window's icon

#include <algorithm>
#include <cctype>

#include "lk_format.h"
#include "lk_licenses.h"
#include "resource.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using lkw::Brush;
using namespace lkw::chrome;

namespace
{
    // The chart engine is the one component a mariner may be asked which copy
    // of they are sailing on, so About states its pin.
    constexpr char const *kEngineId = "tile57";

    // A license runs to 80 columns, so its text is read in a monospaced face.
    constexpr wchar_t const *kMono = L"Cascadia Mono, Consolas, Courier New";

    hstring H(std::string const &s) { return winrt::to_hstring(s); }

    std::string Upper(std::string s)
    {
        for (auto &c : s)
            c = (char)std::toupper((unsigned char)c);
        return s;
    }

    bool Contains(std::string const &haystack, std::string const &needle)
    {
        auto it = std::search(haystack.begin(), haystack.end(), needle.begin(), needle.end(),
                              [](char a, char b) {
                                  return std::tolower((unsigned char)a) ==
                                         std::tolower((unsigned char)b);
                              });
        return it != haystack.end();
    }

    // The app's own mark, from the ICON resource the .rc links in. The 256
    // frame is packed as PNG (see assets/brand/mkico.py), which is the one a
    // BitmapImage takes straight; a DIB frame is left alone and About simply
    // shows no picture.
    std::vector<uint8_t> AppIconPng()
    {
#pragma pack(push, 2)
        struct GrpDir
        {
            uint16_t reserved, type, count;
        };
        struct GrpEntry
        {
            uint8_t width, height, colors, reserved;
            uint16_t planes, bits;
            uint32_t bytes;
            uint16_t id;
        };
#pragma pack(pop)

        HMODULE self = ::GetModuleHandleW(nullptr);
        HRSRC group = ::FindResourceW(self, MAKEINTRESOURCEW(IDI_APPICON), RT_GROUP_ICON);
        if (group == nullptr)
            return {};
        HGLOBAL group_loaded = ::LoadResource(self, group);
        if (group_loaded == nullptr)
            return {};
        auto const *dir = static_cast<GrpDir const *>(::LockResource(group_loaded));
        if (dir == nullptr || dir->count == 0)
            return {};
        auto const *entries = reinterpret_cast<GrpEntry const *>(dir + 1);

        // The biggest frame. A zero width in the directory means 256.
        int best = 0, best_px = 0;
        for (int i = 0; i < (int)dir->count; ++i)
        {
            int px = entries[i].width == 0 ? 256 : entries[i].width;
            if (px > best_px)
            {
                best_px = px;
                best = i;
            }
        }

        HRSRC frame = ::FindResourceW(self, MAKEINTRESOURCEW(entries[best].id), RT_ICON);
        if (frame == nullptr)
            return {};
        HGLOBAL frame_loaded = ::LoadResource(self, frame);
        if (frame_loaded == nullptr)
            return {};
        auto const *bytes = static_cast<uint8_t const *>(::LockResource(frame_loaded));
        DWORD size = ::SizeofResource(self, frame);
        static constexpr uint8_t kPng[8] = { 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };
        if (bytes == nullptr || size < sizeof kPng || memcmp(bytes, kPng, sizeof kPng) != 0)
            return {};
        return { bytes, bytes + size };
    }
}

namespace winrt::LookoutMarine::implementation
{
    // ---- the pieces a detail pane is built from ----------------------------

    // A card: the shade the settings pane's own rows sit on.
    Controls::Border MainWindow::LicenseCard(UIElement const &child)
    {
        Controls::Border card;
        card.CornerRadius({ 8, 8, 8, 8 });
        card.Padding({ 12, 8, 12, 8 });
        card.Background(Brush(DarkChrome() ? 0x14FFFFFFu : 0x0A000000u));
        card.Child(child);
        return card;
    }

    // The label-and-value rows. A commit, a path or a version is monospaced
    // and selectable.
    Controls::Border MainWindow::LicenseFacts(std::vector<LicenseFact> const &rows)
    {
        Controls::StackPanel stack;
        for (size_t i = 0; i < rows.size(); ++i)
        {
            if (i > 0)
            {
                Controls::Border rule;
                rule.Height(1);
                rule.Background(Brush(Rule(DarkChrome())));
                stack.Children().Append(rule);
            }

            Controls::Grid row;
            Controls::ColumnDefinition c0, c1;
            c0.Width({ 92, GridUnitType::Pixel });
            c1.Width({ 1, GridUnitType::Star });
            row.ColumnDefinitions().ReplaceAll({ c0, c1 });
            row.Padding({ 0, 7, 0, 7 });
            row.ColumnSpacing(14);

            Controls::TextBlock label;
            label.Text(hstring{ rows[i].label });
            label.FontSize(13);
            label.Foreground(Brush(Muted(DarkChrome())));
            Controls::Grid::SetColumn(label, 0);
            row.Children().Append(label);

            Controls::TextBlock value;
            value.Text(H(rows[i].value));
            value.FontSize(13);
            value.TextWrapping(TextWrapping::Wrap);
            value.IsTextSelectionEnabled(true);
            value.Foreground(Brush(Ink(DarkChrome())));
            if (rows[i].literal)
                value.FontFamily(Media::FontFamily{ kMono });
            Controls::Grid::SetColumn(value, 1);
            row.Children().Append(value);

            stack.Children().Append(row);
        }
        return LicenseCard(stack);
    }

    // The upstream address, with its own copy button. Opening it needs a
    // connection; copying it does not.
    Controls::Border MainWindow::LicenseUpstream(std::string const &url)
    {
        Controls::StackPanel stack;
        stack.Spacing(6);

        Controls::TextBlock heading;
        heading.Text(L"Upstream");
        heading.FontSize(11.5);
        heading.FontWeight(Windows::UI::Text::FontWeights::SemiBold());
        heading.Foreground(Brush(Muted(DarkChrome())));
        stack.Children().Append(heading);

        Controls::StackPanel line;
        line.Orientation(Controls::Orientation::Horizontal);
        line.Spacing(6);

        Controls::HyperlinkButton link;
        link.Content(box_value(H(url)));
        link.Padding({ 0, 0, 0, 0 });
        link.FontFamily(Media::FontFamily{ kMono });
        link.FontSize(13);
        try
        {
            link.NavigateUri(Windows::Foundation::Uri{ H(url) });
        }
        catch (hresult_error const &)
        {
            // Not an address this platform will open. It still reads and
            // copies, which is what the obligation needs.
            link.IsEnabled(false);
        }
        line.Children().Append(link);

        Controls::Button copy;
        Controls::FontIcon glyph;
        glyph.Glyph(L"");
        glyph.FontSize(13);
        copy.Content(glyph);
        copy.Padding({ 6, 2, 6, 2 });
        Controls::ToolTipService::SetToolTip(copy, box_value(hstring{ L"Copy address" }));
        Automation::AutomationProperties::SetName(copy, L"Copy address");
        copy.Click([url](auto &&, auto &&) {
            Windows::ApplicationModel::DataTransfer::DataPackage package;
            package.SetText(H(url));
            Windows::ApplicationModel::DataTransfer::Clipboard::SetContent(package);
        });
        line.Children().Append(copy);

        stack.Children().Append(line);
        return LicenseCard(stack);
    }

    // A block of text kept whole: the license itself, or a NOTICE.
    Controls::StackPanel MainWindow::LicenseTextBlock(hstring const &heading,
                                                      std::string const &note,
                                                      std::string const &text)
    {
        Controls::StackPanel stack;
        stack.Spacing(8);

        if (text.empty())
        {
            Controls::TextBlock none;
            none.Text(L"No license text.");
            none.FontSize(13);
            none.Foreground(Brush(Muted(DarkChrome())));
            stack.Children().Append(none);
            return stack;
        }

        Controls::TextBlock title;
        title.Text(heading);
        title.FontSize(11.5);
        title.FontWeight(Windows::UI::Text::FontWeights::SemiBold());
        title.Foreground(Brush(Muted(DarkChrome())));
        stack.Children().Append(title);

        if (!note.empty())
        {
            Controls::TextBlock why;
            why.Text(H(note));
            why.FontSize(13);
            why.TextWrapping(TextWrapping::Wrap);
            why.Foreground(Brush(Muted(DarkChrome())));
            stack.Children().Append(why);
        }

        // Whole and unmodified: nothing here trims it or reflows it.
        Controls::TextBlock body;
        body.Text(H(text));
        body.FontFamily(Media::FontFamily{ kMono });
        body.FontSize(11.5);
        body.TextWrapping(TextWrapping::Wrap);
        body.IsTextSelectionEnabled(true);
        body.Foreground(Brush(Ink(DarkChrome())));
        stack.Children().Append(LicenseCard(body));
        return stack;
    }

    // ---- the list ----------------------------------------------------------

    void MainWindow::BuildLicensesList()
    {
        if (licenses_list == nullptr)
            return;

        auto const &m = lkw::Licenses();
        licenses_list.Children().Clear();

        auto section = [&](hstring const &title) {
            Controls::TextBlock tb;
            tb.Text(title);
            tb.FontSize(11.5);
            tb.FontWeight(Windows::UI::Text::FontWeights::SemiBold());
            tb.Foreground(Brush(Muted(DarkChrome())));
            tb.Margin({ 10, 12, 10, 4 });
            licenses_list.Children().Append(tb);
        };

        // One row: what it is on the left, its license and its pin on the
        // right. The selection IS the navigation, so the detail follows it.
        auto row = [&](std::string const &id, std::string const &name,
                       std::string const &summary, std::string const &trailing,
                       std::string const &pin, bool strong, bool unresolved) {
            bool selected = licenses_selection == id;

            Controls::Button button;
            button.HorizontalAlignment(HorizontalAlignment::Stretch);
            button.HorizontalContentAlignment(HorizontalAlignment::Stretch);
            button.Padding({ 0, 0, 0, 0 });
            button.BorderThickness({ 0, 0, 0, 0 });
            button.Background(Brush(kClear));
            for (auto key : { L"ButtonBackground", L"ButtonBackgroundPointerOver",
                              L"ButtonBackgroundPressed", L"ButtonBackgroundDisabled" })
                button.Resources().Insert(box_value(hstring{ key }), Brush(kClear));

            Controls::Border selection;
            selection.CornerRadius({ 6, 6, 6, 6 });
            selection.Padding({ 10, 7, 10, 7 });
            selection.Background(Brush(selected ? AccentFill(DarkChrome()) : kClear));

            Controls::Grid grid;
            Controls::ColumnDefinition c0, c1;
            c0.Width({ 1, GridUnitType::Star });
            c1.Width({ 0, GridUnitType::Auto });
            grid.ColumnDefinitions().ReplaceAll({ c0, c1 });
            grid.ColumnSpacing(8);

            Controls::StackPanel what;
            Controls::TextBlock name_tb;
            name_tb.Text(H(name));
            name_tb.FontSize(13);
            name_tb.TextWrapping(TextWrapping::Wrap);
            name_tb.Foreground(Brush(selected ? Accent(DarkChrome()) : Ink(DarkChrome())));
            if (strong)
                name_tb.FontWeight(Windows::UI::Text::FontWeights::SemiBold());
            what.Children().Append(name_tb);
            if (!summary.empty())
            {
                Controls::TextBlock sub;
                sub.Text(H(summary));
                sub.FontSize(11.5);
                sub.TextWrapping(TextWrapping::Wrap);
                sub.Foreground(Brush(Muted(DarkChrome())));
                what.Children().Append(sub);
            }
            Controls::Grid::SetColumn(what, 0);
            grid.Children().Append(what);

            Controls::StackPanel terms;
            terms.HorizontalAlignment(HorizontalAlignment::Right);
            Controls::TextBlock trailing_tb;
            trailing_tb.Text(H(trailing));
            trailing_tb.FontSize(11.5);
            trailing_tb.TextAlignment(TextAlignment::Right);
            trailing_tb.Foreground(Brush(unresolved ? kAmber : Muted(DarkChrome())));
            terms.Children().Append(trailing_tb);
            if (!pin.empty())
            {
                Controls::TextBlock pin_tb;
                pin_tb.Text(H(pin));
                pin_tb.FontSize(11);
                pin_tb.TextAlignment(TextAlignment::Right);
                pin_tb.Foreground(Brush(Muted(DarkChrome())));
                terms.Children().Append(pin_tb);
            }
            Controls::Grid::SetColumn(terms, 1);
            grid.Children().Append(terms);

            selection.Child(grid);
            button.Content(selection);
            button.Click([this, id](auto &&, auto &&) {
                licenses_selection = id;
                BuildLicensesList();
                BuildLicensesDetail();
            });
            licenses_list.Children().Append(button);
        };

        section(L"This app");
        row("", m.app.name, m.app.copyright, m.app.license, lkw::AppVersion(), true, false);

        auto matches = [&](lkw::LicenseComponent const &c) {
            if (licenses_search.empty())
                return true;
            return Contains(c.name, licenses_search) || Contains(c.id, licenses_search) ||
                   Contains(c.summary, licenses_search) || Contains(c.license, licenses_search);
        };

        int shown = 0;
        auto component_row = [&](lkw::LicenseComponent const &c) {
            row(c.id, c.name, c.summary, c.ColumnLabel(), c.PinLabel(), false, c.license.empty());
            ++shown;
        };

        if (m.components.size() > 12)
        {
            for (auto const &g : m.Groups())
            {
                bool titled = false;
                for (size_t i : g.second)
                {
                    if (!matches(m.components[i]))
                        continue;
                    if (!titled)
                    {
                        section(H(g.first));
                        titled = true;
                    }
                    component_row(m.components[i]);
                }
            }
        }
        else
        {
            bool titled = false;
            for (auto const &c : m.components)
            {
                if (!matches(c))
                    continue;
                if (!titled)
                {
                    section(L"Components");
                    titled = true;
                }
                component_row(c);
            }
        }

        if (shown == 0 && !licenses_search.empty())
        {
            Controls::TextBlock none;
            none.Text(H("Nothing matches “" + licenses_search + "”."));
            none.FontSize(13);
            none.TextWrapping(TextWrapping::Wrap);
            none.Margin({ 10, 8, 10, 8 });
            none.Foreground(Brush(Muted(DarkChrome())));
            licenses_list.Children().Append(none);
        }
    }

    // ---- the detail --------------------------------------------------------

    void MainWindow::BuildLicensesDetail()
    {
        if (licenses_detail == nullptr)
            return;

        auto const &m = lkw::Licenses();
        licenses_detail.Children().Clear();

        auto heading = [&](std::string const &name, std::string const &summary) {
            Controls::StackPanel stack;
            stack.Spacing(6);
            Controls::TextBlock title;
            title.Text(H(name));
            title.FontSize(20);
            title.FontWeight(Windows::UI::Text::FontWeights::SemiBold());
            title.TextWrapping(TextWrapping::Wrap);
            title.Foreground(Brush(Ink(DarkChrome())));
            stack.Children().Append(title);
            if (!summary.empty())
            {
                Controls::TextBlock sub;
                sub.Text(H(summary));
                sub.FontSize(13);
                sub.TextWrapping(TextWrapping::Wrap);
                sub.Foreground(Brush(Muted(DarkChrome())));
                stack.Children().Append(sub);
            }
            licenses_detail.Children().Append(stack);
        };

        // This app's own terms.
        if (licenses_selection.empty())
        {
            heading(m.app.name, m.app.summary);
            licenses_detail.Children().Append(LicenseFacts({
                { L"License", m.app.license, false },
                { L"Version", lkw::AppVersion(), true },
                { L"Copyright", m.app.copyright, false },
            }));
            licenses_detail.Children().Append(LicenseUpstream(m.app.url));
            licenses_detail.Children().Append(
                LicenseTextBlock(H(Upper(m.app.license)), "", m.app.text));
            return;
        }

        lkw::LicenseComponent const *c = lkw::LicenseById(licenses_selection);
        if (c == nullptr)
        {
            heading("No component selected", "");
            return;
        }

        heading(c->name, c->summary);

        // An entry whose terms could not be determined says so, and why.
        if (c->license.empty())
        {
            Controls::StackPanel note;
            note.Spacing(4);
            Controls::TextBlock title;
            title.Text(L"License not resolved");
            title.FontSize(13);
            title.FontWeight(Windows::UI::Text::FontWeights::SemiBold());
            title.Foreground(Brush(kAmber));
            note.Children().Append(title);
            Controls::TextBlock why;
            why.Text(H(c->license_note));
            why.FontSize(13);
            why.TextWrapping(TextWrapping::Wrap);
            why.Foreground(Brush(Ink(DarkChrome())));
            note.Children().Append(why);

            Controls::Border card;
            card.CornerRadius({ 8, 8, 8, 8 });
            card.Padding({ 12, 10, 12, 10 });
            card.Background(Brush(kAmberFill));
            card.BorderBrush(Brush(kAmberEdge));
            card.BorderThickness({ 1, 1, 1, 1 });
            card.Child(note);
            licenses_detail.Children().Append(card);
        }

        std::vector<LicenseFact> facts;
        facts.push_back({ L"License", c->LicenseLabel(), false });
        if (!c->version.empty())
            facts.push_back({ L"Version", c->version, true });
        if (!c->commit.empty())
            facts.push_back({ L"Commit", c->commit, true });
        facts.push_back({ L"Pinned in", c->pinned_in, true });
        facts.push_back({ L"Copyright", c->copyright, false });
        licenses_detail.Children().Append(LicenseFacts(facts));

        licenses_detail.Children().Append(LicenseUpstream(c->url));

        // The NOTICE is a separate obligation from the license, so it sits
        // above it.
        if (!c->notice.empty())
            licenses_detail.Children().Append(LicenseTextBlock(L"NOTICE", "", c->notice));

        licenses_detail.Children().Append(
            LicenseTextBlock(H(Upper(c->LicenseLabel())),
                             c->license.empty() ? "" : c->license_note, c->text));
    }

    // ---- the licenses window -----------------------------------------------

    // Its own window rather than a settings page: the license text runs at its
    // own width, and About opens the same window.
    void MainWindow::ShowLicenses(std::string const &id)
    {
        licenses_selection = id;

        if (licenses_window != nullptr)
        {
            BuildLicensesList();
            BuildLicensesDetail();
            licenses_window.Activate(); // a second ask brings it forward
            return;
        }

        auto const &m = lkw::Licenses();

        Controls::Grid root;
        root.Background(Brush(DarkChrome() ? 0xFF1B2126u : 0xFFF7F7F7u));

        // An entry point that does nothing would hide a build whose list will
        // not decode, so say what happened instead.
        if (!m.ok)
        {
            Controls::StackPanel unavailable;
            unavailable.HorizontalAlignment(HorizontalAlignment::Center);
            unavailable.VerticalAlignment(VerticalAlignment::Center);
            unavailable.Spacing(6);
            Controls::TextBlock title;
            title.Text(L"License list unavailable");
            title.FontSize(16);
            title.FontWeight(Windows::UI::Text::FontWeights::SemiBold());
            title.Foreground(Brush(Ink(DarkChrome())));
            unavailable.Children().Append(title);
            Controls::TextBlock why;
            why.Text(L"This build's list could not be read.");
            why.FontSize(13);
            why.Foreground(Brush(Muted(DarkChrome())));
            unavailable.Children().Append(why);
            root.Children().Append(unavailable);
        }
        else
        {
            Controls::ColumnDefinition c0, c1;
            c0.Width({ 300, GridUnitType::Pixel });
            c0.MinWidth(260);
            c0.MaxWidth(380);
            c1.Width({ 1, GridUnitType::Star });
            root.ColumnDefinitions().ReplaceAll({ c0, c1 });

            Controls::StackPanel side;
            side.Padding({ 8, 8, 8, 8 });
            side.Spacing(2);

            // Search sits above twelve entries and not below: under that the
            // box is more chrome than the list it filters.
            if (m.components.size() > 12)
            {
                Controls::AutoSuggestBox search;
                search.QueryIcon(Controls::SymbolIcon{ Controls::Symbol::Find });
                search.PlaceholderText(
                    H("Search " + std::to_string(m.components.size()) + " components"));
                search.Margin({ 2, 2, 2, 6 });
                search.TextChanged([this](auto &&s, auto &&) {
                    licenses_search =
                        winrt::to_string(s.template as<Controls::AutoSuggestBox>().Text());
                    BuildLicensesList();
                });
                side.Children().Append(search);
            }

            Controls::StackPanel list;
            licenses_list = list;
            side.Children().Append(list);

            Controls::ScrollViewer side_scroll;
            side_scroll.Content(side);
            side_scroll.HorizontalScrollMode(Controls::ScrollMode::Disabled);
            Controls::Grid::SetColumn(side_scroll, 0);
            root.Children().Append(side_scroll);

            Controls::StackPanel detail;
            detail.Spacing(18);
            detail.Padding({ 20, 20, 20, 20 });
            licenses_detail = detail;

            Controls::ScrollViewer detail_scroll;
            detail_scroll.Content(detail);
            detail_scroll.HorizontalScrollMode(Controls::ScrollMode::Disabled);
            Controls::Grid::SetColumn(detail_scroll, 1);
            root.Children().Append(detail_scroll);

            BuildLicensesList();
            BuildLicensesDetail();
        }

        Window w;
        w.Title(L"Licenses");
        w.Content(root);
        licenses_window = w;

        // Wide enough that an 80-column license needs no reflowing.
        // ResizeClient counts PHYSICAL pixels, so the size the layout is
        // written in has to be scaled.
        double density = Density();
        w.AppWindow().ResizeClient({ (int)(980 * density), (int)(680 * density) });

        w.Closed([this](auto &&, auto &&) {
            licenses_list = nullptr;
            licenses_detail = nullptr;
            licenses_search.clear();
            licenses_window = nullptr;
        });

        // The app's mark, so the window wears it in Alt-Tab and the taskbar
        // rather than the stock WinUI one.
        HWND hwnd = nullptr;
        if (auto native = w.try_as<::IWindowNative>())
            if (SUCCEEDED(native->get_WindowHandle(&hwnd)))
                ApplyWindowIcon(hwnd);

        w.Activate();
    }

    // ---- the about window --------------------------------------------------

    void MainWindow::ShowAbout()
    {
        if (about_window != nullptr)
        {
            about_window.Activate();
            return;
        }

        auto const &m = lkw::Licenses();
        lkw::LicenseComponent const *engine = lkw::LicenseById(kEngineId);

        Controls::StackPanel box;
        box.Spacing(14);
        box.Padding({ 24, 24, 24, 24 });
        box.HorizontalAlignment(HorizontalAlignment::Center);
        box.VerticalAlignment(VerticalAlignment::Center);

        if (auto png = AppIconPng(); !png.empty())
        {
            Controls::Image icon;
            icon.Width(96);
            icon.Height(96);
            icon.HorizontalAlignment(HorizontalAlignment::Center);
            LoadAuxImage(icon, std::move(png), L"");
            box.Children().Append(icon);
        }

        Controls::StackPanel names;
        names.Spacing(4);

        Controls::TextBlock title;
        title.Text(H(m.app.name.empty() ? "Lookout Marine" : m.app.name));
        title.FontSize(20);
        title.FontWeight(Windows::UI::Text::FontWeights::SemiBold());
        title.HorizontalAlignment(HorizontalAlignment::Center);
        title.Foreground(Brush(Ink(DarkChrome())));
        names.Children().Append(title);

        Controls::TextBlock version;
        version.Text(H(std::string{ "Version " } + lkw::AppVersion()));
        version.FontSize(13);
        version.HorizontalAlignment(HorizontalAlignment::Center);
        version.Foreground(Brush(Muted(DarkChrome())));
        names.Children().Append(version);

        if (engine != nullptr && !engine->PinLabel().empty())
        {
            Controls::TextBlock pin;
            pin.Text(H("Chart engine " + engine->name + " · " + engine->PinLabel()));
            pin.FontSize(11.5);
            pin.TextAlignment(TextAlignment::Center);
            pin.TextWrapping(TextWrapping::Wrap);
            pin.IsTextSelectionEnabled(true);
            pin.Foreground(Brush(Muted(DarkChrome())));
            names.Children().Append(pin);
        }
        box.Children().Append(names);

        // Set apart, in the same amber the first-run page uses.
        Controls::TextBlock warn;
        warn.Text(L"NOT FOR NAVIGATION");
        warn.FontSize(11.5);
        warn.FontWeight(Windows::UI::Text::FontWeights::SemiBold());
        warn.HorizontalAlignment(HorizontalAlignment::Center);
        warn.Foreground(Brush(kAmber));
        box.Children().Append(warn);

        Controls::StackPanel buttons;
        buttons.Orientation(Controls::Orientation::Horizontal);
        buttons.Spacing(10);
        buttons.HorizontalAlignment(HorizontalAlignment::Center);

        // The ellipsis is the platform's promise that a window opens.
        Controls::Button licenses;
        licenses.Content(box_value(hstring{ L"Licenses…" }));
        licenses.Click([this](auto &&, auto &&) { ShowLicenses(""); });
        buttons.Children().Append(licenses);

        if (!m.app.url.empty())
        {
            Controls::HyperlinkButton source;
            source.Content(box_value(hstring{ L"Source" }));
            try
            {
                source.NavigateUri(Windows::Foundation::Uri{ H(m.app.url) });
                buttons.Children().Append(source);
            }
            catch (hresult_error const &)
            {
                // No address to open. About still says everything else.
            }
        }
        box.Children().Append(buttons);

        if (!m.app.copyright.empty())
        {
            Controls::TextBlock copyright;
            copyright.Text(H(m.app.copyright));
            copyright.FontSize(11);
            copyright.TextWrapping(TextWrapping::Wrap);
            copyright.TextAlignment(TextAlignment::Center);
            copyright.Foreground(Brush(Muted(DarkChrome())));
            box.Children().Append(copyright);
        }

        Controls::Grid root;
        root.Background(Brush(DarkChrome() ? 0xFF1B2126u : 0xFFF7F7F7u));
        root.Children().Append(box);

        Window w;
        w.Title(L"About Lookout Marine");
        w.Content(root);
        about_window = w;

        double density = Density();
        w.AppWindow().ResizeClient({ (int)(340 * density), (int)(420 * density) });
        // Fixed: the panel is one column of text and a pair of buttons.
        if (auto presenter =
                w.AppWindow().Presenter().try_as<Microsoft::UI::Windowing::OverlappedPresenter>())
        {
            presenter.IsResizable(false);
            presenter.IsMaximizable(false);
        }

        w.Closed([this](auto &&, auto &&) { about_window = nullptr; });

        HWND hwnd = nullptr;
        if (auto native = w.try_as<::IWindowNative>())
            if (SUCCEEDED(native->get_WindowHandle(&hwnd)))
                ApplyWindowIcon(hwnd);

        w.Activate();
    }
}
