// Plugin alerts: the strip at the top of the chart and the siren behind it.
//
// AN ALARM IS AUDIBLE AND A WARNING IS VISIBLE. The plugins decide what is
// dangerous; this file only makes sure the decision reaches the helm: an
// alarm sounds, repeats until it is acknowledged, and never times out.
// Looking at it is not acknowledging it.
//
// The watch runs at 1 s whenever a chart is open, independent of any pane —
// a collision alarm must not need the settings window. The list is rebuilt
// only when the core's seq moves. An unreadable read clears the strip and
// silences the siren but KEEPS POLLING: stopping would leave the boat deaf
// for the rest of the session over one unanswered read.
#include "pch.h"
#include "MainWindow.xaml.h"

#include <mmsystem.h>

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace winrt::Windows::Data::Json;

namespace
{
    // The chrome tokens, so the strip follows the rest of the shell: alarm
    // wears the overscale red-orange, warning the amber, notice the accent.
    constexpr winrt::Windows::UI::Color kAlarm{ 0xFF, 0xD8, 0x3B, 0x01 };
    constexpr winrt::Windows::UI::Color kWarning{ 0xFF, 0xF5, 0x9E, 0x0B };
    constexpr winrt::Windows::UI::Color kNotice{ 0xFF, 0x1B, 0x49, 0xC4 };
    constexpr winrt::Windows::UI::Color kInk{ 0xFF, 0x1A, 0x1A, 0x1A };
    constexpr winrt::Windows::UI::Color kMuted{ 0xFF, 0x6B, 0x6B, 0x6B };
    constexpr winrt::Windows::UI::Color kRule{ 0xFF, 0xDD, 0xDD, 0xDD };
    // Theme-resolved ink for the strip's rows: the chrome wears the chart's
    // scheme, and the rows rebuild when the alert set changes.
    winrt::Windows::UI::Color ThemeInk(winrt::Microsoft::UI::Xaml::FrameworkElement const &el)
    {
        return el.ActualTheme() == winrt::Microsoft::UI::Xaml::ElementTheme::Dark
                   ? winrt::Windows::UI::Color{ 0xFF, 0xDD, 0xE4, 0xEA } : kInk;
    }

    winrt::Windows::UI::Color ThemeMuted(winrt::Microsoft::UI::Xaml::FrameworkElement const &el)
    {
        return el.ActualTheme() == winrt::Microsoft::UI::Xaml::ElementTheme::Dark
                   ? winrt::Windows::UI::Color{ 0xFF, 0x9F, 0xB0, 0xBD } : kMuted;
    }

    winrt::Windows::UI::Color ThemeRule(winrt::Microsoft::UI::Xaml::FrameworkElement const &el)
    {
        return el.ActualTheme() == winrt::Microsoft::UI::Xaml::ElementTheme::Dark
                   ? winrt::Windows::UI::Color{ 0xFF, 0x33, 0x41, 0x4D } : kRule;
    }


    winrt::Windows::UI::Color SeverityColor(int severity)
    {
        return severity >= 2 ? kAlarm : severity == 1 ? kWarning : kNotice;
    }

    wchar_t const *SeverityGlyph(int severity)
    {
        // Warning triangle for an alarm, exclamation circle for a warning,
        // info circle for a notice.
        return severity >= 2 ? L"\uE7BA" : severity == 1 ? L"\uE783" : L"\uE946";
    }

    int ParseSeverity(winrt::hstring const &word)
    {
        if (word == L"notice")
            return 0;
        if (word == L"warning")
            return 1;
        // "alarm", and every word this shell does not know: silence is never
        // the fallback.
        return 2;
    }
}

namespace winrt::LookoutMarine::implementation
{
    void MainWindow::StartAlertWatch()
    {
        if (alert_timer == nullptr)
        {
            alert_timer = DispatcherTimer{};
            alert_timer.Interval(std::chrono::seconds(1));
            alert_timer.Tick([this](auto &&, auto &&) { RefreshAlerts(); });
        }
        alert_seq = -1;
        RefreshAlerts();
        alert_timer.Start();
    }

