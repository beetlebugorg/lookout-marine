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
                row.charts = all[i]->charts;
                row.pictures = all[i]->pictures;
                row.held_back = all[i]->held_back;
                for (int b = 1; b <= 6; ++b)
                    if (all[i]->band_count[b - 1] != 0)
                        row.bands[b] = all[i]->band_count[b - 1];
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
