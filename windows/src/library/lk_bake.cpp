#include "lk_bake.h"

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cstdio>
#include <filesystem>
#include <map>

extern "C"
{
#include "tile57.h"
}

namespace lkw
{
    namespace
    {
        long long NowMs()
        {
            using namespace std::chrono;
            return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
        }

        std::string LowerExt(std::string const &path)
        {
            std::string ext = std::filesystem::path(path).extension().string();
            std::transform(ext.begin(), ext.end(), ext.begin(),
                           [](unsigned char c) { return (char)std::tolower(c); });
            return ext;
        }

        /* What has to happen to one file before it can be drawn. A file that
         * is a chart already only has to come out of the archive. */
        lookout_prepare PrepareOf(ScannedCell const &c)
        {
            if (c.kind == LOOKOUT_FILE_SOURCE)
                return LOOKOUT_PREPARE_CELL;
            if (c.kind == LOOKOUT_FILE_RASTER_SOURCE)
                return LOOKOUT_PREPARE_SHEET;
            return LOOKOUT_PREPARE_LIFT;
        }

        /* A picture belongs to the raster underlay rather than the vector
         * open, whichever way it got there. */
        bool IsPicture(lookout_file_kind kind)
        {
            return kind == LOOKOUT_FILE_RASTER || kind == LOOKOUT_FILE_RASTER_SOURCE;
        }
    }

    bool IsArchive(std::string const &path)
    {
        return LowerExt(path) == ".zip";
    }

    std::string BakeProgress::Title() const
    {
        if (kind == WorkKind::Finding || total == 0)
            return "Finding charts in " + name;
        return "Importing " + name;
    }

    std::string BakeProgress::Remaining() const
    {
        if (done < 3 || total <= done || elapsed <= 1.0)
            return {};
        double per = elapsed / (double)done;
        double left = per * (double)(total - done);
        if (left < 60)
            return "under a minute left";
        if (left < 3600)
            return "about " + std::to_string((int)(left / 60 + 0.5)) + " min left";
        char buf[64];
        snprintf(buf, sizeof buf, "about %.1f h left", left / 3600.0);
        return buf;
    }

    ScanResult ScanCharts(std::string const &path)
    {
        ScanResult out;
        /* A read is the caller's own copy, so two scans may run at once. */
        const bool zip = IsArchive(path);
        lookout_scan *scan = zip ? lookout_scan_zip_read(path.c_str())
                                 : lookout_scan_read(path.c_str());
        if (scan == nullptr)
            return out;

        out.ok = true;
        if (lookout_scan_summary const *found = lookout_scan_found(scan))
        {
            out.root = found->root;
            out.sources = (unsigned)found->sources;
        }

        /* Inside an archive every entry is archived: `path` is an entry name,
         * and nothing opens until the bake takes it out. */
        for (int half = 0; half < 2; ++half)
        {
            size_t n = 0;
            lookout_chart_file const *const *files =
                half == 0 ? lookout_scan_cells(scan, &n) : lookout_scan_raster(scan, &n);
            for (size_t i = 0; i < n; ++i)
            {
                ScannedCell c;
                c.path = files[i]->path;
                c.name = files[i]->name;
                c.kind = files[i]->kind;
                c.band = files[i]->band;
                c.archived = zip;
                if (!c.path.empty())
                    out.cells.push_back(std::move(c));
            }
        }
        lookout_scan_free(scan);
        return out;
    }

    BakeJob::~BakeJob()
    {
        /* Cancel first, or the free blocks for about one chart's bake time. */
        Cancel();
        if (job_ != nullptr)
            lookout_bake_free(job_);
    }

    void BakeJob::Cancel()
    {
        cancelled_ = true;
        if (job_ != nullptr)
            lookout_bake_cancel(job_);
    }

    bool BakeJob::Running() const
    {
        if (job_ == nullptr)
            return false;
        lookout_bake_progress p{};
        lookout_bake_poll(job_, &p);
        return p.running != 0;
    }

    BakeProgress BakeJob::Snapshot() const
    {
        BakeProgress out;
        out.kind = WorkKind::Importing;
        out.name = source_name_;
        out.cancelled = cancelled_;
        if (job_ == nullptr)
            return out;

        lookout_bake_progress p{};
        lookout_bake_poll(job_, &p);
        out.done = p.done;
        out.total = p.total;
        out.cell = p.chart;
        out.running = p.running != 0;
        out.elapsed = (double)(NowMs() - started_ms_) / 1000.0;
        return out;
    }

