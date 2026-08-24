#include "pch.h"

#include "lk_bake.h"

#include <algorithm>
#include <chrono>
#include <filesystem>

extern "C"
{
#include "lookout.h"
#include "tile57.h"
}

using namespace winrt::Windows::Data::Json;

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

        /* The engine bakes a cell before a sheet before a lift, and each engine
         * call takes one contiguous run, so this is both the mariner's order and
         * the call boundary. */
        int Rank(ScannedCell const &c)
        {
            if (c.kind == "source")
                return 0;
            if (c.kind == "raster_source")
                return 1;
            return 2;
        }

        std::string JsonString(JsonObject const &o, wchar_t const *key)
        {
            if (!o.HasKey(key))
                return {};
            auto v = o.GetNamedValue(key);
            if (v.ValueType() != JsonValueType::String)
                return {};
            return winrt::to_string(v.GetString());
        }

        int JsonInt(JsonObject const &o, wchar_t const *key)
        {
            if (!o.HasKey(key))
                return 0;
            auto v = o.GetNamedValue(key);
            if (v.ValueType() != JsonValueType::Number)
                return 0;
            return (int)v.GetNumber();
        }

        /* tile57's callbacks take a void* context; both forward to the job. */
        bool ProgressThunk(void *ctx, uint32_t done, uint32_t total)
        {
            return ((BakeJob *)ctx)->OnProgress(done, total);
        }
        void LabelThunk(void *ctx, uint32_t index)
        {
            ((BakeJob *)ctx)->OnLabel(index);
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
        size_t len = 0;
        /* Both scans share one buffer inside the core and are NOT reentrant, so
         * this must stay on one thread. It runs before the bake thread starts. */
        char const *json = IsArchive(path) ? lookout_scan_zip(path.c_str(), &len)
                                           : lookout_scan_charts(path.c_str(), &len);
        if (json == nullptr || len == 0)
            return out;

        JsonObject root{ nullptr };
        if (!JsonObject::TryParse(winrt::to_hstring(std::string(json, len)), root))
            return out;

        out.ok = true;
        out.root = JsonString(root, L"root");
        out.sources = (unsigned)JsonInt(root, L"sources");

        /* Inside an archive every entry is archived: `path` is an entry name,
         * and nothing opens until the bake takes it out. */
        const bool zip = IsArchive(path);
        for (wchar_t const *key : { L"cells", L"raster" })
        {
            if (!root.HasKey(key))
                continue;
            auto arr = root.GetNamedArray(key);
            for (uint32_t i = 0; i < arr.Size(); ++i)
            {
                auto o = arr.GetObjectAt(i);
                ScannedCell c;
                c.path = JsonString(o, L"path");
                c.name = JsonString(o, L"name");
                c.kind = JsonString(o, L"kind");
                c.band = JsonInt(o, L"band");
                c.archived = zip;
                if (!c.path.empty())
                    out.cells.push_back(std::move(c));
            }
        }
        return out;
    }

    BakeJob::~BakeJob()
    {
        Cancel();
        if (thread_.joinable())
            thread_.join();
    }

    void BakeJob::Cancel()
    {
        cancel_.store(true);
        std::lock_guard<std::mutex> g(mu_);
        p_.cancelled = true;
    }

    BakeProgress BakeJob::Snapshot() const
    {
        std::lock_guard<std::mutex> g(mu_);
        BakeProgress p = p_;
        p.running = running_.load();
        if (started_ms_ != 0)
            p.elapsed = (double)(NowMs() - started_ms_) / 1000.0;
        return p;
    }

    std::string BakeJob::Error() const
    {
        std::lock_guard<std::mutex> g(mu_);
        return error_;
    }

    std::vector<std::string> BakeJob::Finished() const
    {
        std::lock_guard<std::mutex> g(mu_);
        return finished_;
    }

    std::vector<std::string> BakeJob::FinishedRasters() const
    {
        std::lock_guard<std::mutex> g(mu_);
        return finished_rasters_;
    }

    bool BakeJob::OnProgress(unsigned done, unsigned total)
    {
        {
            std::lock_guard<std::mutex> g(mu_);
            p_.kind = WorkKind::Importing;
            p_.done = done + offset_;
            p_.total = job_total_ > 0 ? job_total_ : total;
        }
        return !cancel_.load();
    }

    void BakeJob::OnLabel(unsigned index)
    {
        std::lock_guard<std::mutex> g(mu_);
        size_t i = (size_t)index + offset_;
        if (i >= out_paths_.size())
            return;
        /* ordered_ and out_paths_ run in step, so the kind rides on the index:
         * a baked sheet is a picture for the raster underlay, never a chart
         * for the vector open. */
        if (ordered_[i].kind == "raster_source")
            finished_rasters_.push_back(out_paths_[i]);
        else
            finished_.push_back(out_paths_[i]);
        p_.cell = std::filesystem::path(out_paths_[i]).stem().string();
    }

    bool BakeJob::Start(ScanResult const &scan, std::string const &source, std::string const &out_dir,
                        std::string const &raster_out_dir)
    {
        ordered_.clear();
        for (auto const &c : scan.cells)
            if (c.NeedsPrepare())
                ordered_.push_back(c);
        if (ordered_.empty())
            return false;

        /* Coarse band first, so a cancel leaves usable coverage of the whole
         * passage rather than every berth in one river. */
        std::sort(ordered_.begin(), ordered_.end(), [](ScannedCell const &a, ScannedCell const &b) {
            if (Rank(a) != Rank(b))
                return Rank(a) < Rank(b);
            if (a.band != b.band)
                return a.band < b.band;
            return a.name < b.name;
        });

        /* Every prepared chart goes in a directory of its own name, which is the
         * layout tile57's own bake writes and the layout an exchange set uses. A
         * cell carries the text and pictures it references beside it, and the
         * engine only writes those when the chart has a directory to hold them;
         * written flat they would share one manifest and overwrite each other.
         *
         * From an archive the output MIRRORS the entry's own path, so what comes
         * out is laid out like what went in. An exchange set already puts each
         * cell in a directory of its name, so appending the stem again would give
         * US1EEZ3M/US1EEZ3M/US1EEZ3M.pmtiles. */
        const bool zip = IsArchive(source);
        out_paths_.clear();
        out_paths_.reserve(ordered_.size());
        for (auto const &c : ordered_)
        {
            std::filesystem::path stem = std::filesystem::path(c.name).stem();
            const bool raster = (c.kind == "raster_source" || c.kind == "raster");
            std::filesystem::path base = raster ? raster_out_dir : out_dir;
            if (zip)
            {
                std::filesystem::path rel = std::filesystem::path(c.path).parent_path();
                if (!rel.empty())
                    base /= rel;
            }
            /* A lift keeps the entry's own name in the mirrored directory: it
             * is a chart already, and the stem directory is for what a bake
             * writes beside a cell. */
            const bool lift = Rank(c) == 2;
            std::filesystem::path dir = (lift || base.filename() == stem) ? base : base / stem;
            std::error_code ec;
            std::filesystem::create_directories(dir, ec);
            std::string fname = lift ? std::filesystem::path(c.path).filename().string()
                                     : stem.string() + ".pmtiles";
            out_paths_.push_back((dir / fname).string());
        }

        {
            std::lock_guard<std::mutex> g(mu_);
            p_ = BakeProgress{};
            p_.kind = WorkKind::Importing;
            p_.name = std::filesystem::path(source).filename().string();
            p_.total = (unsigned)ordered_.size();
            finished_.clear();
            finished_rasters_.clear();
        }
        job_total_ = (unsigned)ordered_.size();
        offset_ = 0;
        started_ms_ = NowMs();
        cancel_.store(false);
        running_.store(true);
        thread_ = std::thread(&BakeJob::Run, this, source, out_dir);
        return true;
    }

    void BakeJob::Run(std::string source, std::string out_dir)
    {
        (void)out_dir;
        const bool zip = IsArchive(source);
        /* A MEMORY bound, not a speed dial: each worker holds a whole cell's
         * working set. */
        unsigned hw = std::thread::hardware_concurrency();
        uint32_t workers = (uint32_t)std::max(1u, std::min(8u, hw ? hw : 4u));

        std::vector<char const *> ins, outs;
        ins.reserve(ordered_.size());
        outs.reserve(ordered_.size());
        for (size_t i = 0; i < ordered_.size(); ++i)
        {
            ins.push_back(ordered_[i].path.c_str());
            outs.push_back(out_paths_[i].c_str());
        }

        /* Sorted by kind, so each is one contiguous run and each engine call
         * takes exactly its own. */
        size_t cells = 0;
        while (cells < ordered_.size() && Rank(ordered_[cells]) == 0)
            ++cells;
        size_t sheets = 0;
        while (cells + sheets < ordered_.size() && Rank(ordered_[cells + sheets]) == 1)
            ++sheets;

        tile57_error err{};
        uint32_t baked_total = 0;
        auto run = [&](size_t off, size_t n, bool raster) {
            if (n == 0 || cancel_.load())
                return;
            offset_ = (unsigned)off;
            uint32_t baked = 0;
            if (zip)
            {
                if (raster)
                    tile57_bake_zip_rasters(source.c_str(), ins.data() + off, outs.data() + off, n,
                                            workers, ProgressThunk, LabelThunk, this, &baked, &err);
                else
                    tile57_bake_zip_charts(source.c_str(), ins.data() + off, outs.data() + off, n,
                                           workers, ProgressThunk, LabelThunk, this, &baked, &err);
            }
            else
            {
                if (raster)
                    tile57_bake_rasters(ins.data() + off, outs.data() + off, n, workers,
                                        ProgressThunk, LabelThunk, this, &baked, &err);
                else
                    tile57_bake_files(ins.data() + off, outs.data() + off, n, workers,
                                      ProgressThunk, LabelThunk, this, &baked, &err);
            }
            baked_total += baked;
        };

        run(0, cells, false);
        run(cells, sheets, true);

        /* The lift: entries that are charts already and only have to come out
         * of the archive. Serial in the engine; no label callback, so the
         * finished lists are settled from what actually landed — an entry the
         * archive does not hold is skipped and writes nothing. */
        const size_t lifts = ordered_.size() - cells - sheets;
        if (zip && lifts != 0 && !cancel_.load())
        {
            const size_t off = cells + sheets;
            offset_ = (unsigned)off;
            uint32_t done = 0;
            tile57_zip_extract(source.c_str(), ins.data() + off, outs.data() + off, lifts,
                               ProgressThunk, this, &done, &err);
            std::lock_guard<std::mutex> g(mu_);
            for (size_t i = off; i < ordered_.size(); ++i)
            {
                std::error_code ec;
                if (!std::filesystem::exists(out_paths_[i], ec))
                    continue;
                if (ordered_[i].kind == "raster")
                    finished_rasters_.push_back(out_paths_[i]);
                else
                    finished_.push_back(out_paths_[i]);
            }
        }

        /* An import that produced NOTHING must say why, not just take the
         * panel down: a folder of malformed cells otherwise looks like an app
         * that did nothing. A partial bake is not an error — what landed is a
         * library — so only the all-failed case keeps the message. */
        if (!cancel_.load() && baked_total == 0 && (cells + sheets) != 0)
        {
            std::lock_guard<std::mutex> g(mu_);
            error_ = err.message[0] != '\0'
                         ? err.message
                         : "None of the charts could be prepared.";
        }

        running_.store(false);
    }
}