    void MainWindow::StopAlertWatch()
    {
        if (alert_timer != nullptr)
            alert_timer.Stop();
        alerts.clear();
        alert_seq = -1;
        RebuildAlertStrip();
        SirenSetSounding(false);
    }

    void MainWindow::RefreshAlerts()
    {
        char *json = lk_controller_alerts_json(controller);
        if (json == nullptr)
        {
            // Unreadable is not "no alerts", but nothing readable means
            // nothing showable: clear, silence, keep watching.
            if (!alerts.empty())
            {
                alerts.clear();
                alert_seq = -1;
                RebuildAlertStrip();
            }
            SirenSetSounding(false);
            return;
        }

        bool changed = false;
        try
        {
            auto root = JsonObject::Parse(winrt::to_hstring(json));
            long long seq = (long long)root.GetNamedNumber(L"seq", 0);
            if (seq != alert_seq)
            {
                alert_seq = seq;
                changed = true;
                alerts.clear();
                auto arr = root.GetNamedArray(L"alerts", JsonArray{});
                for (auto const &v : arr)
                {
                    auto o = v.GetObject();
                    AlertItem a;
                    a.id = (unsigned long long)o.GetNamedNumber(L"id", 0);
                    a.severity = ParseSeverity(o.GetNamedString(L"severity", L""));
                    a.title = o.GetNamedString(L"title", L"").c_str();
                    a.body = o.GetNamedString(L"body", L"").c_str();
                    a.acknowledged = o.GetNamedBoolean(L"acknowledged", false);
                    alerts.push_back(std::move(a));
                }
            }
        }
        catch (winrt::hresult_error const &)
        {
            // A malformed read changes nothing; the next second answers again.
        }
        free(json);

        if (changed)
            RebuildAlertStrip();

        // The siren follows the state every poll, changed or not: an alarm is
        // audible until acknowledged, and warnings are never counted.
        bool audible = false;
        for (auto const &a : alerts)
            audible = audible || (a.severity >= 2 && !a.acknowledged);
        SirenSetSounding(audible);
    }

    void MainWindow::AcknowledgeAlert(unsigned long long id)
    {
        lk_controller_alert_ack(controller, id);
        // The control answers now, not on the next second.
        alert_seq = -1;
        RefreshAlerts();
    }