    /* An import that produced NOTHING must say why, not just take the panel
     * down: a folder of malformed cells otherwise looks like an app that did
     * nothing. A partial bake is not an error — what landed is a library — so
     * only the all-failed case keeps the message. */
    std::string BakeJob::Error() const
    {
        if (job_ == nullptr || cancelled_)
            return {};
        lookout_bake_progress p{};
        lookout_bake_poll(job_, &p);
        if (p.running != 0 || p.baked != 0 || p.total == 0)
            return {};
        return p.why[0] != '\0' ? std::string(p.why) : "None of the charts could be prepared.";
    }

    /* What landed, read off the disk. The engine counts charts; which of them
     * belongs to the raster underlay rather than the vector open is the
     * shell's question, and an entry an archive did not hold wrote nothing. */
    std::vector<std::string> BakeJob::Finished() const
    {
        return Landed(false);
    }

    std::vector<std::string> BakeJob::FinishedRasters() const
    {
        return Landed(true);
    }

    std::vector<std::string> BakeJob::Landed(bool raster) const
    {
        std::vector<std::string> out;
        for (size_t i = 0; i < out_paths_.size(); ++i)
        {
            if ((is_raster_[i] != 0) != raster)
                continue;
            std::error_code ec;
            if (std::filesystem::exists(out_paths_[i], ec))
                out.push_back(out_paths_[i]);
        }
        return out;
    }

    bool BakeJob::Start(ScanResult const &scan, std::string const &source, std::string const &out_dir,
                        std::string const &raster_out_dir)
    {
        std::vector<ScannedCell> work;
        for (auto const &c : scan.cells)
            if (c.NeedsPrepare())
                work.push_back(c);
        if (work.empty())
            return false;

        /* Coarse band first, so a cancel leaves usable coverage of the whole
         * passage rather than every berth in one river. The order is also what
         * makes the phases contiguous for lookout_bake_start. */
        std::vector<lookout_bake_item> items;
        std::map<std::string, lookout_file_kind> kinds;
        items.reserve(work.size());
        for (auto const &c : work)
        {
            items.push_back({ c.path.c_str(), c.name.c_str(), c.band, PrepareOf(c) });
            kinds[c.path] = c.kind;
        }
        lookout_bake_order(items.data(), items.size());

        /* A cell bakes into the chart library and a sheet into the raster one:
         * separate roots, because the vector open globs the chart library for
         * .pmtiles and a picture archive it swallowed would join the composed
         * chart library. */
        out_paths_.clear();
        is_raster_.clear();
        std::vector<std::string> ins;
        for (auto const &item : items)
        {
            const bool raster = IsPicture(kinds[item.path]);
            char buf[1024];
            size_t n = lookout_bake_output_path(raster ? raster_out_dir.c_str() : out_dir.c_str(),
                                                source.c_str(), &item, buf, sizeof buf);
            if (n == 0)
                return false;
            std::error_code ec;
            std::filesystem::create_directories(std::filesystem::path(buf).parent_path(), ec);
            out_paths_.push_back(buf);
            is_raster_.push_back(raster ? 1 : 0);
            ins.push_back(item.path);
        }

        /* Kind-contiguous after the order, and each engine phase takes its own
         * run: the cells, then the sheets, then the lift. */
        size_t cells = 0, sheets = 0;
        for (auto const &item : items)
        {
            if (item.work == LOOKOUT_PREPARE_CELL)
                ++cells;
            else if (item.work == LOOKOUT_PREPARE_SHEET)
                ++sheets;
        }

        std::vector<char const *> in_c, out_c;
        for (size_t i = 0; i < ins.size(); ++i)
        {
            in_c.push_back(ins[i].c_str());
            out_c.push_back(out_paths_[i].c_str());
        }

        source_name_ = std::filesystem::path(source).filename().string();
        started_ms_ = NowMs();
        cancelled_ = false;
        job_ = lookout_bake_start(source.c_str(), in_c.data(), out_c.data(), cells, sheets,
                                  items.size() - cells - sheets, IsArchive(source) ? 1 : 0);
        return job_ != nullptr;
    }
}
