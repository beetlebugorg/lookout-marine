// Setup's shared parts. Declared in FirstRunParts.h.
#include "pch.h"
#include "FirstRunParts.h"

namespace lkw::setup
{

    SolidColorBrush HairlineBrush(bool dark)
    {
        return SolidColorBrush{ lkw::Rgb(lkw::chrome::Hairline(dark)) };
    }

    // A step's title and the one line under it, centered in the card the way
    // the reference centers them. The blurb is held to 470 points: a line of
    // prose the full width of the card has no shorter line to center against.
    StackPanel Heading(std::wstring const &title, std::wstring const &blurb)
    {
        StackPanel s;
        s.Spacing(9);
        auto head = Line(title, 24, true);
        head.CharacterSpacing(-13); // the reference's -0.3 points at 24
        head.TextAlignment(TextAlignment::Center);
        head.HorizontalAlignment(HorizontalAlignment::Center);
        s.Children().Append(head);
        auto says = Muted(blurb, 13.5);
        says.TextAlignment(TextAlignment::Center);
        says.HorizontalAlignment(HorizontalAlignment::Center);
        says.MaxWidth(470);
        s.Children().Append(says);
        return s;
    }

    // One thing the app does, as a row: the glyph, then what and why.
    StackPanel Fact(wchar_t const *glyph, std::wstring const &title, std::wstring const &blurb,
                    bool dark)
    {
        StackPanel row;
        row.Orientation(Orientation::Horizontal);
        row.Spacing(12);

        FontIcon icon;
        icon.Glyph(glyph);
        icon.FontSize(18);
        icon.Foreground(AccentBrush(dark));
        icon.VerticalAlignment(VerticalAlignment::Top);
        icon.Margin({ 0, 2, 0, 0 });
        row.Children().Append(icon);

        StackPanel words;
        words.Spacing(2);
        words.MaxWidth(560);
        words.Children().Append(Line(title, 14, true));
        words.Children().Append(Muted(blurb));
        row.Children().Append(words);
        return row;
    }

    // The amber panel the compliance text sits in. The colour is fixed in both
    // schemes, because it means "read this" in day and night alike.
    Border WarningPanel(std::wstring const &heading, std::wstring const &body)
    {
        StackPanel words;
        words.Spacing(4);

        TextBlock head;
        head.Text(heading);
        head.FontSize(12);
        head.FontWeight(Windows::UI::Text::FontWeights::Bold());
        head.CharacterSpacing(50);
        words.Children().Append(head);
        words.Children().Append(Muted(body, 12));

        Border b;
        b.CornerRadius({ 9, 9, 9, 9 });
        b.Padding({ 12, 11, 12, 11 });
        b.Background(SolidColorBrush{ Windows::UI::Color{ 0x24, 0xF5, 0x9E, 0x0B } });
        b.BorderBrush(SolidColorBrush{ Windows::UI::Color{ 0x8C, 0xF5, 0x9E, 0x0B } });
        b.BorderThickness({ 1, 1, 1, 1 });
        b.Child(words);
        return b;
    }

    // A link that opens in the mariner's browser.
    TextBlock LinkLine(std::wstring const &text, std::wstring const &url)
    {
        TextBlock t;
        t.FontSize(12.5);
        t.TextWrapping(TextWrapping::Wrap);
        Hyperlink h;
        h.NavigateUri(Windows::Foundation::Uri{ url });
        Run r;
        r.Text(text);
        h.Inlines().Append(r);
        t.Inlines().Append(h);
        return t;
    }

    // A pill or a segment wearing the pick.
    void PaintPicked(Button const &b, bool on, bool dark)
    {
        b.BorderThickness({ 1, 1, 1, 1 });
        // A pill keeps one hue through the hover fade. See lkw::ButtonFills:
        // a transparent button crosses through a dark wash on the way to the
        // theme's own hover fill, and an accent one washes out to near white.
        if (on)
        {
            uint32_t const fill = lkw::chrome::Accent(dark);
            lkw::ButtonFills(b, fill, fill, fill, 0x00000000u);
            b.BorderBrush(SolidColorBrush{ Windows::UI::Colors::Transparent() });
            b.Foreground(SolidColorBrush{ Windows::UI::Colors::White() });
            b.FontWeight(Windows::UI::Text::FontWeights::SemiBold());
        }
        else
        {
            lkw::FlatFills(b, dark, lkw::chrome::Hairline(dark));
            b.BorderBrush(HairlineBrush(dark));
            // Back to the theme's own ink rather than a colour of this file's.
            b.ClearValue(Controls::Control::ForegroundProperty());
            b.FontWeight(Windows::UI::Text::FontWeights::Normal());
        }
    }

