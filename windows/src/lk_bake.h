/* lk_bake — turning raw S-57 cells into charts the app can draw.
 *
 * A cell as a hydrographic office publishes it is an S-57 dataset: the survey,
 * not a picture of it. The app draws baked archives, so a folder or an archive
 * of .000 cells is baked once on the way in. tile57 does the work; this chooses
 * the order, runs it off the UI thread, reports where it has got to, and stops
 * when the mariner says stop.
 *
 * ORDER IS THE POINT. The list goes coarse band first: Overview, General,
 * Coastal, then the harbor detail. A mariner who cancels half way then has
 * charts that cover the whole passage at a usable scale. The other order gives
 * them every berth in one river and nothing between rivers.
 *
 * THE CHART OPENS ONCE, AT THE END. Handing each batch to the open library as
 * it finished put a chart on screen sooner and cost about half the machine:
 * every batch rebuilt the ownership partition over a growing library and
 * re-tessellated, against a bake that only gets half the cores to begin with.
 *
 * THE UI POLLS RATHER THAN BEING CALLED. tile57's progress callback fires from
 * worker threads, out of order, and a XAML element may only be touched on the
 * UI thread. Rather than marshal every step across, the job keeps one
 * mutex-guarded snapshot and the panel reads it on a timer — which also throttles
 * a 7,000 cell import to the handful of updates an eye can follow.
 */
#pragma once

#include <atomic>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace lkw
{
    /* Which piece of work the panel is reporting. */
    enum class WorkKind
    {
        Finding,  /* looking through a folder or an archive for charts */
        Importing /* converting cells and sheets into charts */
    };

    /* Where a bake has got to. Copied out under the lock; never aliased. */
    struct BakeProgress
    {
        WorkKind kind = WorkKind::Finding;
        unsigned done = 0;
        unsigned total = 0;
        std::string name; /* the folder or archive being baked */
        std::string cell; /* the cell that finished last */
        double elapsed = 0;
        bool running = false;
        bool cancelled = false;

        double Fraction() const { return total > 0 ? (double)done / (double)total : 0.0; }
        /* What this work is called, wherever it is shown. One definition, so the
         * panel and any pill cannot disagree. A count means the charts have been
         * found and are being converted. */
        std::string Title() const;
        /* What is left, from the rate so far. Empty until there is enough to say. */
        std::string Remaining() const;
    };

    /* One chart the scan found. `path` is a filesystem path for a folder, or an
     * ENTRY NAME for an archive — which is what the engine's zip bake takes back. */
    struct ScannedCell
    {
        std::string path;
        std::string name;
        std::string kind; /* "baked" (draws now), "source" (bakes first), "raster_source" */
        int band = 0;

        bool NeedsPrepare() const { return kind == "source" || kind == "raster_source"; }
    };

    struct ScanResult
    {
        std::string root;
        std::vector<ScannedCell> cells;
        unsigned sources = 0;
        bool ok = false;
    };

    /* True when `path` names an archive rather than a folder of files. */
    bool IsArchive(std::string const &path);

    /* Look through a folder or a .zip and report the charts in it. Reads only the
     * archive's central directory — nothing is inflated and nothing is written. */
    ScanResult ScanCharts(std::string const &path);

    /* One bake, running on its own thread. Construct, Start, poll Snapshot, and
     * either let it finish or Cancel. Destroying it joins the thread. */
    class BakeJob
    {
    public:
        BakeJob() = default;
        ~BakeJob();
        BakeJob(BakeJob const &) = delete;
        BakeJob &operator=(BakeJob const &) = delete;

        /* Bake every source under `source`: cells into `out_dir`, BSB/KAP
         * sheets into `raster_out_dir` — separate roots, because the vector
         * open globs the chart library for .pmtiles and a picture archive it
         * swallowed would join the composed chart library. False when there is
         * nothing to bake, in which case no thread starts. */
        bool Start(ScanResult const &scan, std::string const &source, std::string const &out_dir,
                   std::string const &raster_out_dir);

        /* Ask the bake to stop. tile57 stops at the next chart boundary, so this
         * lands within roughly one cell's bake time, not instantly. What already
         * landed is a valid library and a later run resumes from it. */
        void Cancel();

        BakeProgress Snapshot() const;
        bool Running() const { return running_.load(); }
        /* Every VECTOR chart archive that finished — what the open takes.
         * Valid once Running() is false. */
        std::vector<std::string> Finished() const;
        /* Every baked raster sheet — these belong to the raster underlay
         * (lookout_raster_add), never to the vector open. */
        std::vector<std::string> FinishedRasters() const;

        /* tile57 calls these from its workers; public only so the C callbacks
         * can reach them. */
        bool OnProgress(unsigned done, unsigned total);
        void OnLabel(unsigned index);

    private:
        void Run(std::string source, std::string out_dir);

        mutable std::mutex mu_;
        BakeProgress p_;
        std::vector<std::string> out_paths_;
        std::vector<std::string> finished_;
        std::vector<std::string> finished_rasters_;
        /* Where the phase now running starts in out_paths_, and the whole job's
         * count: the engine is called once per kind and counts from zero each
         * time, while the mariner is watching one job. */
        unsigned offset_ = 0;
        unsigned job_total_ = 0;

        std::vector<ScannedCell> ordered_;
        std::atomic<bool> cancel_{ false };
        std::atomic<bool> running_{ false };
        std::thread thread_;
        long long started_ms_ = 0;
    };
}