    // Only unacknowledged alerts show: acknowledging takes the row off the
    // chart entirely. What is still dangerous stays on the chart and at the
    // top of the target list.
    void MainWindow::RebuildAlertStrip()
    {
        auto rows = AlertRows();
        rows.Children().Clear();

        static constexpr int kMaxVisible = 2;
        int shown = 0, hidden = 0;
        for (auto const &a : alerts)
        {
            if (a.acknowledged)
                continue;
            if (shown >= kMaxVisible)
            {
                ++hidden;
                continue;
            }

            if (shown > 0)
            {
                Controls::Border rule;
                rule.Height(1);
                rule.Background(Media::SolidColorBrush{ ThemeRule(AlertStrip()) });
                rows.Children().Append(rule);
            }

            auto tint = SeverityColor(a.severity);

            Controls::Grid row;
            // The severity bar is an overlay at the row's leading edge, never
            // a sibling: a sibling is greedy vertically and drags the height.
            Controls::Border bar;
            bar.Width(4);
            bar.HorizontalAlignment(HorizontalAlignment::Left);
            bar.VerticalAlignment(VerticalAlignment::Stretch);
            bar.Background(Media::SolidColorBrush{ tint });
            row.Children().Append(bar);

            Controls::Grid line;
            line.Margin({ 14, 8, 10, 8 });
            line.ColumnSpacing(8);
            Controls::ColumnDefinition c0, c1, c2, c3;
            c0.Width({ 0, GridUnitType::Auto });
            c1.Width({ 0, GridUnitType::Auto });
            c2.Width({ 1, GridUnitType::Star });
            c3.Width({ 0, GridUnitType::Auto });
            line.ColumnDefinitions().ReplaceAll({ c0, c1, c2, c3 });

            Controls::FontIcon glyph;
            glyph.Glyph(SeverityGlyph(a.severity));
            glyph.FontSize(12);
            glyph.Foreground(Media::SolidColorBrush{ tint });
            glyph.VerticalAlignment(VerticalAlignment::Center);
            line.Children().Append(glyph);

            Controls::TextBlock title;
            title.Text(a.title);
            title.FontSize(13);
            title.FontWeight(winrt::Windows::UI::Text::FontWeights::SemiBold());
            title.Foreground(Media::SolidColorBrush{ ThemeInk(AlertStrip()) });
            title.VerticalAlignment(VerticalAlignment::Center);
            Controls::Grid::SetColumn(title, 1);
            line.Children().Append(title);

            // One line always: the body truncates rather than wrapping,
            // because the water under it is what the mariner is reading.
            Controls::TextBlock body;
            body.Text(a.body);
            body.FontSize(12);
            body.Foreground(Media::SolidColorBrush{ ThemeMuted(AlertStrip()) });
            body.VerticalAlignment(VerticalAlignment::Center);
            body.TextTrimming(TextTrimming::CharacterEllipsis);
            body.TextWrapping(TextWrapping::NoWrap);
            Controls::Grid::SetColumn(body, 2);
            line.Children().Append(body);

            Controls::Button ack;
            ack.Content(winrt::box_value(L"Acknowledge"));
            ack.FontSize(12);
            ack.Padding({ 10, 4, 10, 4 });
            ack.CornerRadius({ 6, 6, 6, 6 });
            ack.BorderThickness({ 0, 0, 0, 0 });
            ack.Background(Media::SolidColorBrush{ winrt::Windows::UI::Color{ 0x14, 0x00, 0x00, 0x00 } });
            ack.VerticalAlignment(VerticalAlignment::Center);
            Controls::ToolTipService::SetToolTip(ack,
                winrt::box_value(L"Silence this alert and take it off the chart"));
            unsigned long long id = a.id;
            ack.Click([this, id](auto &&, auto &&) { AcknowledgeAlert(id); });
            Controls::Grid::SetColumn(ack, 3);
            line.Children().Append(ack);

            row.Children().Append(line);
            rows.Children().Append(row);
            ++shown;
        }

        if (hidden > 0)
        {
            Controls::Border rule;
            rule.Height(1);
            rule.Background(Media::SolidColorBrush{ ThemeRule(AlertStrip()) });
            rows.Children().Append(rule);

            Controls::TextBlock more;
            more.Text(winrt::to_hstring(std::to_string(hidden) + " more"));
            more.FontSize(12);
            more.Foreground(Media::SolidColorBrush{ ThemeMuted(AlertStrip()) });
            more.Padding({ 12, 6, 12, 6 });
            rows.Children().Append(more);
        }

        AlertStrip().Visibility(shown > 0 ? Visibility::Visible : Visibility::Collapsed);
    }

    // ---- the siren ----------------------------------------------------------

    // Strike at once, then every 10 seconds until acknowledged: once a second
    // is right on a boat and unusable at a desk, and 10 s cannot be mistaken
    // for a one-off chime while leaving room to speak on the radio.
    void MainWindow::SirenSetSounding(bool on)
    {
        if (on == siren_on)
            return;
        siren_on = on;

        if (!on)
        {
            if (siren_timer != nullptr)
                siren_timer.Stop();
            PlaySoundW(nullptr, nullptr, 0); // stop a tone mid-ring
            return;
        }

        if (siren_timer == nullptr)
        {
            siren_timer = DispatcherTimer{};
            siren_timer.Interval(std::chrono::seconds(10));
            siren_timer.Tick([this](auto &&, auto &&) { SirenStrike(); });
        }
        SirenStrike();
        siren_timer.Start();
    }

    void MainWindow::SirenStrike()
    {
        // Stop, then play: restarted, never overlapped — an overlap goes
        // silent. The system exclamation stands in for a real marine tone,
        // as the macOS shell's system sound does.
        PlaySoundW(nullptr, nullptr, 0);
        if (!PlaySoundW(L"SystemExclamation", nullptr, SND_ALIAS | SND_ASYNC))
            MessageBeep(MB_ICONEXCLAMATION);
    }
}
