/* lk_bake — turning raw S-57 cells into charts the app can draw.
 *
 * A cell as a hydrographic office publishes it is an S-57 dataset: the survey,
 * not a picture of it. The app draws baked archives, so a folder or an archive
 * of .000 cells is baked once on the way in.
 *
 * THE ENGINE RUNS IT (lookout_bake_start): the coarse-band-first order, the
 * worker cap, the three phases, where each prepared chart is written, and the
 * cancel. What is left here is what the import PANEL shows: the phase it is
 * in, how long there is to go, and which of what landed is a picture.
 *
 * THE CHART OPENS ONCE, AT THE END. Handing each batch to the open library as
 * it finished put a chart on screen sooner and cost about half the machine:
 * every batch rebuilt the ownership partition over a growing library and
 * re-tessellated, against a bake that only gets half the cores to begin with.
 *
 * THE UI POLLS RATHER THAN BEING CALLED. No callback crosses back out of the
 * engine, and a XAML element may only be touched on the UI thread anyway, so
 * the panel reads one snapshot on a timer — which also throttles a 7,000 cell
 * import to the handful of updates an eye can follow.
 */
#pragma once

#include <mutex>
#include <string>
#include <vector>

#include "lookout.h"

namespace lkw
{
    /* Which piece of work the panel is reporting. */
    enum class WorkKind
    {
        Finding,  /* looking through a folder or an archive for charts */
        Importing, /* converting cells and sheets into charts */
        /* deleting charts a mariner gave back: a set they removed, or
         * water they unticked in the NOAA picker. Counted the way the
         * import counted them in, a chart at a time. */
        Removing
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
        /* What the file is, as the engine classified it. */
        lookout_file_kind kind = LOOKOUT_FILE_OTHER;
        int band = 0;
        /* `path` is an entry inside the archive: even a chart that draws now
         * has to come out before the engine can be handed it. */
        bool archived = false;

        bool NeedsPrepare() const
        {
            return archived || kind == LOOKOUT_FILE_SOURCE || kind == LOOKOUT_FILE_RASTER_SOURCE;
        }
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

    /* A removal, reported while it runs.
     *
     * The charts are out of the library the moment the rename returns, and the
     * delete behind it takes as long as the disk takes: 930 cells is 446 MB of
     * files to unlink. That is what this reports, so a removal says where it
     * has got to in the same panel an import does, and for the same reason.
     *
     * There is no way out of one. The set is already off the list and the
     * charts are already moved aside, so stopping here could only leave them
     * half deleted.
     *
     * Written by the delete thread, read by the UI thread, under one lock.
     * Held by shared_ptr: the thread outlives the call that started it.
     */
    class RemovalJob
    {
    public:
        /* `name` is what is going, in the mariner's words ("Mid-Atlantic",
         * "NOAA"). `total` is how many charts were moved aside. */
        void Begin(std::string name, unsigned total);
        /* One chart gone. */
        void Step();
        /* How many there are, once the emptier has listed them. */
        void Count(unsigned total);
        /* Nothing left to delete. `note` is what the page says afterwards, and
         * stays until the next removal. */
        void Finish(std::string note);

        BakeProgress Snapshot() const;
        bool Running() const;
        /* What the last removal left to say. Empty when there is nothing. */
        std::string Note() const;

    private:
        mutable std::mutex mu_;
        BakeProgress now_;
        std::string note_;
    };

    /* One bake, running on the ENGINE's own thread. Construct, Start, poll
     * Snapshot, and either let it finish or Cancel. Destroying it cancels and
     * joins. */
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
         * nothing to bake, in which case no bake starts. */
        bool Start(ScanResult const &scan, std::string const &source, std::string const &out_dir,
                   std::string const &raster_out_dir);

        /* Ask the bake to stop. tile57 stops at the next chart boundary, so this
         * lands within roughly one cell's bake time, not instantly. What already
         * landed is a valid library and a later run resumes from it. */
        void Cancel();

        BakeProgress Snapshot() const;
        /* The core's job, for lookout_chart_sets_note_bake. Freed when this
         * is destroyed, so read it before the reset. */
        lookout_bake const *Handle() const { return job_; }
        bool Running() const;
        /* Why an import produced nothing, one sentence ready to show. Empty on
         * success, on cancel, and on a partial result (what landed is a
         * library). Valid once Running() is false. */
        std::string Error() const;
        /* Every VECTOR chart archive that finished — what the open takes.
         * Valid once Running() is false. */
        std::vector<std::string> Finished() const;
        /* What landed, of one kind. */
        std::vector<std::string> Landed(bool raster) const;
        /* Every baked raster sheet — these belong to the raster underlay
         * (lookout_raster_add), never to the vector open. */
        std::vector<std::string> FinishedRasters() const;

    private:
        /* The paths the bake was given, in the order the engine runs them, and
         * whether each is a picture. What landed is read off the disk when the
         * bake stops: the engine counts charts, and which of them are pictures
         * is the shell's question. */
        std::vector<std::string> out_paths_;
        std::vector<char> is_raster_;
        std::string source_name_;
        long long started_ms_ = 0;
        bool cancelled_ = false;
        lookout_bake *job_ = nullptr;
    };
}
