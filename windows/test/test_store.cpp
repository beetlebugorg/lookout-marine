/* What the shell writes down.
 *
 * The store is where a mariner's own decisions live between launches: where
 * the camera was, which chart sets are aboard, which pictures they switched
 * off, what the display settings are. Two things matter more than the rest:
 *
 *   - A pose that would strand the camera is REFUSED at load, not saved and
 *     restored into. The envelope is what a marine chart can contain.
 *   - The mariner state is applied KEY BY KEY, so a settings file written by
 *     an older build leaves the fields it never knew about at the engine's
 *     defaults instead of zeroing them.
 */
#include "lk_test.h"

#include <filesystem>
#include <fstream>
#include <string>

extern "C" {
#include "lk_store.h"
}

using namespace lktest;

namespace
{
    namespace fs = std::filesystem;

    /* The store is pointed at a directory of its own before anything reads
     * it, so a test never touches the profile it is running under. */
    std::string TempStoreDir()
    {
        std::error_code ec;
        fs::path dir = fs::temp_directory_path(ec) / "lk-test-store";
        fs::remove_all(dir, ec);
        fs::create_directories(dir, ec);
        return dir.string();
    }

    int RecentsCount(char **list)
    {
        int n = 0;
        for (; list != nullptr && list[n] != nullptr; n++)
            ;
        return n;
    }
}

