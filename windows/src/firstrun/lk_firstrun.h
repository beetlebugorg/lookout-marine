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
#include <lookout-library.h> // lookout_setup_state
#include <optional>
#include <string>
#include <utility>
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

    // What of one region's water is on this device.
    //
    // The pick as a whole is priced by one cost call, and that total is what a
    // download costs. These are separate calls, one for each region, and they
    // state what the mariner already holds. The reference prices both, because
    // a picker that shows only the price of a pick says nothing about the
    // water a mariner downloaded last month.
    struct RegionHold
    {
        uint32_t missing{ 0 };
        uint32_t held{ 0 };

        uint32_t Total() const { return missing + held; }
        // Every cell covering this water is here.
        bool Complete() const { return missing == 0 && held > 0; }
        // Part of it is here. NOAA files a cell under one district that covers
        // another's water, so a region is often partly held before it is ever
        // picked.
        bool Partial() const { return held > 0 && missing > 0; }
        // Before a catalog is read every count is zero, and the pill says
        // nothing.
        bool Known() const { return Total() > 0; }
    };

    // What the pill says beside the region's name. Empty for water with none
    // of it here, which is most of the map on a first run.
    std::wstring RegionBadge(RegionHold const &hold);

    // The pill's name for a screen reader, which states the counts the badge
    // abbreviates to "installed".
    std::wstring RegionLabel(std::wstring const &name, std::wstring const &blurb,
                             RegionHold const &hold);

    // What a pick costs, in the mariner's words. Water already here is left
    // out of the price, so a pick wholly installed costs nothing and states
    // what fetching it again would move instead.
    std::wstring CostLine(uint32_t cells, uint64_t bytes, uint32_t held, uint64_t held_bytes);

    // ---- the picker's two halves ------------------------------------------
    //
    // A picker opened from the Charts pane states what the mariner HOLDS:
    // water already downloaded opens ticked, unticking it gives that water
    // back, and Apply does both halves at once. There was no way to give water
    // back before except by removing a whole chart set.

    // The regions ticked when the picker opened and unticked since, in the
    // order they were held. These are the removals. A region that was never
    // here and is unticked again is a mariner changing their mind.
    std::vector<std::string> Removed(std::string const &held, std::string const &picked);

    // What Apply is about to do, in the mariner's words. `removing` names the
    // regions being given back. With nothing to do either way it states what
    // the pick holds instead.
    std::wstring PlanLine(uint32_t cells, uint64_t bytes, uint32_t held, uint64_t held_bytes,
                          std::vector<std::wstring> const &removing);

    // The question asked before charts are deleted.
    std::wstring RemovalTitle(std::vector<std::wstring> const &removing);

    // Whether Apply has anything to do: charts to fetch, or water to give
    // back. Nothing to price from means nothing to apply.
    bool ApplyEnabled(bool have_catalog, uint32_t cells, size_t removing);

    // About how long preparing this many charts takes, for the question asked
    // before a set's prepared charts are deleted: the mariner is deciding
    // whether to throw away work, so the size of that work is the fact they
    // need. A fifth of a second a chart, measured by the reference over a
    // mixed Chesapeake set with every core working.
    std::wstring PrepareEstimate(size_t charts);

    // What the page says after a removal, in the mariner's words.
    //
    // Here beside PrepareEstimate for the same reason: these are the words the
    // question about deleting charts and its answer are made of, and one file
    // holds the words the tests can read.
    //
    // `removed` is how many charts went, `failed` how many a rename refused,
    // which on Windows means something still has the file open. Nothing of
    // either says the water was not this app's to give back.
    std::wstring RemovalNote(size_t removed, size_t failed);

    // One reading of the two services.
    struct FirstRunLive
    {
        // The transfer (lookout_noaa_poll).
        bool     downloading{ false };
        uint32_t fetched{ 0 };
        uint32_t expected{ 0 };
        // The core's prepare of the download (lookout_noaa_poll).
        bool     baking{ false };
        uint32_t found{ 0 }; // how many the scan returned
        uint32_t baked{ 0 }; // how many are through
        std::vector<FirstRunBand> bands;
    };

    // The setup step's view model. The core's setup handle holds the state
    // (lookout_setup, lookout-library.h). The shell reads it into this with
    // Read, and this keeps the words, the order and the bar.
    class FirstRun
    {
    public:
        // ---- the core's state, as last read ------------------------------
        void Read(lookout_setup_state const &s) { state_ = s; }
        FirstRunStep step() const { return static_cast<FirstRunStep>(state_.step); }
        // True while setup is over the chart.
        bool showing() const { return state_.showing != 0; }
        // True while setup is one step opened on its own.
        bool picker_only() const { return state_.picker_only != 0; }
        bool CanGoBack() const { return state_.can_go_back != 0; }
        bool PrimaryEnabled() const { return state_.primary_enabled != 0; }
        // NOAA's terms are up over the source step.
        bool showing_enc_terms() const { return state_.terms_showing != 0; }
        // Work ran on the import step, or the order finished. An import yet
        // to start and one that has finished both have no work running.
        bool saw_bake() const { return state_.saw_work != 0; }
        // The order's run ended with no chart to continue to. Back returns
        // to the coverage step.
        bool import_stalled() const { return state_.import_ended != 0; }

        ChartSource source() const { return source_; }
        void        set_source(ChartSource s) { source_ = s; }

        // What one run of setup holds. The shell clears it when setup comes
        // up: a second download in one launch read the first run's bands and
        // counts.
        void Restart()
        {
            order_.reset();
            shown_ = FirstRunLive{};
        }

        // ---- what the pages read ------------------------------------------
        std::wstring Title() const;
        // The last step names what it keeps. The online step offers Skip until
        // a chart is chosen.
        std::wstring PrimaryTitle(bool has_chart) const;

        // The facts the line beside the primary action is composed from. The
        // step decides which of them it uses.
        struct Footnotes
        {
            bool         have_catalog{ false };
            uint32_t     cells{ 0 };
            uint64_t     bytes{ 0 };
            uint32_t     held{ 0 };
            uint64_t     held_bytes{ 0 };
            std::wstring credit;
            bool         have_charts{ false };
            /* The regions being given back, by name. Only a picker opened
             * from the Charts pane has any: setup has nothing to give back
             * yet. */
            std::vector<std::wstring> removing;
        };
        // The line beside the primary action: the coverage step prices the
        // pick there, the depths step says where its numbers live afterwards,
        // and the online step states the publisher's credit. Empty on the
        // steps that have nothing to say.
        std::wstring Footnote(Footnotes const &f) const;

        // ---- the order, and the counts ------------------------------------
        std::optional<FirstRunOrder> const &order() const { return order_; }
        void set_order(FirstRunOrder o) { order_ = std::move(o); }

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
        lookout_setup_state          state_{};
        ChartSource                  source_{ ChartSource::Noaa };
        std::optional<FirstRunOrder> order_;
        FirstRunLive                 shown_;
    };
}
