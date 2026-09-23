// Model code: no WinRT. See lk_chart_sets.h.
#include "lk_chart_sets.h"

#include <filesystem>
#include <thread>

#include "lk_paths.h"
#include "lk_store.h"

namespace lkw
{
    // The model, opened on the first ask and kept for the window. It needs no
    // chart handle: the sets exist before anything is open, and the empty
    // state is drawn from them.
    lookout_chart_sets *ChartSets::Model()
    {
        if (model_ == nullptr)
        {
            model_ = lookout_chart_sets_open(lk_store_handle(), ChartLibraryDir().c_str());
            // The library directory was the managed set before it became
            // prepared_root. Its row stays listed as a set the mariner can
            // remove.
            if (model_ != nullptr)
                lookout_chart_sets_set_managed(model_, ChartLibraryDir().c_str(), 0);
            // What a removal left when the app ended during its delete: in the
            // library, and beside it where earlier builds renamed to.
            std::thread([lib = std::filesystem::path(ChartLibraryDir())] {
                lookout_bake_sweep(lib.string().c_str());
                lookout_bake_sweep(lib.parent_path().string().c_str());
            }).detach();
        }
        return model_;
    }

    // The list itself is there at once. The metadata arrives later, announced
    // by lookout_chart_sets_changed.
    void ChartSets::Load()
    {
        rows_.clear();
        if (lookout_chart_sets *model = Model())
        {
            size_t n = 0;
            lookout_chart_set const *const *all = lookout_chart_sets_all(model, &n);
            for (size_t i = 0; i < n; ++i)
            {
                lkw::ChartSetRow row;
                row.path = all[i]->path;
                row.title = all[i]->title;
                row.on = all[i]->on != 0;
                row.managed = all[i]->managed != 0;
                row.scanned = all[i]->scanned != 0;
                row.unprepared = all[i]->unprepared;
                row.to_prepare = all[i]->to_prepare;
                row.refused = all[i]->refused;
                for (size_t b = 0; b < 6; ++b)
                    row.band_todo[b] = all[i]->band_todo[b];
                row.bytes = all[i]->bytes;
                // What the row says it holds. The engine's own counts split a
                // file that bakes first out of both halves, and this line has
                // always counted a picture waiting to be baked as a picture.
                size_t files = 0;
                std::vector<std::string> names;
                auto found = lookout_chart_set_files(model, all[i]->path, &files);
                for (size_t f = 0; f < files; ++f)
                {
                    switch (found[f]->kind)
                    {
                    case LOOKOUT_FILE_RASTER:
                    case LOOKOUT_FILE_RASTER_SOURCE: row.pictures++; break;
                    case LOOKOUT_FILE_BAKED:
                        row.charts++;
                        names.push_back(found[f]->name);
                        if (found[f]->band >= 1 && found[f]->band <= 6)
                            ++row.bands[found[f]->band];
                        break;
                    default:                         break;
                    }
                }
                // The office whose charts these are, when the core fell back
                // to the folder's own name. A NOAA library baked into the
                // app's chart folder read as "Charts", which names where the
                // files are rather than whose they are.
                std::string const folder =
                    std::filesystem::path(row.path).filename().string();
                if (row.title == folder && !names.empty())
                {
                    std::string agency = AgencyForCells(names);
                    if (!agency.empty())
                        row.title = agency;
                }
                rows_.push_back(std::move(row));
            }
        }
    }

    bool ChartSets::Scanning() const
    {
        for (auto const &s : rows_)
            if (!s.scanned)
                return true;
        return false;
    }

    // Sorted, with duplicates dropped: two sets may overlap, and the same
    // cell twice would be composed twice.
    std::vector<std::string> ChartSets::Compose()
    {
        std::vector<std::string> out;
        lookout_chart_sets *model = Model();
        if (model == nullptr)
            return out;
        size_t n = 0;
        char const *const *paths = lookout_chart_sets_compose(model, &n);
        for (size_t i = 0; i < n; ++i)
            out.push_back(paths[i]);
        return out;
    }

    void ChartSets::Close()
    {
        if (model_ == nullptr)
            return;
        lookout_chart_sets_close(model_);
        model_ = nullptr;
    }
}