void TestStore()
{
    lk_store_set_dir(TempStoreDir().c_str());

    Suite("lk_store: the camera pose");

    LK_CASE("a pose round-trips");
    {
        lookout_view saved{};
        saved.lon = -76.4767;
        saved.lat = 38.9763;
        saved.zoom = 15.5;
        saved.rotation_deg = 42;
        lk_store_save_view(&saved);

        lookout_view back{};
        LK_EQ(lk_store_load_view(&back), 1);
        LK_NEAR(back.lon, -76.4767, 1e-9);
        LK_NEAR(back.lat, 38.9763, 1e-9);
        LK_NEAR(back.zoom, 15.5, 1e-9);
        LK_NEAR(back.rotation_deg, 42, 1e-9);
    }

    /* No chart lies above ~84°, and that bound alone rejects the corner pose
     * a zoom past the f32 world overrun collapses to. Zoom stops at 19:
     * berthing work sits at z16–19 and must restore. */
    LK_CASE("a pose outside what a chart can contain is refused");
    {
        lookout_view out{};

        lookout_view high{ -76, 85.0, 15, 0 };
        lk_store_save_view(&high);
        LK_EQ(lk_store_load_view(&out), 0);

        lookout_view deep{ -76, 38.9, 19.5, 0 };
        lk_store_save_view(&deep);
        LK_EQ(lk_store_load_view(&out), 0);

        lookout_view off_world{ 181, 38.9, 15, 0 };
        lk_store_save_view(&off_world);
        LK_EQ(lk_store_load_view(&out), 0);
    }

    /* The Aleutians cross the dateline, so longitude keeps the full ±180. */
    LK_CASE("the edges that are still places");
    {
        lookout_view out{};
        lookout_view edge{ -180, 84, 19, 359 };
        lk_store_save_view(&edge);
        LK_EQ(lk_store_load_view(&out), 1);
    }

    Suite("lk_store: recents");

    LK_CASE("most recent first, deduped, capped");
    {
        lk_store_note_recent("C:\\charts\\a.pmtiles");
        lk_store_note_recent("C:\\charts\\b.pmtiles");
        lk_store_note_recent("C:\\charts\\a.pmtiles"); /* again: it moves to the front */

        char **list = lk_store_load_recents();
        LK_EQ(RecentsCount(list), 2);
        if (RecentsCount(list) == 2)
        {
            LK_EQ(std::string(list[0]), std::string("C:\\charts\\a.pmtiles"));
            LK_EQ(std::string(list[1]), std::string("C:\\charts\\b.pmtiles"));
        }
        lk_store_free_recents(list);

        for (int i = 0; i < 20; i++)
            lk_store_note_recent(("C:\\charts\\" + std::to_string(i) + ".pmtiles").c_str());
        list = lk_store_load_recents();
        LK_EQ(RecentsCount(list) <= 10, true);
        lk_store_free_recents(list);
    }

    LK_CASE("an empty path is not a recent");
    {
        char **before = lk_store_load_recents();
        int n = RecentsCount(before);
        lk_store_free_recents(before);

        lk_store_note_recent("");
        lk_store_note_recent(nullptr);

        char **after = lk_store_load_recents();
        LK_EQ(RecentsCount(after), n);
        lk_store_free_recents(after);
    }

    Suite("lk_store: the raster library");

    LK_CASE("added, switched off, forgotten");
    {
        lk_store_clear_rasters();
        lk_store_note_raster("C:\\r\\a.mbtiles");
        lk_store_note_raster("C:\\r\\b.mbtiles");

        int *on = nullptr;
        char **paths = lk_store_load_rasters(&on);
        LK_EQ(RecentsCount(paths), 2);
        if (RecentsCount(paths) == 2)
        {
            LK_EQ(std::string(paths[0]), std::string("C:\\r\\a.mbtiles"));
            LK_EQ(on[0], 1); /* a chart added is a chart drawn */
            LK_EQ(on[1], 1);
        }
        lk_store_free_rasters(paths, on);

        /* Switched off, not deleted: half a gigabyte is not thrown away
         * because it is not today's water. */
        lk_store_set_raster_enabled("C:\\r\\a.mbtiles", 0);
        paths = lk_store_load_rasters(&on);
        LK_EQ(RecentsCount(paths), 2);
        if (RecentsCount(paths) == 2)
        {
            LK_EQ(on[0], 0);
            LK_EQ(on[1], 1);
        }
        lk_store_free_rasters(paths, on);

        lk_store_forget_raster("C:\\r\\a.mbtiles");
        paths = lk_store_load_rasters(&on);
        LK_EQ(RecentsCount(paths), 1);
        lk_store_free_rasters(paths, on);
    }

    /* A baked bundle is hundreds of sheets: one load and one save, whatever
     * the count. */
    LK_CASE("a batch add, and a batch forget");
    {
        lk_store_clear_rasters();
        char const *batch[] = { "C:\\r\\1.pmtiles", "C:\\r\\2.pmtiles", "C:\\r\\3.pmtiles",
                                "C:\\r\\1.pmtiles" /* a duplicate inside the batch */ };
        lk_store_note_rasters(batch, 4);

        int *on = nullptr;
        char **paths = lk_store_load_rasters(&on);
        LK_EQ(RecentsCount(paths), 3);
        lk_store_free_rasters(paths, on);

        lk_store_forget_rasters(batch, 2);
        paths = lk_store_load_rasters(&on);
        LK_EQ(RecentsCount(paths), 1);
        lk_store_free_rasters(paths, on);
    }

    /* The hidden list is keyed by set NAME, so a library that is forgotten
     * takes its hidden entries with it — the same file added again months
     * later must not come back not drawn with nothing on screen to say why. */
    LK_CASE("forgetting the library forgets what was hidden in it");
    {
        lk_store_clear_rasters();
        lk_store_note_raster("C:\\r\\a.mbtiles");
        char const *hidden[] = { "OpenSeaMap" };
        lk_store_save_hidden_sets(hidden, 1);

        char **names = lk_store_load_hidden_sets();
        LK_EQ(RecentsCount(names), 1);
        lk_store_free_recents(names);

        lk_store_clear_rasters();
        names = lk_store_load_hidden_sets();
        LK_EQ(RecentsCount(names), 0);
        lk_store_free_recents(names);
    }

    LK_CASE("the ENC-over-raster switch");
    {
        lk_store_set_chart_hidden(1);
        LK_EQ(lk_store_chart_hidden(), 1);
        lk_store_set_chart_hidden(0);
        LK_EQ(lk_store_chart_hidden(), 0);
    }

    Suite("lk_store: the chart sets aboard");

    LK_CASE("a set is switched off, not removed");
    {
        lk_store_note_chartset("C:\\charts\\NOAA");
        lk_store_note_chartset("C:\\charts\\UKHO");

        int *on = nullptr;
        char **paths = lk_store_load_chartsets(&on);
        LK_EQ(RecentsCount(paths), 2);
        if (RecentsCount(paths) == 2)
            LK_EQ(on[0], 1);
        lk_store_free_rasters(paths, on);

        lk_store_set_chartset_on("C:\\charts\\NOAA", 0);
        paths = lk_store_load_chartsets(&on);
        LK_EQ(RecentsCount(paths), 2);
        if (RecentsCount(paths) == 2)
        {
            LK_EQ(on[0], 0);
            LK_EQ(on[1], 1);
        }
        lk_store_free_rasters(paths, on);

        /* Aboard already: its switch is the mariner's, not the adder's. */
        lk_store_note_chartset("C:\\charts\\NOAA");
        paths = lk_store_load_chartsets(&on);
        LK_EQ(RecentsCount(paths), 2);
        if (RecentsCount(paths) == 2)
            LK_EQ(on[0], 0);
        lk_store_free_rasters(paths, on);

        lk_store_forget_chartset("C:\\charts\\NOAA");
        paths = lk_store_load_chartsets(&on);
        LK_EQ(RecentsCount(paths), 1);
        lk_store_free_rasters(paths, on);
    }

    Suite("lk_store: charts by link");

    LK_CASE("the list, and which one is picked");
    {
        lk_store_save_chartlinks(R"([{"url":"https://example.invalid/style.json"}])");
        char *back = lk_store_load_chartlinks();
        LK_CHECK(back != nullptr);
        if (back != nullptr)
        {
            LK_EQ(std::string(back), std::string(R"([{"url":"https://example.invalid/style.json"}])"));
            free(back);
        }

        char url[512] = { 0 };
        LK_EQ(lk_store_load_chartlink_active(url, sizeof url), 0); /* the built-in chart */
        lk_store_save_chartlink_active("https://example.invalid/style.json");
        LK_EQ(lk_store_load_chartlink_active(url, sizeof url), 1);
        LK_EQ(std::string(url), std::string("https://example.invalid/style.json"));

        lk_store_save_chartlink_active("");
        LK_EQ(lk_store_load_chartlink_active(url, sizeof url), 0);
    }

    Suite("lk_store: the mariner's settings");

    /* The engine's own defaults are the engine's to state, and nothing here
     * links it — so a struct filled with values no default has stands in for
     * them, and what the test watches is which of them survive. */
    LK_CASE("saved field by field, and applied back");
    {
        tile57_mariner m{};
        m.scheme = (tile57_scheme)2;
        m.safety_contour = 7.5;
        m.deep_contour = 33.25;
        m.four_shade_water = true;
        m.text_names = false;
        m.size_scale = 1.25;
        m.text_size_scale = 1.75;
        m.boundary_style = (tile57_boundary_style)1;
        lk_store_save_mariner(&m);

        tile57_mariner back{};
        lk_store_apply_saved_mariner(&back);
        LK_EQ((int)back.scheme, 2);
        LK_NEAR(back.safety_contour, 7.5, 1e-9);
        LK_NEAR(back.deep_contour, 33.25, 1e-9);
        LK_EQ(back.four_shade_water, true);
        LK_EQ(back.text_names, false);
        LK_NEAR(back.size_scale, 1.25, 1e-9);
        LK_NEAR(back.text_size_scale, 1.75, 1e-9);
        LK_EQ((int)back.boundary_style, 1);
    }

    /* A settings file written by an older build must leave the fields it
     * never knew about at the engine's defaults, not at zero. Written by hand
     * because that is the only way to have a file that is missing a key. */
    LK_CASE("a key that was never written leaves the value alone");
    {
        std::error_code ec;
        fs::path dir = fs::temp_directory_path(ec) / "lk-test-store-old";
        fs::remove_all(dir, ec);
        fs::create_directories(dir, ec);
        {
            std::ofstream ini(dir / "settings.ini");
            ini << "[mariner.v1]\nscheme=2\n";
        }
        lk_store_set_dir(dir.string().c_str());

        tile57_mariner back{};
        back.deep_contour = 33.25;   /* stands in for an engine default */
        back.text_size_scale = 1.75;
        back.four_shade_water = true;
        lk_store_apply_saved_mariner(&back);

        LK_EQ((int)back.scheme, 2); /* the one key the file carried */
        LK_NEAR(back.deep_contour, 33.25, 1e-9);
        LK_NEAR(back.text_size_scale, 1.75, 1e-9);
        LK_EQ(back.four_shade_water, true);
    }

    /* A stored 0 for a size scale would black out every symbol on the chart. */
    LK_CASE("a size scale of zero is not applied");
    {
        std::error_code ec;
        fs::path dir = fs::temp_directory_path(ec) / "lk-test-store-zero";
        fs::remove_all(dir, ec);
        fs::create_directories(dir, ec);
        {
            std::ofstream ini(dir / "settings.ini");
            ini << "[mariner.v1]\nsize_scale=0\ntext_size_scale=0\n"
                   "sounding_size_scale=0\nsafety_contour=0\n";
        }
        lk_store_set_dir(dir.string().c_str());

        tile57_mariner back{};
        back.size_scale = 1.0;
        back.text_size_scale = 1.0;
        back.sounding_size_scale = 1.0;
        back.safety_contour = 10.0;
        lk_store_apply_saved_mariner(&back);

        LK_NEAR(back.size_scale, 1.0, 1e-9);
        LK_NEAR(back.text_size_scale, 1.0, 1e-9);
        LK_NEAR(back.sounding_size_scale, 1.0, 1e-9);
        /* A contour of zero IS a value: the surface is a real depth. */
        LK_NEAR(back.safety_contour, 0.0, 1e-9);
    }

    /* Back to a store of this suite's own for whatever follows. */
    lk_store_set_dir(TempStoreDir().c_str());

    Suite("lk_store: window frames");

    LK_CASE("a named window opens where it was left");
    {
        int w = 0, h = 0;
        LK_EQ(lk_store_load_frame("table-org.beetlebug.ais-targets", &w, &h), 0);
        lk_store_save_frame("table-org.beetlebug.ais-targets", 900, 600);
        LK_EQ(lk_store_load_frame("table-org.beetlebug.ais-targets", &w, &h), 1);
        LK_EQ(w, 900);
        LK_EQ(h, 600);

        /* A size nobody could use is not a size. */
        lk_store_save_frame("table-org.beetlebug.ais-targets", 0, -1);
        LK_EQ(lk_store_load_frame("table-org.beetlebug.ais-targets", &w, &h), 1);
        LK_EQ(w, 900);
    }

    LK_CASE("the settings window's own size");
    {
        int w = 0, h = 0;
        lk_store_save_settings_size(720, 560);
        LK_EQ(lk_store_load_settings_size(&w, &h), 1);
        LK_EQ(w, 720);
        LK_EQ(h, 560);
    }
}
