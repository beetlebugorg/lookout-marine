// What the plugins put ON the chart, from the shell's side: the bubble pinned
// to an overlay object (an AIS target), the hover tip, the position-source
// pill and the follow lock. The drawing itself is the core's; this file only
// asks where things are and says what they are.
#include "pch.h"
#include "MainWindow.xaml.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace winrt::Windows::Data::Json;

namespace
{
    constexpr winrt::Windows::UI::Color kInk{ 0xFF, 0x1A, 0x1A, 0x1A };
    constexpr winrt::Windows::UI::Color kMuted{ 0xFF, 0x6B, 0x6B, 0x6B };
    constexpr winrt::Windows::UI::Color kAccent{ 0xFF, 0x1B, 0x49, 0xC4 };
    constexpr winrt::Windows::UI::Color kOverscale{ 0xFF, 0xD8, 0x3B, 0x01 };

    winrt::Windows::UI::Color WithAlpha(winrt::Windows::UI::Color c, double a)
    {
        c.A = (uint8_t)(a * 255.0 + 0.5);
        return c;
    }

    // {"title":"...","rows":[["key","value"],...]} into a small stack.
    void BuildPayload(winrt::Microsoft::UI::Xaml::Controls::StackPanel const &into,
                      std::string const &json)
    {
        into.Children().Clear();
        try
        {
            auto root = JsonObject::Parse(winrt::to_hstring(json));
            winrt::Microsoft::UI::Xaml::Controls::TextBlock title;
            title.Text(root.GetNamedString(L"title", L""));
            title.FontSize(13);
            title.FontWeight(winrt::Windows::UI::Text::FontWeights::SemiBold());
            title.Foreground(Media::SolidColorBrush{ kInk });
            into.Children().Append(title);
            for (auto const &rv : root.GetNamedArray(L"rows", JsonArray{}))
            {
                auto pair = rv.GetArray();
                if (pair.Size() < 2)
                    continue;
                winrt::Microsoft::UI::Xaml::Controls::StackPanel line;
                line.Orientation(winrt::Microsoft::UI::Xaml::Controls::Orientation::Horizontal);
                line.Spacing(6);
                winrt::Microsoft::UI::Xaml::Controls::TextBlock k;
                k.Text(pair.GetAt(0).GetString());
                k.FontSize(12);
                k.Foreground(Media::SolidColorBrush{ kMuted });
                line.Children().Append(k);
                winrt::Microsoft::UI::Xaml::Controls::TextBlock v;
                v.Text(pair.GetAt(1).GetString());
                v.FontSize(12);
                v.Foreground(Media::SolidColorBrush{ kInk });
                line.Children().Append(v);
                into.Children().Append(line);
            }
        }
        catch (winrt::hresult_error const &)
        {
        }
    }
}

namespace winrt::LookoutMarine::implementation
{
    // ---- the pinned bubble --------------------------------------------------

    // A tap that lands on an overlay symbol pins its bubble and does not open
    // the chart pick report. Returns true when it took the tap.
    bool MainWindow::TryPinOverlayAt(double x, double y)
    {
        lk_overlay_obj obj;
        if (!lk_controller_overlay_hit(controller, x, y, &obj))
            return false;
        overlay_pin_id = obj.id;
        overlay_pin_info.clear();
        DismissPick(); // one thing under the finger at a time
        UpdateOverlayBubble();
        lk_controller_overlay_free(&obj);
        return true;
    }

    void MainWindow::CloseOverlayBubble()
    {
        overlay_pin_id.clear();
        overlay_pin_info.clear();
        OverlayBubble().Visibility(Visibility::Collapsed);
    }

    // Re-read the pinned object every readout tick: the target moves, its
    // values change, and one day it ages out — the bubble follows all three.
    void MainWindow::UpdateOverlayBubble()
    {
        if (overlay_pin_id.empty())
            return;

        lk_overlay_obj obj;
        if (!lk_controller_overlay_info(controller, overlay_pin_id.c_str(), &obj))
        {
            CloseOverlayBubble(); // the object is gone; a bubble must not outlive it
            return;
        }

        std::string info = obj.info != nullptr ? obj.info : "";
        if (info != overlay_pin_info)
        {
            overlay_pin_info = info;
            BuildPayload(OverlayBubbleBody(), info);
        }

        double x = 0, y = 0;
        if (lk_controller_screen_of(controller, obj.lon, obj.lat, &x, &y))
        {
            OverlayBubble().Margin({ x + 14, y - 14, 0, 0 });
            OverlayBubble().Visibility(Visibility::Visible);
        }
        lk_controller_overlay_free(&obj);
    }

    // ---- the hover tip ------------------------------------------------------