    // One region as a pill: a capsule the mariner picks, ticked and filled
    // while it is in the pick. The reference draws the districts this way in
    // setup and in the settings picker alike.
    Button RegionPill(std::wstring const &name, std::wstring const &blurb,
                      lkw::RegionHold const &hold, bool on, bool enabled, bool dark)
    {
        StackPanel row;
        row.Orientation(Orientation::Horizontal);
        row.Spacing(6);
        row.VerticalAlignment(VerticalAlignment::Center);
        if (on)
        {
            FontIcon tick;
            tick.Glyph(L""); // CheckMark
            tick.FontSize(10);
            tick.Foreground(SolidColorBrush{ Windows::UI::Colors::White() });
            row.Children().Append(tick);
        }
        TextBlock t;
        t.Text(name);
        t.FontSize(12.5);
        if (on)
        {
            t.FontWeight(Windows::UI::Text::FontWeights::SemiBold());
            t.Foreground(SolidColorBrush{ Windows::UI::Colors::White() });
        }
        row.Children().Append(t);

        // What of this water is here, after the name. Water with none of it
        // here says nothing, which is every region on a first run.
        std::wstring const badge = lkw::RegionBadge(hold);
        if (!badge.empty())
        {
            TextBlock note;
            note.Text(badge);
            note.FontSize(11);
            note.Opacity(0.75);
            if (on)
                note.Foreground(SolidColorBrush{ Windows::UI::Colors::White() });
            row.Children().Append(note);
        }

        Button b;
        b.Content(row);
        b.Height(30);
        b.MinWidth(0);
        b.Padding({ 13, 0, 13, 0 });
        b.CornerRadius({ 15, 15, 15, 15 });
        b.BorderThickness({ 1, 1, 1, 1 });
        if (on)
        {
            // The pick stays the accent under the pointer, rather than fading
            // to the theme's near-white hover fill. See lkw::ButtonFills.
            uint32_t const fill = lkw::chrome::Accent(dark);
            lkw::ButtonFills(b, fill, fill, fill, 0x00000000u);
            b.BorderBrush(SolidColorBrush{ Windows::UI::Colors::Transparent() });
        }
        else
        {
            // The reference fills an unpicked pill with Chrome.surface, which
            // is white by day and #16181C at night. Opaque, so the hover fade
            // stays in that family.
            lkw::ButtonFills(b, lkw::chrome::Surface(dark),
                             lkw::chrome::SurfaceOver(dark),
                             lkw::chrome::SurfaceDown(dark),
                             lkw::chrome::Hairline(dark));
            b.BorderBrush(HairlineBrush(dark));
        }
        b.IsEnabled(enabled);
        b.Opacity(enabled ? 1.0 : 0.5);
        ToolTipService::SetToolTip(b, box_value(blurb));
        Automation::AutomationProperties::SetName(b, lkw::RegionLabel(name, blurb, hold));
        return b;
    }

    // One pickable card: the source step's three, and the coverage step's
    // regions. The border shows the checked state, and the whole card is the
    // click target.
    Button ChoiceCard(wchar_t const *glyph, std::wstring const &title, std::wstring const &blurb,
                      bool picked, bool recommended, bool dark)
    {
        StackPanel words;
        words.Spacing(3);

        StackPanel title_row;
        title_row.Orientation(Orientation::Horizontal);
        title_row.Spacing(8);
        title_row.Children().Append(Line(title, 14, true));
        if (recommended)
        {
            Border tag;
            tag.CornerRadius({ 8, 8, 8, 8 });
            tag.Padding({ 7, 1, 7, 2 });
            tag.Background(AccentBrush(dark));
            TextBlock tt;
            tt.Text(L"Recommended");
            tt.FontSize(10.5);
            tt.FontWeight(Windows::UI::Text::FontWeights::SemiBold());
            tt.Foreground(SolidColorBrush{ Windows::UI::Colors::White() });
            tag.Child(tt);
            tag.VerticalAlignment(VerticalAlignment::Center);
            title_row.Children().Append(tag);
        }
        words.Children().Append(title_row);
        words.Children().Append(Muted(blurb));

        StackPanel row;
        row.Orientation(Orientation::Horizontal);
        row.Spacing(12);
        if (glyph != nullptr)
        {
            FontIcon icon;
            icon.Glyph(glyph);
            icon.FontSize(17);
            icon.VerticalAlignment(VerticalAlignment::Top);
            icon.Margin({ 0, 2, 0, 0 });
            if (picked)
                icon.Foreground(AccentBrush(dark));
            else
                icon.Opacity(0.7);
            row.Children().Append(icon);
        }
        row.Children().Append(words);

        Button b;
        b.Content(row);
        b.HorizontalAlignment(HorizontalAlignment::Stretch);
        b.HorizontalContentAlignment(HorizontalAlignment::Left);
        b.Padding({ 14, 12, 14, 12 });
        b.CornerRadius({ 10, 10, 10, 10 });
        b.BorderThickness(picked ? Thickness{ 2, 2, 2, 2 } : Thickness{ 1, 1, 1, 1 });
        b.BorderBrush(picked ? AccentBrush(dark) : HairlineBrush(dark));
        return b;
    }
}
