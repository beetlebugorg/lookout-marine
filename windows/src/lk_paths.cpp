#include "pch.h"
#include "lk_paths.h"

#include <shlobj.h> // SHGetKnownFolderPath / FOLDERID_LocalAppData

#include <algorithm>
#include <cctype>
#include <filesystem>

#include "lk_store.h"

namespace lkw
{
    std::string ChartLibraryDir()
    {
        wchar_t *base = nullptr;
        std::filesystem::path root;
        if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &base)) && base != nullptr)
            root = std::filesystem::path(base) / L"lookout-marine" / L"Charts";
        if (base != nullptr)
            CoTaskMemFree(base);
        if (root.empty())
            root = std::filesystem::path(".") / "Charts";
        std::error_code ec;
        std::filesystem::create_directories(root, ec);
        return root.string();
    }

    std::vector<std::string> CollectCells(std::string const &dir)
    {
        std::vector<std::string> out;
        std::error_code ec;
        for (auto const &e : std::filesystem::recursive_directory_iterator(dir, ec))
        {
            if (e.is_regular_file(ec) && e.path().extension() == ".pmtiles")
                out.push_back(e.path().string());
        }
        std::sort(out.begin(), out.end());
        return out;
    }

    std::vector<std::string> CellsFor(std::string const &path)
    {
        std::error_code ec;
        if (std::filesystem::is_directory(path, ec))
            return CollectCells(path);
        if (std::filesystem::exists(path, ec))
            return { path };
        return {};
    }

    std::vector<std::string> CollectRasterCharts(std::string const &dir)
    {
        std::vector<std::string> out;
        std::error_code ec;
        for (auto const &e : std::filesystem::recursive_directory_iterator(dir, ec))
        {
            if (!e.is_regular_file(ec))
                continue;
            std::string ext = e.path().extension().string();
            std::transform(ext.begin(), ext.end(), ext.begin(),
                           [](unsigned char c) { return (char)std::tolower(c); });
            if (ext == ".mbtiles" || ext == ".pmtiles")
                out.push_back(e.path().string());
        }
        std::sort(out.begin(), out.end());
        return out;
    }

    namespace
    {
        bool ContainsIgnoreCase(std::string const &hay, std::string const &needle)
        {
            if (needle.empty() || hay.size() < needle.size())
                return false;
            auto it = std::search(hay.begin(), hay.end(), needle.begin(), needle.end(),
                                  [](unsigned char a, unsigned char b) {
                                      return std::tolower(a) == std::tolower(b);
                                  });
            return it != hay.end();
        }

        /* A producer this name carries, if any. Longest first, so "OpenSeaMap"
         * is not reported as "OSM" (mirrors raster.zig providerIn). */
        char const *ProviderIn(std::string const &name)
        {
            static char const *known[] = {
                "OpenSeaMap", "Navionics", "Sentinel", "ArcGIS", "Google",
                "C-Map",      "Yandex",    "Imagery",  "Bing",   "ESRI",
                "Esri",       "CMap",      "NAIP",     "SASP",   "OSM",
            };
            for (auto k : known)
                if (ContainsIgnoreCase(name, k))
                    return k;
            return nullptr;
        }
    }

    std::string RasterSetNameFor(std::string const &path)
    {
        std::filesystem::path p(path);
        std::string base = p.filename().string();
        if (auto k = ProviderIn(base))
            return k;

        std::string stem = p.stem().string();

        /* The bake's layout — <root>/<stem>/<stem>.pmtiles: the sheet belongs
         * to the bake, and the bake's own name names the producer when it
         * carries one. */
        if (p.extension() == ".pmtiles")
        {
            auto dir = p.parent_path();
            if (dir.filename().string() == stem)
            {
                std::string root = dir.parent_path().filename().string();
                if (!root.empty())
                {
                    if (auto k = ProviderIn(root))
                        return k;
                    return root;
                }
            }
        }
        return stem.empty() ? base : stem;
    }

    std::vector<std::string> InitialPaths()
    {
        char env[1024];
        DWORD n = GetEnvironmentVariableA("LOOKOUT_OPEN", env, sizeof env);
        if (n > 0 && n < sizeof env)
        {
            auto cells = CellsFor(env);
            if (!cells.empty())
                return cells;
        }
        char **recents = lk_store_load_recents();
        if (recents != nullptr)
        {
            std::string first = recents[0] != nullptr ? recents[0] : "";
            lk_store_free_recents(recents);
            if (!first.empty())
            {
                auto cells = CellsFor(first);
                if (!cells.empty())
                    return cells;
            }
        }
        char exe[MAX_PATH];
        GetModuleFileNameA(nullptr, exe, MAX_PATH);
        std::string dir(exe);
        dir.resize(dir.find_last_of('\\'));
        char full[MAX_PATH];
        std::string demo = dir + "\\..\\..\\..\\android\\app\\src\\main\\assets\\charts\\US5MD1MC.pmtiles";
        if (GetFullPathNameA(demo.c_str(), MAX_PATH, full, nullptr) != 0 &&
            GetFileAttributesA(full) != INVALID_FILE_ATTRIBUTES)
            return { full };
        return {};
    }
}