    // Throttled from pointer moves; shows the payload under the pointer and
    // goes when nothing is there.
    void MainWindow::HoverProbe(double x, double y)
    {
        // One card at a time: while a bubble is pinned the hover tip stays
        // down, or the two overlap over the same target.
        if (!overlay_pin_id.empty())
        {
            HoverTip().Visibility(Visibility::Collapsed);
            hover_payload.clear();
            return;
        }
        LARGE_INTEGER now, freq;
        QueryPerformanceCounter(&now);
        QueryPerformanceFrequency(&freq);
        if (hover_qpc != 0 && (double)(now.QuadPart - hover_qpc) / freq.QuadPart < 0.12)
            return;
        hover_qpc = now.QuadPart;

        char *json = lk_controller_overlay_at(controller, x, y);
        if (json == nullptr)
        {
            HoverTip().Visibility(Visibility::Collapsed);
            hover_payload.clear();
            return;
        }
        if (hover_payload != json)
        {
            hover_payload = json;
            BuildPayload(HoverTipBody(), hover_payload);
        }
        free(json);
        HoverTip().Margin({ x + 16, y + 12, 0, 0 });
        HoverTip().Visibility(Visibility::Visible);
    }

    // ---- the position source ------------------------------------------------

    // GPS while a plugin publishes a fix, NO GPS when the fix is lost, and
    // Configure GPS when nothing publishes one. The reported fix or nothing —
    // never the map centre, never a dead-reckoned number.
    void MainWindow::UpdateGpsPill()
    {
        double lon = 0, lat = 0;
        int state = lk_controller_own_ship(controller, &lon, &lat);
        if (state == fix_state_shown)
            return;
        fix_state_shown = state;

        GpsPill().Visibility(Visibility::Visible);
        if (state == 2)
        {
            GpsIcon().Glyph(L"\uE707");
            GpsText().Text(L"GPS");
            GpsIcon().Foreground(Media::SolidColorBrush{ kAccent });
            GpsText().Foreground(Media::SolidColorBrush{ kAccent });
            GpsPill().Background(Media::SolidColorBrush{ WithAlpha(kAccent, 0.18) });
        }
        else if (state == 1)
        {
            GpsIcon().Glyph(L"\uE707");
            GpsText().Text(L"NO GPS");
            GpsIcon().Foreground(Media::SolidColorBrush{ kOverscale });
            GpsText().Foreground(Media::SolidColorBrush{ kOverscale });
            GpsPill().Background(Media::SolidColorBrush{ WithAlpha(kOverscale, 0.22) });
        }
        else
        {
            GpsIcon().Glyph(L"\uE713");
            GpsText().Text(L"Configure GPS");
            GpsIcon().Foreground(Media::SolidColorBrush{ kMuted });
            GpsText().Foreground(Media::SolidColorBrush{ kMuted });
            GpsPill().Background(Media::SolidColorBrush{ WithAlpha(kMuted, 0.14) });
        }
        Controls::ToolTipService::SetToolTip(GpsPill(), winrt::box_value(
            state == 0 ? L"No source of position. Add a gateway or a Signal K server."
                       : L"Position source. Opens Settings at Connections."));
    }

    // ---- the follow lock ----------------------------------------------------

    // The north bubble is the follow lock: unlocked it snaps north-up and arms
    // follow; following, it toggles north-up and course-up. Panning is the way
    // out — the core cancels follow on a pan, and this poll notices.
    void MainWindow::CycleFollowLock()
    {
        int follow = lk_controller_follow_active(controller);
        if (follow == 0)
        {
            lk_controller_reset_rotation(controller);
            lk_controller_follow_set(controller, 1);
        }
        else if (lk_controller_course_up_active(controller) == 0)
        {
            lk_controller_course_up_set(controller, 1);
        }
        else
        {
            lk_controller_course_up_set(controller, 0);
            lk_controller_reset_rotation(controller);
        }
        UpdateReadouts(true);
    }

    void MainWindow::UpdateFollowLock()
    {
        int follow = lk_controller_follow_active(controller);
        int course = lk_controller_course_up_active(controller);
        int state = follow == 0 ? 0 : follow == 2 ? 1 : course != 0 ? 3 : 2;
        if (state == follow_state_shown)
            return;
        follow_state_shown = state;

        NorthLetter().Text(state == 3 ? L"C" : L"N");
        auto tint = state == 0 ? kInk : state == 1 ? winrt::Windows::UI::Color{ 0xFF, 0xF5, 0x9E, 0x0B }
                                                   : kAccent;
        NorthLetter().Foreground(Media::SolidColorBrush{ tint });
        NorthCaret().Foreground(Media::SolidColorBrush{ tint });
        Controls::ToolTipService::SetToolTip(NorthBtn(), winrt::box_value(
            state == 0 ? L"Follow own ship"
            : state == 1 ? L"Following own ship, waiting for a fix"
            : state == 2 ? L"Following own ship, north up. Tap for course up"
                         : L"Following own ship, course up. Tap for north up"));
    }
}
