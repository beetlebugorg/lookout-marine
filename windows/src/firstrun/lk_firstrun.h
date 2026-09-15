// Setup: what it asks, in what order, and whether it runs.
//
// This is the model. It has no XAML, no WinRT and no core handle, so
// windows/test/test_firstrun.cpp exercises the whole flow without a UI thread.
// The pages in firstrun/ui read it and draw what it reports.
//
// Ported from android/.../firstrun/FirstRunModel.kt. It matches Apple and
// Android on when setup runs. It differs on where the import counts are
// latched: Android latches in the view with `remember`, and this latches in
// Observe below, so a test covers the rule.
#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace lkw
{
    // Where the charts come from. The source step asks this once.
    enum class ChartSource
    {
        Noaa,
        Online,
        Files,
    };

    enum class FirstRunStep
    {
        Welcome,
        Source,
        Coverage,    // which waters, for NOAA
        OnlineChart, // a published style, drawn as the chart
        Importing,   // charts arriving and converting; setup stays open
        Depths,      // the safety contour, once there is a chart to draw it on
    };

    // What the mariner asked NOAA for, kept from the moment they asked. The
    // download service resets its counters when the transfer ends. The page
    // outlives the transfer.
    struct FirstRunOrder
    {
        std::wstring regions;    // the names, for the page
        std::string  region_ids; // "d5,d8", for the core
        uint32_t     charts{ 0 };
        uint64_t     bytes{ 0 };
    };

    // One usage band's share of the bake. Coarse band first. That is the order
    // lookout_bake_order runs, and stopping partway then leaves charts
    // covering the whole passage.
    struct FirstRunBand
    {
        int          band{ 0 }; // 1..6
        std::wstring name;      // "Overview", "General", ...
        uint32_t     done{ 0 };
        uint32_t     total{ 0 };

        bool complete() const { return total > 0 && done >= total; }
    };

    // "Overview", "General", "Coastal", "Approach", "Harbor", "Berthing", else
    // "Other". The same words the other shells use.
    std::wstring FirstRunBandName(int band);

    // The shape the other shells price a download in, so "226.5 MB" and
    // "1,238". What the settings pane totals a library in as well.
    std::wstring SizeText(uint64_t bytes);
    std::wstring Thousands(uint64_t n);

    // The depth step's two questions, and the four numbers the engine draws
    // with that follow from them.
    //
    // The draft and the clearance are held in the unit on screen so every
    // number displays round. A metric list converted into feet gives a 4.9 ft
    // clearance and a 16.4 ft contour.
    class DepthChoice
    {
    public:
        // A small keelboat. The stored safety depth is no help as a start: it
        // begins at the engine's 10 m, and a draft read back out of that is
        // 9.7 m.
        explicit DepthChoice(bool feet = false)
            : feet_(feet), draft_(feet ? 5.5 : 1.7), clearance_(feet ? 2.0 : 0.6)
        {
        }

        bool feet() const { return feet_; }
        double draft() const { return draft_; }
        double clearance() const { return clearance_; }
        wchar_t const *unit() const { return feet_ ? L"ft" : L"m"; }

        // The clearances offered, round in both units.
        std::vector<double> Clearances() const;
        // The contours an S-57 survey draws. The safety contour is the first
        // of these at or past the safety depth, because the chart shades on a
        // contour the survey has.
        std::vector<double> Ladder() const;

        // Draft plus clearance, rounded up to a whole foot or metre. A chart
        // names its depths in whole numbers, and the fraction belongs to the
        // keel rather than to the water.
        double SafetyDepth() const;
        double SafetyContour() const;
        // Twice the safety contour, up the same ladder. The step does not ask
        // for it.
        double DeepContour() const;
        // The deepest water the illustration draws, half again past the deep
        // contour so the last shade has water in it.
        double Floor() const { return DeepContour() * 1.5; }

        // How far out a depth lies, as a fraction of the illustration. The
        // slope is measured in contours rather than metres because the
        // answers span a dinghy and a ship.
        double Reach(double depth) const;

        // One step of the draft field: half a foot, or a tenth of a metre.
        double StepSize() const { return feet_ ? 0.5 : 0.1; }
        void Step(int by);
        // Read a draft the mariner typed. False when it is not a depth, in
        // which case the draft stands.
        bool ReadDraft(std::wstring const &text);
        void set_clearance(double c) { clearance_ = c; }
        // Change the unit: convert the draft, and snap the clearance to one of
        // the choices the new unit offers.
        void SetUnit(bool feet);

        // A depth on screen with its unit on it, and the draft alone for the
        // field.
        std::wstring Measure(double v) const;
        std::wstring DraftText() const;
        // A depth on screen in metres, which is what the engine is given.
        double Metres(double v) const { return feet_ ? v / 3.28084 : v; }

        // The spot depths the illustration draws: a depth as a multiple of
        // the safety contour, and how far along its line it stands. Multiples
        // hold a sounding in place while the mariner works, so it moves only
        // when the contour steps to the next one the survey draws.
        struct Spot
        {
            double of_contour;
            double across;
        };
        static std::vector<Spot> Spots();

    private:
        bool   feet_{ false };
        double draft_{ 1.7 };
        double clearance_{ 0.6 };
    };

    // The regions a download covers, as the core's own comma separated list
    // ("d5,d8"). A mariner picks several: lookout_noaa_cost and
    // lookout_noaa_download both take the list and answer for the union, which
    // is why one total is stated rather than a price per region (the cells of
    // neighbouring districts overlap, so per-region prices do not sum).
    bool RegionPicked(std::string const &list, std::string const &id);
    std::string RegionToggle(std::string const &list, std::string const &id);

    // About how long preparing this many charts takes, for the question asked
    // before a set's prepared charts are deleted: the mariner is deciding
    // whether to throw away work, so the size of that work is the fact they
    // need. A fifth of a second a chart, measured by the reference over a
    // mixed Chesapeake set with every core working.
    std::wstring PrepareEstimate(size_t charts);

    // The band breakdown, from what the scan found and how far the bake has
    // got. `band_of_each_chart` is the band of every chart the scan returned,
    // in any order. `done` is the bake's own count.
    //
    // The bake publishes no per-band counter. lookout_bake_order runs coarse
    // band first, so the first `done` charts of that run are the coarsest
    // `done` charts. Spreading `done` over the bands in ascending order
    // reports what the bake finished.
    //
    // A chart whose name has no usage band goes last.
    std::vector<FirstRunBand> FirstRunBands(std::vector<int> const &band_of_each_chart,
                                            uint32_t done);

    // One reading of the two services.
    struct FirstRunLive
    {
        // The transfer (lookout_noaa_poll).
        bool     downloading{ false };
        uint32_t fetched{ 0 };
        uint32_t expected{ 0 };
        // The bake (lookout_bake_poll, plus the scan that fed it).
        bool     baking{ false };
        uint32_t found{ 0 }; // how many the scan returned
        uint32_t baked{ 0 }; // how many are through
        std::vector<FirstRunBand> bands;
    };

    class FirstRun
    {
    public:
        // ---- where it is -------------------------------------------------
        FirstRunStep step() const { return step_; }
        ChartSource  source() const { return source_; }
        void         set_source(ChartSource s) { source_ = s; }
        // True while setup is over the chart.
        bool showing() const { return showing_; }

        // ---- whether it runs ---------------------------------------------
        //
        // `nothing_to_draw` is the app having settled on having no chart to
        // draw, for any reason, including a configured set whose drive is
        // unplugged. Setup is where an empty chart area goes, because the
        // source step is where a mariner re-points at their charts.
        //
        // Setup runs on every launch that finds an empty library, rather than
        // once per device. A mariner with an empty library has the same
        // questions to answer on their fiftieth launch as their first.
        //
        // `linked` is a published style drawing in place of a library. A
        // mariner sailing on one has no empty library to fill.
        bool ShouldRun(bool nothing_to_draw, bool linked) const
        {
            return !put_away_ && !linked && nothing_to_draw;
        }

        void Begin()
        {
            step_        = FirstRunStep::Welcome;
            showing_     = true;
            picker_only_ = false;
        }

        // Open one step on its own, for Get charts from NOAA in the Charts
        // pane. The mariner already has charts and has answered the welcome
        // questions, so the run ends when the charts are in rather than going
        // on to the depth step.
        void BeginAt(FirstRunStep step)
        {
            step_        = step;
            showing_     = true;
            picker_only_ = true;
        }

        // True while setup is one step opened on its own.
        bool picker_only() const { return picker_only_; }

        // ---- moving through it -------------------------------------------

        // Back applies on the asking steps. The welcome step offers Set Up
        // Later instead. Past the import the charts are already arriving.
        bool CanGoBack() const
        {
            if (picker_only_)
                return false;
            return step_ == FirstRunStep::Source || step_ == FirstRunStep::Coverage ||
                   step_ == FirstRunStep::OnlineChart;
        }
        void Back();

        // The primary action for the step on screen. Returns the source to act
        // on when the flow has finished asking and the shell has work to do,
        // such as raising a file picker, else no source.
        std::optional<ChartSource> Advance();

        // ---- NOAA's terms -------------------------------------------------
        //
        // The gate is in the model rather than on the button. Advance() raises
        // the sheet instead of moving the step, so every caller of the primary
        // action inherits it. The sheet is a dialog over setup rather than a
        // step of it, so it stays out of the step count and out of Back.
        bool showing_enc_terms() const { return showing_enc_terms_; }
        // Accepted. On to picking water.
        void AgreeToEncTerms()
        {
            showing_enc_terms_ = false;
            step_              = FirstRunStep::Coverage;
        }
        // Dismissed without accepting. The source step stands, so another
        // source is still open to them.
        void DeclineEncTerms() { showing_enc_terms_ = false; }

        // Set Up Later, and the end of a run that finished. Both put setup away
        // for the rest of this launch. Set Up Later means not now, so it holds
        // until the app is next started with an empty library.
        void Finish();

        // ---- what the pages read ------------------------------------------
        std::wstring Title() const;
        // The last step names what it keeps. The online step offers Skip until
        // a chart is chosen.
        std::wstring PrimaryTitle(bool has_chart) const;

        // Whether the primary action has anything to do on the step showing.
        //
        // A download with nothing picked, or with no catalog to price it
        // from, does nothing. While charts are still arriving there is
        // nothing to continue TO: the shell opens the library when the bake
        // ends, and `chart_ready` is how it says that has happened. Every
        // other step is always ready to move on.
        bool PrimaryEnabled(bool have_catalog, bool region_picked, bool chart_ready) const;

        // ---- the order, and the counts ------------------------------------
        std::optional<FirstRunOrder> const &order() const { return order_; }
        void set_order(FirstRunOrder o) { order_ = std::move(o); }

        // True once a bake has been seen running. An import that has yet to
        // start and one that has finished both report no work, and this
        // separates them.
        bool saw_bake() const { return saw_bake_; }

        // Hand this every reading of the two services. It keeps the last
        // figures each of them reported.
        //
        // Both services reset when their work ends. The transfer's counters go
        // back to zero and the bake's last state has no total and no bands, so
        // a page reading them live empties itself to "0 of 513" at the moment
        // it finishes. A reading counts as news only when it has a total.
        void Observe(FirstRunLive const &live);

        // The figures to draw, after latching. Safe to call before any
        // Observe.
        FirstRunLive const &shown() const { return shown_; }
        // How many charts the transfer is working towards: what it reported,
        // else what the mariner ordered.
        uint32_t expected() const;
        // 0..1 across the whole job. One bar, because a bar per phase reads as
        // three jobs. The transfer is the first 35%, since the bake is the
        // longer part.
        double Fraction() const;

    private:
        FirstRunStep step_{ FirstRunStep::Welcome };
        ChartSource  source_{ ChartSource::Noaa };
        bool         showing_{ false };
        bool         showing_enc_terms_{ false };
        bool         put_away_{ false };
        bool         saw_bake_{ false };
        bool         picker_only_{ false };

        std::optional<FirstRunOrder> order_;
        FirstRunLive                 shown_;
    };
}
