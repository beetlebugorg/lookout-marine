// Model code: no WinRT, so the discovery rules are reachable from a test.
#include "lk_paths.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shlobj.h> // SHGetKnownFolderPath / FOLDERID_LocalAppData

#include <algorithm>
#include <cctype>
#include <filesystem>
#include <utility>

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

    namespace
    {
        std::string LowerExtOf(std::filesystem::path const &p)
        {
            std::string ext = p.extension().string();
            std::transform(ext.begin(), ext.end(), ext.begin(),
                           [](unsigned char c) { return (char)std::tolower(c); });
            return ext;
        }
    }

    std::vector<std::string> CollectCells(std::string const &dir)
    {
        std::vector<std::string> out;
        std::error_code ec;
        for (auto const &e : std::filesystem::recursive_directory_iterator(dir, ec))
        {
            if (e.is_regular_file(ec) && LowerExtOf(e.path()) == ".pmtiles")
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
        if (!std::filesystem::exists(path, ec))
            return {};
        /* A raw source file — the .zip an import was baked FROM, a lone .000 —
         * is not a chart the open can draw: it stands for the library its bake
         * filled. Handing it to the vector open gets it skipped as
         * not-a-chart, and the app comes up blank. This holds for every
         * surface a stored recent reaches: startup, the Recents menu, and
         * Settings ▸ Charts. */
        if (LowerExtOf(path) != ".pmtiles")
            return CollectCells(ChartLibraryDir());
        return { path };
    }

    std::string RasterLibraryDir()
    {
        wchar_t *base = nullptr;
        std::filesystem::path root;
        if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &base)) && base != nullptr)
            root = std::filesystem::path(base) / L"lookout-marine" / L"Rasters";
        if (base != nullptr)
            CoTaskMemFree(base);
        if (root.empty())
            root = std::filesystem::path(".") / "Rasters";
        std::error_code ec;
        std::filesystem::create_directories(root, ec);
        return root.string();
    }

    bool IsRasterSource(std::string const &path)
    {
        std::string ext = LowerExtOf(path);
        return ext == ".kap" || ext == ".bsb";
    }

    std::vector<std::string> CollectRasterCharts(std::string const &dir)
    {
        std::vector<std::string> out;
        std::error_code ec;
        for (auto const &e : std::filesystem::recursive_directory_iterator(dir, ec))
        {
            if (!e.is_regular_file(ec))
                continue;
            std::string ext = LowerExtOf(e.path());
            if (ext == ".mbtiles" || ext == ".pmtiles" || ext == ".kap" || ext == ".bsb")
                out.push_back(e.path().string());
        }
        std::sort(out.begin(), out.end());
        return out;
    }

    std::string AgencyForCells(std::vector<std::string> const &cells)
    {
        // The producer code every sampled cell name opens with, else nothing.
        std::string code;
        int sampled = 0;
        for (auto const &p : cells)
        {
            std::string stem = std::filesystem::path(p).stem().string();
            if (stem.size() < 2 || !std::isalpha((unsigned char)stem[0]) ||
                !std::isalpha((unsigned char)stem[1]))
                return {};
            std::string c{ (char)std::toupper((unsigned char)stem[0]),
                           (char)std::toupper((unsigned char)stem[1]) };
            if (code.empty())
                code = c;
            else if (code != c)
                return {};
            if (++sampled >= 64) // a library is one office; the tail agrees
                break;
        }
        // The hydrographic office the code belongs to (ChartSet.agency on
        // macOS). An office not listed keeps its dull name rather than being
        // given one invented here.
        static std::pair<char const *, char const *> const known[] = {
            { "US", "NOAA" }, { "GB", "UKHO" }, { "CA", "CHS" }, { "AU", "AHO" },
            { "NZ", "LINZ" }, { "NL", "Netherlands Hydrographic Office" },
            { "DE", "BSH" }, { "FR", "Shom" },
            { "NO", "Norwegian Hydrographic Service" },
            { "DK", "Danish Geodata Agency" },
            { "SE", "Swedish Maritime Administration" },
            { "FI", "Finnish Transport Agency" }, { "IE", "INFOMAR" },
            { "JP", "Japan Hydrographic Association" }, { "BR", "DHN" },
            { "ZA", "SANHO" },
        };
        for (auto const &[c, name] : known)
            if (code == c)
                return name;
        return {};
    }

    std::vector<std::string> InitialPaths(char const *most_recent, std::string *source_out)
    {
        if (source_out != nullptr)
            source_out->clear();
        char env[1024];
        DWORD n = GetEnvironmentVariableA("LOOKOUT_OPEN", env, sizeof env);
        if (n > 0 && n < sizeof env)
        {
            auto cells = CellsFor(env);
            if (!cells.empty())
            {
                if (source_out != nullptr)
                    *source_out = env;
                return cells;
            }
        }
        {
            std::string first = most_recent != nullptr ? most_recent : "";
            // A recent that names raw source — the .zip an import was baked
            // FROM, noted by builds before the bake learned to note the
            // library — stands for the library the bake filled. Handing the
            // zip to the vector open skips it as not-a-chart and the app
            // comes up blank.
            std::error_code ec;
            if (!first.empty() && !std::filesystem::is_directory(first, ec) &&
                LowerExtOf(first) != ".pmtiles")
                first = ChartLibraryDir();
            if (!first.empty())
            {
                auto cells = CellsFor(first);
                if (!cells.empty())
                {
                    if (source_out != nullptr)
                        *source_out = first;
                    return cells;
                }
            }
        }
        // The repo's own test cell, for a developer running out of the build
        // tree. Every step is checked: this is documented as answering empty
        // for a chart it cannot find, and resize(npos) would throw instead.
        char exe[MAX_PATH];
        DWORD exe_n = GetModuleFileNameA(nullptr, exe, MAX_PATH);
        if (exe_n == 0 || exe_n >= MAX_PATH)
            return {};
        std::string dir(exe, exe_n);
        size_t slash = dir.find_last_of('\\');
        if (slash == std::string::npos)
            return {};
        dir.resize(slash);
        char full[MAX_PATH];
        std::string demo = dir + "\\..\\..\\..\\android\\app\\src\\main\\assets\\charts\\US5MD1MC.pmtiles";
        if (GetFullPathNameA(demo.c_str(), MAX_PATH, full, nullptr) != 0 &&
            GetFileAttributesA(full) != INVALID_FILE_ATTRIBUTES)
            return { full };
        return {};
    }
}
