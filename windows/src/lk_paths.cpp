#include "pch.h"
#include "lk_paths.h"

#include <algorithm>
#include <filesystem>

#include "lk_store.h"

namespace lkw
{
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
