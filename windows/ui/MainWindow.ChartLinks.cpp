// Charts by link: an online map AS the chart.
//
// lookout owns the whole feature: it probes the link, inlines TileJSON
// sources, generates a wrapper style for bare tiles, fetches the sprite packs,
// builds the credit line, templates the tile urls and persists the list. This
// file is the shell's two halves of it — a WinHTTP fetcher for the urls
// lookout asks for, and the snapshot the Chart list and the scale-bar credit
// render. See lookout.h, lookout_set_http_provider.
#include "pch.h"
#include "MainWindow.xaml.h"

#include <winhttp.h>

#include <condition_variable>
#include <deque>
#include <filesystem>
#include <fstream>
#include <functional>
#include <mutex>
#include <thread>

#include "lk_store.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace winrt::Windows::Data::Json;

namespace
{
    // One HTTP GET, synchronous, on a worker thread. Returns the final HTTP
    // status (0 on transport failure) and fills bytes on a 2xx.
    int FetchUrl(std::wstring const &url, std::vector<uint8_t> &bytes)
    {
        URL_COMPONENTS parts{};
        wchar_t host[256]{}, path[2048]{}, extra[2048]{};
        parts.dwStructSize = sizeof parts;
        parts.lpszHostName = host;
        parts.dwHostNameLength = _countof(host);
        parts.lpszUrlPath = path;
        parts.dwUrlPathLength = _countof(path);
        // The query string is its OWN component; without asking for it here
        // it is silently dropped, and every API-keyed host (?key=…) answers
        // 401 to a request that never carried the key.
        parts.lpszExtraInfo = extra;
        parts.dwExtraInfoLength = _countof(extra);
        if (!WinHttpCrackUrl(url.c_str(), 0, 0, &parts))
            return 0;
        std::wstring object = std::wstring(path) + extra;

        // A unique, identifiable agent with a way to reach the developer:
        // public tile hosts (openstreetmap.org's tile usage policy,
        // osm.wiki/Blocked_tiles) serve "access blocked" placeholder tiles
        // to anonymous or platform-default agents.
        HINTERNET ses = WinHttpOpen(L"LookoutMarine/1.0 (Windows; org.beetlebug.lookout; contact jeremy.collins@beetlebug.org)",
                                    WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
                                    WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
        if (ses == nullptr)
            return 0;
        // A stalled fetch must not hold a worker forever: the chart is drawn
        // from whatever HAS landed, so a slow tile costs only itself.
        WinHttpSetTimeouts(ses, 20000, 20000, 20000, 20000);

        int status = 0;
        HINTERNET con = WinHttpConnect(ses, host, parts.nPort, 0);
        HINTERNET req = nullptr;
        if (con != nullptr)
        {
            DWORD flags = parts.nScheme == INTERNET_SCHEME_HTTPS ? WINHTTP_FLAG_SECURE : 0;
            req = WinHttpOpenRequest(con, L"GET", object.c_str(), nullptr, L"https://beetlebug.org/",
                                     WINHTTP_DEFAULT_ACCEPT_TYPES, flags);
        }
        if (req != nullptr &&
            WinHttpSendRequest(req, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                               WINHTTP_NO_REQUEST_DATA, 0, 0, 0) &&
            WinHttpReceiveResponse(req, nullptr))
        {
            DWORD code = 0, len = sizeof code;
            WinHttpQueryHeaders(req, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                                WINHTTP_HEADER_NAME_BY_INDEX, &code, &len, WINHTTP_NO_HEADER_INDEX);
            status = (int)code;
            if (status >= 200 && status < 300)
            {
                // A hostile or broken host must not be able to stream the app
                // out of memory. Nothing a chart link legitimately fetches
                // comes anywhere near this cap.
                constexpr size_t kFetchCap = size_t{ 64 } << 20;
                DWORD avail = 0;
                while (WinHttpQueryDataAvailable(req, &avail) && avail > 0)
                {
                    if (bytes.size() + avail > kFetchCap)
                    {
                        bytes.clear();
                        status = 0;
                        break;
                    }
                    size_t at = bytes.size();
                    bytes.resize(at + avail);
                    DWORD got = 0;
                    if (!WinHttpReadData(req, bytes.data() + at, avail, &got))
                        break;
                    bytes.resize(at + got);
                    if (got == 0)
                        break;
                }
            }
        }
        if (req != nullptr)
            WinHttpCloseHandle(req);
        if (con != nullptr)
            WinHttpCloseHandle(con);
        WinHttpCloseHandle(ses);
        return status;
    }

    // The path a local url names, or an empty string when it names a host.
    // A mariner's own style.json is a real way to get a chart aboard —
    // offline, or one they wrote themselves.
    std::string LocalPath(std::string const &url)
    {
        std::string p = url;
        if (p.rfind("file://", 0) == 0)
        {
            p = p.substr(7);
            // file:///C:/… keeps a slash before the drive; strip it, and give
            // %20 and friends their characters back.
            if (p.size() >= 3 && p[0] == '/' && p[2] == ':')
                p = p.substr(1);
            std::string plain;
            for (size_t i = 0; i < p.size(); ++i)
            {
                if (p[i] == '%' && i + 2 < p.size() &&
                    isxdigit((unsigned char)p[i + 1]) && isxdigit((unsigned char)p[i + 2]))
                {
                    plain += (char)std::stoi(p.substr(i + 1, 2), nullptr, 16);
                    i += 2;
                }
                else
                {
                    plain += p[i];
                }
            }
            return plain;
        }
        if (!p.empty() && (p[0] == '/' || (p.size() >= 2 && p[1] == ':')))
            return p;
        return {};
    }

    bool ReadLocalFile(std::string const &path, std::vector<uint8_t> &out)
    {
        std::ifstream f(std::filesystem::path(path), std::ios::binary);
        if (!f)
            return false;
        out.assign(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
        return true;
    }

    // The fetch pool. lookout raises its asks on the render thread with its
    // lock held, so the thunk does the least possible: queue the job and
    // return. Every job is ANSWERED, because an id that is neither answered
    // nor cancelled holds one of lookout's outstanding-request slots — except
    // one lookout has itself cancelled, which released its slot already.
    class HttpPool
    {
    public:
        void Start(int workers)
        {
            std::lock_guard<std::mutex> lock(mu_);
            if (running_)
                return;
            running_ = true;
            for (int i = 0; i < workers; ++i)
                threads_.emplace_back([this] { Run(); });
        }

        // Answers the ids that were queued and never started, so the caller
        // can release lookout's slots for them.
        std::vector<uint64_t> Stop()
        {
            std::vector<uint64_t> dropped;
            {
                std::lock_guard<std::mutex> lock(mu_);
                if (!running_)
                    return dropped;
                running_ = false;
                for (auto const &job : queue_)
                    dropped.push_back(job.id);
                queue_.clear();
            }
            cv_.notify_all();
            for (auto &t : threads_)
            {
                if (t.joinable())
                    t.join();
            }
            threads_.clear();
            return dropped;
        }

        // False when the pool is down, so the caller answers the ask itself
        // rather than leaving lookout holding a slot for it.
        bool Submit(uint64_t id, std::function<void()> run)
        {
            {
                std::lock_guard<std::mutex> lock(mu_);
                if (!running_)
                    return false;
                queue_.push_back(Job{ id, std::move(run) });
            }
            cv_.notify_one();
            return true;
        }

        // Advisory. A job not yet started is dropped and never answered —
        // lookout released its slot when it cancelled. One already running
        // finishes and answers, which lookout ignores.
        void Cancel(uint64_t id)
        {
            std::lock_guard<std::mutex> lock(mu_);
            for (auto it = queue_.begin(); it != queue_.end(); ++it)
            {
                if (it->id == id)
                {
                    queue_.erase(it);
                    return;
                }
            }
        }

    private:
        struct Job
        {
            uint64_t              id{ 0 };
            std::function<void()> run;
        };

        void Run()
        {
            for (;;)
            {
                Job job;
                {
                    std::unique_lock<std::mutex> lock(mu_);
                    cv_.wait(lock, [this] { return !running_ || !queue_.empty(); });
                    if (!running_)
                        return;
                    job = std::move(queue_.front());
                    queue_.pop_front();
                }
                job.run();
            }
        }

        std::mutex               mu_;
        std::condition_variable  cv_;
        std::deque<Job>          queue_;
        std::vector<std::thread> threads_;
        bool                     running_{ false };
    };

    HttpPool g_http_pool;
}

namespace winrt::LookoutMarine::implementation
{
    // Answering funnels through here: `link_mu` is held so a handle closing
    // mid-answer is never answered into, and lk_controller_http_respond takes
    // no lock of the core's own, so nothing can deadlock behind it.
    void MainWindow::ChartLinkRespond(uint64_t id, void const *bytes, size_t len, int status)
    {
        std::lock_guard<std::mutex> lock(link_mu);
        if (!link_live)
            return;
        lk_controller_http_respond(controller, id, bytes, len, status);
    }

    // The C entry point: fired on the render thread with lookout's lock held.
    // Copy the url out — it is lookout's memory and valid only for this call —
    // queue the fetch, return.
    void MainWindow::HttpGetThunk(void *user, unsigned long long req_id,
                                  const char *url, int allow_file)
    {
        auto *self = static_cast<MainWindow *>(user);
        if (url == nullptr)
        {
            self->ChartLinkRespond(req_id, nullptr, 0, 0);
            return;
        }
        std::string link(url);
        bool        allow = allow_file != 0;
        bool queued = g_http_pool.Submit(req_id, [self, req_id, link, allow] {
            std::vector<uint8_t> bytes;
            int                  status = 0;
            // The file:// boundary. lookout says when a url may be read off
            // disk (see lookout_http_get): the link the mariner typed, and
            // what a document already read from disk names inside that link's
            // directory. A style that arrived over the network never gets it,
            // so it cannot make this read arbitrary local files as its
            // "TileJSON".
            std::string path = LocalPath(link);
            if (!path.empty())
            {
                if (allow && ReadLocalFile(path, bytes))
                    status = 200;
            }
            else
            {
                status = FetchUrl(winrt::to_hstring(link).c_str(), bytes);
            }
            self->ChartLinkRespond(req_id, bytes.empty() ? nullptr : bytes.data(),
                                   bytes.size(), status);
        });
        if (!queued)
            self->ChartLinkRespond(req_id, nullptr, 0, 0);
    }

    void MainWindow::HttpCancelThunk(void *user, unsigned long long req_id)
    {
        (void)user;
        g_http_pool.Cancel(req_id);
    }

    // Install the fetcher on the handle just opened, hand lookout the shell's
    // old store the first time, and take the snapshot that follows. Every open
    // makes a new handle, so this runs beside the raster replay.
    void MainWindow::ChartLinksAttach()
    {
        {
            std::lock_guard<std::mutex> lock(link_mu);
            link_live = true;
        }
        g_http_pool.Start(6);
        lk_controller_set_http_provider(controller, &MainWindow::HttpGetThunk,
                                        &MainWindow::HttpCancelThunk, this);
        MigrateChartLinks();
        PollChartLinks();
    }

    // Before the handle closes: the fetches still out are answered, the
    // provider is cleared, and the pool is joined, so nothing can answer into
    // a handle that is about to be destroyed.
    void MainWindow::ChartLinksDetach()
    {
        if (controller != nullptr)
            lk_controller_set_http_provider(controller, nullptr, nullptr, nullptr);
        auto dropped = g_http_pool.Stop();
        std::lock_guard<std::mutex> lock(link_mu);
        for (uint64_t id : dropped)
        {
            if (link_live)
                lk_controller_http_respond(controller, id, nullptr, 0, 0);
        }
        link_live = false;
    }

    // Hand the old chartlinks.json to lookout, once, and then drop it.
    //
    // lookout ignores the import when it already has a list of its own, so the
    // window between handing it over and deleting the file replays harmlessly
    // if the app dies in it.
    void MainWindow::MigrateChartLinks()
    {
        if (chart_links_imported)
            return;
        chart_links_imported = true;

        char *raw = lk_store_load_chartlinks();
        if (raw == nullptr)
            return;
        std::string links(raw);
        free(raw);
        if (links.empty())
            return;

        JsonArray arr{ nullptr };
        if (!JsonArray::TryParse(winrt::to_hstring(links), arr))
        {
            lk_store_save_chartlinks("");
            lk_store_save_chartlink_active("");
            return;
        }
        JsonObject doc;
        doc.SetNamedValue(L"links", arr);
        char active[8192]{};
        if (lk_store_load_chartlink_active(active, (int)sizeof active) && active[0] != '\0')
            doc.SetNamedValue(L"active", JsonValue::CreateStringValue(winrt::to_hstring(active)));
        lk_controller_chart_links_import(controller, winrt::to_string(doc.Stringify()).c_str());
        lk_store_save_chartlinks("");
        lk_store_save_chartlink_active("");
    }

    // Take lookout's snapshot, if it changed. UI THREAD, off the readout
    // timer: the changed flag has ONE consumer, and the rows it rebuilds are
    // XAML.
    void MainWindow::PollChartLinks()
    {
        if (controller == nullptr)
            return;
        char *json = lk_controller_chart_links_changed_json(controller);
        if (json == nullptr)
            return;
        std::string text(json);
        lk_controller_string_free(json);

        JsonObject top{ nullptr };
        if (!JsonObject::TryParse(winrt::to_hstring(text), top))
            return;

        chart_links.clear();
        if (top.HasKey(L"links"))
        {
            auto arr = top.GetNamedArray(L"links", JsonArray{});
            for (auto const &value : arr)
            {
                if (value.ValueType() != JsonValueType::Object)
                    continue;
                auto row = value.GetObject();
                std::string url = winrt::to_string(row.GetNamedString(L"url", L""));
                if (url.empty())
                    continue;
                ChartLink link;
                link.url = url;
                link.name = winrt::to_string(row.GetNamedString(L"name", winrt::to_hstring(url)));
                chart_links.push_back(std::move(link));
            }
        }
        active_chart_link.clear();
        if (top.HasKey(L"active") && top.GetNamedValue(L"active").ValueType() == JsonValueType::String)
            active_chart_link = winrt::to_string(top.GetNamedString(L"active"));
        chart_link_error = winrt::to_string(top.GetNamedString(L"error", L""));
        chart_link_busy = top.GetNamedBoolean(L"busy", false);
        std::string credit = winrt::to_string(top.GetNamedString(L"attribution", L""));

        // Public tile hosts make the visible credit a condition of service, so
        // it sits under the scale bar for as long as the link draws.
        if (credit.empty())
        {
            ScaleBarCredit().Text(L"");
            ScaleBarCredit().Visibility(Visibility::Collapsed);
        }
        else
        {
            ScaleBarCredit().Text(winrt::to_hstring(credit));
            ScaleBarCredit().Visibility(Visibility::Visible);
        }
        BuildSettingsPage();
    }

    // ---- the management surface --------------------------------------------

    void MainWindow::AddChartLink(std::string const &raw)
    {
        std::string trimmed = raw;
        while (!trimmed.empty() && isspace((unsigned char)trimmed.front()))
            trimmed.erase(trimmed.begin());
        while (!trimmed.empty() && isspace((unsigned char)trimmed.back()))
            trimmed.pop_back();
        if (trimmed.empty())
            return;
        lk_controller_chart_link_add(controller, trimmed.c_str());
        PollChartLinks();
    }

    void MainWindow::SelectChartLink(std::string const &url)
    {
        // Selecting the link that is already drawn is a no-op: the radio fires
        // on every click, and re-selecting would re-resolve the style and
        // every sprite pack for nothing. A selection whose last resolve failed
        // does retry.
        if (!url.empty() && url == active_chart_link && chart_link_error.empty())
            return;
        lk_controller_chart_link_select(controller, url.empty() ? nullptr : url.c_str());
        PollChartLinks();
    }

    void MainWindow::RemoveChartLink(std::string const &url)
    {
        lk_controller_chart_link_remove(controller, url.c_str());
        PollChartLinks();
    }

    void MainWindow::RefreshChartLink(std::string const &url)
    {
        lk_controller_chart_link_refresh(controller, url.c_str());
        PollChartLinks();
    }
}
