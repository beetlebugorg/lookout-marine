// Chart links: an online map AS the chart. The shell fetches a publisher's
// MapLibre style, hands lookout the JSON, and then serves that style's tiles
// (lookout does no networking — see lookout.h, lookout_set_tile_provider).
// The Windows twin of the macOS AltChartStyle.swift + AppModel chart links.
//
// WHY THE STYLE IS REWRITTEN ON THE WAY IN. A source may name its tiles
// inline ("tiles": [...]) or point at a TileJSON document ("url": ...). Only
// the first is something lookout can act on, so a TileJSON source is resolved
// HERE, once, and its answer inlined before the style goes down.
#include "pch.h"
#include "MainWindow.xaml.h"

#include <winhttp.h>

#include <algorithm>
#include <condition_variable>
#include <deque>
#include <filesystem>
#include <fstream>

#include "lk_store.h"

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace winrt::Windows::Data::Json;

namespace
{
    // status codes lk_controller_tile_respond takes.
    constexpr int kTileBytes = 0;
    constexpr int kTileNone = 1;   // no tile there — remembered, not re-asked
    constexpr int kTileFailed = 2; // tried and failed — also remembered

    // One HTTP GET, synchronous, on a worker thread. Returns the HTTP status
    // (0 on transport failure) and fills bytes on 200.
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
        // A stalled tile must not hold a fetch thread forever: the chart is
        // drawn from whatever HAS landed, so a slow tile costs only itself.
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
            if (status == 200)
            {
                // A hostile or broken host must not be able to stream the
                // app out of memory. Nothing a chart link legitimately
                // fetches (style, TileJSON, sprite sheet, or tile) comes
                // anywhere near this cap.
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

    // A style document off the disk, for a file path or file:// link; empty
    // optional when the link is not a file. A mariner's own style.json is a
    // real way to get a chart aboard — offline, or one they wrote themselves.
    bool ReadFileLink(std::string const &link, std::string &out)
    {
        std::string p = link;
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
            p = std::move(plain);
        }
        else if (p.empty() || (p[0] != '/' && (p.size() < 2 || p[1] != ':')))
        {
            return false;
        }
        std::ifstream f(std::filesystem::path(p), std::ios::binary);
        if (!f)
            return false;
        out.assign(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
        return true;
    }

    // True for a path or file url — something the mariner keeps on disk,
    // whose style may in turn name files beside it.
    bool LooksLikeFileLink(std::string const &link)
    {
        return link.rfind("file://", 0) == 0 ||
               (!link.empty() && (link[0] == '/' || (link.size() >= 2 && link[1] == ':')));
    }

    // allow_file marks a link the mariner typed, or one derived from it.
    // Only those may read the disk. A url found inside a document fetched
    // from the network must never reach the file branch, or a hostile style
    // could make the shell read arbitrary local files as its "TileJSON".
    bool FetchText(std::string const &link, std::string &out, bool allow_file)
    {
        if (allow_file && ReadFileLink(link, out))
            return true;
        std::vector<uint8_t> bytes;
        if (FetchUrl(winrt::to_hstring(link).c_str(), bytes) != 200)
            return false;
        out.assign(bytes.begin(), bytes.end());
        return true;
    }

    bool ParseObject(std::string const &text, JsonObject &out)
    {
        return JsonObject::TryParse(winrt::to_hstring(text), out);
    }

    // One sprite pack a style declares: the pack id as the icon-name prefix
    // ("" for the spec's "default"), and the base url `.json`/`.png` append
    // to.
    struct SpritePackRef
    {
        std::string prefix;
        std::string url;
    };

    // A pack fetched whole, ready for the engine.
    struct FetchedSpritePack
    {
        std::string prefix;
        std::string json;
        std::vector<uint8_t> png;
    };

    // The style's `sprite` root: one base url, or the array form of {id, url}
    // packs whose icons resolve as "id:name" ("default" gives bare names).
    std::vector<SpritePackRef> SpritePacksOf(JsonObject const &top)
    {
        std::vector<SpritePackRef> out;
        auto v = top.TryLookup(L"sprite");
        if (v == nullptr)
            return out;
        if (v.ValueType() == JsonValueType::String)
        {
            auto url = winrt::to_string(v.GetString());
            if (!url.empty())
                out.push_back({ "", url });
            return out;
        }
        if (v.ValueType() != JsonValueType::Array)
            return out;
        for (auto const &e : v.GetArray())
        {
            if (e.ValueType() != JsonValueType::Object)
                continue;
            auto o = e.GetObject();
            auto url = winrt::to_string(o.GetNamedString(L"url", L""));
            if (url.empty())
                continue;
            auto id = winrt::to_string(o.GetNamedString(L"id", L""));
            out.push_back({ id == "default" ? std::string{} : id, url });
        }
        return out;
    }

    bool FetchBytes(std::string const &link, std::vector<uint8_t> &out)
    {
        return FetchUrl(winrt::to_hstring(link).c_str(), out) == 200;
    }

    // Fetch a style's sprite packs whole. @2x first — the sheets draw at
    // their authored logical size whatever the ratio, and every display that
    // matters is dense — with the 1x pack as the fallback for a publisher
    // who ships only one. A pack that will not fetch is skipped, not fatal:
    // the chart draws, short its icons.
    // "…/sprite" + "@2x" + ".json", keeping a query string at the end: an
    // API-keyed host serves …/sprite@2x.json?key=K, never …?key=K@2x.json.
    std::string SpriteVariant(std::string const &base, char const *density, char const *ext)
    {
        auto q = base.find('?');
        if (q == std::string::npos)
            return base + density + ext;
        return base.substr(0, q) + density + ext + base.substr(q);
    }

    std::vector<FetchedSpritePack> FetchSpritePacks(std::vector<SpritePackRef> const &packs)
    {
        std::vector<FetchedSpritePack> out;
        for (auto const &p : packs)
        {
            bool got = false;
            for (auto const *s : { "@2x", "" })
            {
                std::vector<uint8_t> jb, pb;
                if (!FetchBytes(SpriteVariant(p.url, s, ".json"), jb) ||
                    !FetchBytes(SpriteVariant(p.url, s, ".png"), pb))
                    continue;
                FetchedSpritePack f;
                f.prefix = p.prefix;
                f.json.assign(jb.begin(), jb.end());
                f.png = std::move(pb);
                out.push_back(std::move(f));
                got = true;
                break;
            }
            if (!got)
                fprintf(stderr, "shell: sprite pack %s: fetch failed; its icons will be missing\n",
                        p.url.c_str());
        }
        return out;
    }

    // A style for a bare tile source. Raster tiles draw as imagery; vector
    // tiles draw each advertised layer in a legible generic scheme — honest
    // geometry, not the publisher's portrayal (a tile source doesn't carry
    // one). The look matches the reference shell's wrapper, hue for hue.
    std::string TileJsonWrapperStyle(std::string const &link, JsonObject const &tilejson)
    {
        JsonArray layers;
        {
            JsonObject bg, paint;
            bg.SetNamedValue(L"id", JsonValue::CreateStringValue(L"bg"));
            bg.SetNamedValue(L"type", JsonValue::CreateStringValue(L"background"));
            paint.SetNamedValue(L"background-color", JsonValue::CreateStringValue(L"#c9e2f0"));
            bg.SetNamedValue(L"paint", paint);
            layers.Append(bg);
        }
        JsonObject source;
        source.SetNamedValue(L"url", JsonValue::CreateStringValue(winrt::to_hstring(link)));
        auto vlayers = tilejson.TryLookup(L"vector_layers");
        if (vlayers == nullptr || vlayers.ValueType() != JsonValueType::Array ||
            vlayers.GetArray().Size() == 0)
        {
            source.SetNamedValue(L"type", JsonValue::CreateStringValue(L"raster"));
            JsonObject tiles;
            tiles.SetNamedValue(L"id", JsonValue::CreateStringValue(L"tiles"));
            tiles.SetNamedValue(L"type", JsonValue::CreateStringValue(L"raster"));
            tiles.SetNamedValue(L"source", JsonValue::CreateStringValue(L"tiles"));
            layers.Append(tiles);
        }
        else
        {
            source.SetNamedValue(L"type", JsonValue::CreateStringValue(L"vector"));
            static constexpr double hues[] = { 210, 30, 120, 275, 0, 165, 55, 320 };
            auto arr = vlayers.GetArray();
            for (uint32_t i = 0; i < arr.Size(); ++i)
            {
                auto vl = arr.GetAt(i).ValueType() == JsonValueType::Object
                              ? arr.GetAt(i).GetObject() : nullptr;
                if (vl == nullptr)
                    continue;
                auto lid = vl.GetNamedString(L"id", L"");
                if (lid.empty())
                    continue;
                std::string low = winrt::to_string(lid);
                for (auto &c : low)
                    c = (char)tolower((unsigned char)c);
                double hue = hues[i % _countof(hues)];
                char fill[64], line[64], point[64];
                double point_radius = 2.5;
                snprintf(fill, sizeof fill, "hsla(%g,55%%,62%%,0.35)", hue);
                snprintf(line, sizeof line, "hsl(%g,60%%,38%%)", hue);
                snprintf(point, sizeof point, "hsl(%g,65%%,40%%)", hue);
                if (low.find("depare") != std::string::npos ||
                    low.find("depth") != std::string::npos ||
                    low.find("bathy") != std::string::npos)
                {
                    snprintf(fill, sizeof fill, "hsla(205,60%%,70%%,0.5)");
                    snprintf(line, sizeof line, "hsl(205,45%%,55%%)");
                    snprintf(point, sizeof point, "hsl(205,45%%,45%%)");
                }
                else if (low.find("contour") != std::string::npos)
                {
                    snprintf(fill, sizeof fill, "hsla(205,30%%,60%%,0.15)");
                    snprintf(line, sizeof line, "hsl(205,35%%,55%%)");
                    snprintf(point, sizeof point, "hsl(205,35%%,45%%)");
                }
                else if (low.find("sound") != std::string::npos)
                {
                    point_radius = 1.5;
                    snprintf(fill, sizeof fill, "hsla(210,25%%,55%%,0.2)");
                    snprintf(line, sizeof line, "hsl(210,25%%,55%%)");
                    snprintf(point, sizeof point, "hsl(210,25%%,35%%)");
                }
                else if (low.find("land") != std::string::npos ||
                         low.find("coast") != std::string::npos)
                {
                    snprintf(fill, sizeof fill, "hsla(45,45%%,70%%,0.9)");
                    snprintf(line, sizeof line, "hsl(45,30%%,40%%)");
                    snprintf(point, sizeof point, "hsl(45,30%%,40%%)");
                }

                auto geom_filter = [](wchar_t const *kind) {
                    JsonArray f, g;
                    f.Append(JsonValue::CreateStringValue(L"=="));
                    g.Append(JsonValue::CreateStringValue(L"geometry-type"));
                    f.Append(g);
                    f.Append(JsonValue::CreateStringValue(kind));
                    return f;
                };
                auto add_layer = [&](wchar_t const *suffix, wchar_t const *type,
                                     wchar_t const *kind, JsonObject paint) {
                    JsonObject l;
                    l.SetNamedValue(L"id", JsonValue::CreateStringValue(lid + suffix));
                    l.SetNamedValue(L"type", JsonValue::CreateStringValue(type));
                    l.SetNamedValue(L"source", JsonValue::CreateStringValue(L"tiles"));
                    l.SetNamedValue(L"source-layer", JsonValue::CreateStringValue(lid));
                    l.SetNamedValue(L"filter", geom_filter(kind));
                    l.SetNamedValue(L"paint", paint);
                    layers.Append(l);
                };
                JsonObject pf, pl, pp;
                pf.SetNamedValue(L"fill-color", JsonValue::CreateStringValue(winrt::to_hstring(fill)));
                add_layer(L"-fill", L"fill", L"Polygon", pf);
                pl.SetNamedValue(L"line-color", JsonValue::CreateStringValue(winrt::to_hstring(line)));
                pl.SetNamedValue(L"line-width", JsonValue::CreateNumberValue(1.0));
                add_layer(L"-line", L"line", L"LineString", pl);
                pp.SetNamedValue(L"circle-radius", JsonValue::CreateNumberValue(point_radius));
                pp.SetNamedValue(L"circle-color", JsonValue::CreateStringValue(winrt::to_hstring(point)));
                add_layer(L"-pt", L"circle", L"Point", pp);
            }
        }
        JsonObject style, sources;
        style.SetNamedValue(L"version", JsonValue::CreateNumberValue(8));
        style.SetNamedValue(L"name", JsonValue::CreateStringValue(
            tilejson.GetNamedString(L"name", L"Tiles")));
        sources.SetNamedValue(L"tiles", source);
        style.SetNamedValue(L"sources", sources);
        style.SetNamedValue(L"layers", layers);
        return winrt::to_string(style.Stringify());
    }

    // The style.json living beside a TileJSON, when the publisher shipped
    // one: that is the look the mariner pasted the link expecting. Only if it
    // parses as a MapLibre style.
    bool SiblingStyle(std::string const &link, std::string &out_url, std::string &out_name)
    {
        auto cut = link.find_last_of('/');
        if (cut == std::string::npos)
            return false;
        std::string candidate = link.substr(0, cut) + "/style.json";
        if (candidate == link)
            return false;
        std::string text;
        JsonObject obj;
        if (!FetchText(candidate, text, false) || !ParseObject(text, obj))
            return false;
        if (!obj.HasKey(L"layers") || !obj.HasKey(L"version"))
            return false;
        out_url = candidate;
        auto n = winrt::to_string(obj.GetNamedString(L"name", L""));
        out_name = n.empty() ? candidate : n;
        return true;
    }

    // Read a link and work out what chart it is: a whole MapLibre style (keep
    // the url and fetch it each time), a TileJSON (tiles with no style of
    // their own — a wrapper is generated), or a mariner's style file (its
    // TEXT is carried, since the path may not answer next launch the same
    // way). Returns false when nothing chart-like is there.
    bool ProbeChartLink(std::string const &raw, std::string &url,
                        std::string &name, std::string &doc)
    {
        std::string text;
        if (ReadFileLink(raw, text))
        {
            JsonObject obj;
            if (!ParseObject(text, obj) || !obj.HasKey(L"layers") || !obj.HasKey(L"version"))
                return false;
            url = raw;
            auto n = winrt::to_string(obj.GetNamedString(L"name", L""));
            name = n.empty() ? std::filesystem::path(raw).stem().string() : n;
            doc = text;
            return true;
        }
        JsonObject obj;
        if (!FetchText(raw, text, true) || !ParseObject(text, obj))
            return false;
        auto n = winrt::to_string(obj.GetNamedString(L"name", L""));
        name = n.empty() ? raw : n;
        url = raw;
        doc.clear();
        if (obj.HasKey(L"layers") && obj.HasKey(L"version"))
            return true;
        if (obj.HasKey(L"tiles") || obj.HasKey(L"tilejson"))
        {
            std::string s_url, s_name;
            if (SiblingStyle(raw, s_url, s_name))
            {
                url = s_url;
                name = s_name;
                return true;
            }
            doc = TileJsonWrapperStyle(raw, obj);
            return true;
        }
        return false;
    }

    // The credit line a style's sources ask for: distinct attributions in
    // source order, HTML markup reduced to its text. Public tile hosts make
    // the visible credit a condition of service (openstreetmap.org's tile
    // usage policy among them), so the shell shows it under the scale bar.
    std::string StripAttribution(std::string const &raw)
    {
        std::string out;
        bool in_tag = false;
        for (size_t i = 0; i < raw.size(); ++i)
        {
            char c = raw[i];
            if (c == '<') { in_tag = true; continue; }
            if (c == '>') { in_tag = false; continue; }
            if (in_tag)
                continue;
            if (raw.compare(i, 6, "&copy;") == 0) { out += "\xC2\xA9"; i += 5; continue; }
            if (raw.compare(i, 4, "&lt;") == 0) { out += '<'; i += 3; continue; }
            if (raw.compare(i, 4, "&gt;") == 0) { out += '>'; i += 3; continue; }
            if (raw.compare(i, 6, "&quot;") == 0) { out += '"'; i += 5; continue; }
            if (raw.compare(i, 5, "&#39;") == 0) { out += '\''; i += 4; continue; }
            if (raw.compare(i, 6, "&nbsp;") == 0) { out += ' '; i += 5; continue; }
            if (raw.compare(i, 5, "&amp;") == 0) { out += '&'; i += 4; continue; }
            out += c;
        }
        // Trim the whitespace the markup leaves behind.
        size_t a = out.find_first_not_of(" \t\r\n");
        size_t b = out.find_last_not_of(" \t\r\n");
        return a == std::string::npos ? "" : out.substr(a, b - a + 1);
    }

    // Resolve a style: inline every TileJSON source, collect each source's
    // url templates and TMS flag for the tile provider, and gather the
    // sources' attribution for display. Returns the rewritten style JSON;
    // false when the text is not a style.
    bool ResolveStyle(std::string const &raw, std::string &out_json,
                      std::map<std::string, std::pair<std::vector<std::string>, bool>> &out_sources,
                      std::string &out_attribution,
                      std::vector<SpritePackRef> &out_packs,
                      bool local_style)
    {
        JsonObject top;
        if (!ParseObject(raw, top))
            return false;
        out_packs = SpritePacksOf(top);
        std::vector<std::string> credits;
        auto declared = top.TryLookup(L"sources");
        if (declared == nullptr || declared.ValueType() != JsonValueType::Object)
            return false;
        auto sources = declared.GetObject();
        for (auto const &kv : sources)
        {
            if (kv.Value().ValueType() != JsonValueType::Object)
                continue;
            auto src = kv.Value().GetObject();
            if (!src.HasKey(L"tiles"))
            {
                auto link = winrt::to_string(src.GetNamedString(L"url", L""));
                std::string text;
                JsonObject docj;
                if (!link.empty() && FetchText(link, text, local_style) && ParseObject(text, docj))
                {
                    for (auto const *key : { L"tiles", L"minzoom", L"maxzoom",
                                             L"bounds", L"scheme", L"attribution" })
                    {
                        if (docj.HasKey(key))
                            src.SetNamedValue(key, docj.Lookup(key));
                    }
                    // TileJSON says tileSize nowhere; raster tiles are 256
                    // unless the style already said otherwise, and getting
                    // this wrong draws the imagery one zoom level off.
                    if (!src.HasKey(L"tileSize") && src.GetNamedString(L"type", L"") == L"raster")
                        src.SetNamedValue(L"tileSize", JsonValue::CreateNumberValue(256));
                    src.Remove(L"url");
                }
            }
            auto tiles = src.TryLookup(L"tiles");
            if (tiles == nullptr || tiles.ValueType() != JsonValueType::Array)
                continue;
            std::vector<std::string> templates;
            auto arr = tiles.GetArray();
            for (uint32_t i = 0; i < arr.Size(); ++i)
                if (arr.GetAt(i).ValueType() == JsonValueType::String)
                    templates.push_back(winrt::to_string(arr.GetAt(i).GetString()));
            if (templates.empty())
                continue;
            std::string scheme = winrt::to_string(src.GetNamedString(L"scheme", L""));
            for (auto &c : scheme)
                c = (char)tolower((unsigned char)c);
            out_sources[winrt::to_string(kv.Key())] = { templates, scheme == "tms" };

            std::string credit =
                StripAttribution(winrt::to_string(src.GetNamedString(L"attribution", L"")));
            if (!credit.empty())
                credits.push_back(std::move(credit));
        }
        // Distinct, and an attribution CONTAINED in another is dropped —
        // sources repeat each other's credits inside composite strings, and
        // keeping both made the line longer than the scale bar it sits
        // under.
        for (size_t i = 0; i < credits.size(); ++i)
        {
            bool drop = false;
            for (size_t k = 0; k < credits.size() && !drop; ++k)
            {
                if (k == i)
                    continue;
                if (credits[k] == credits[i])
                    drop = k < i; // exact duplicate: the first one speaks
                else if (credits[k].find(credits[i]) != std::string::npos)
                    drop = true; // contained in a longer credit
            }
            if (drop)
                continue;
            if (!out_attribution.empty())
                out_attribution += " \xC2\xB7 ";
            out_attribution += credits[i];
        }
        out_json = winrt::to_string(top.Stringify());
        return true;
    }

    // Fill a style's url template for one tile. The subdomain pick is
    // deterministic, so the same tile keeps hitting the same host and stays
    // cached there. TMS counts y from the south.
    std::string TileUrl(std::vector<std::string> const &templates, bool flip_y,
                        int z, int x, int y)
    {
        if (templates.empty())
            return "";
        std::string url = templates[(size_t)std::abs(x + y) % templates.size()];
        int ty = flip_y ? (1 << z) - 1 - y : y;
        auto sub = [&url](char const *tag, int v) {
            auto at = url.find(tag);
            if (at != std::string::npos)
                url.replace(at, strlen(tag), std::to_string(v));
        };
        sub("{z}", z);
        sub("{x}", x);
        sub("{y}", ty);
        return url;
    }

    // The C entry point: render thread, core lock held. Copy the name out and
    // hand off — the fetch must not run here.
    void TileThunk(void *user, const char *source, unsigned long long req_id,
                   int z, int x, int y)
    {
        auto *self = (winrt::LookoutMarine::implementation::MainWindow *)user;
        self->TileRequest(source != nullptr ? source : "", req_id, z, x, y);
    }

    // A small fixed pool for the tile fetches: tiles arrive in bursts of
    // dozens, and a thread per tile would spawn as many. Four workers match
    // the connection budget a tile host expects from one client. The pool
    // lives for the process, and the workers honour their jthread stop token
    // — the destructor JOINS at CRT exit, and a wait that never looked at the
    // token hung the process on quit. condition_variable_any is what takes a
    // stop token in its wait.
    class TilePool
    {
    public:
        void Run(std::function<void()> task)
        {
            {
                std::lock_guard<std::mutex> g(mu_);
                if (workers_.empty())
                {
                    for (int i = 0; i < 4; ++i)
                        workers_.emplace_back([this](std::stop_token st) { Work(st); });
                }
                queue_.push_back(std::move(task));
            }
            cv_.notify_one();
        }

    private:
        void Work(std::stop_token st)
        {
            for (;;)
            {
                std::function<void()> task;
                {
                    std::unique_lock<std::mutex> g(mu_);
                    if (!cv_.wait(g, st, [this] { return !queue_.empty(); }))
                        return; // stop requested: the process is quitting
                    task = std::move(queue_.front());
                    queue_.pop_front();
                }
                task();
            }
        }

        std::mutex mu_;
        std::condition_variable_any cv_;
        std::deque<std::function<void()>> queue_;
        std::vector<std::jthread> workers_;
    };

    TilePool g_tile_pool;
}

namespace winrt::LookoutMarine::implementation
{
    void MainWindow::LoadChartLinks()
    {
        chart_links.clear();
        if (char *raw = lk_store_load_chartlinks())
        {
            JsonArray arr;
            if (JsonArray::TryParse(winrt::to_hstring(raw), arr))
            {
                for (uint32_t i = 0; i < arr.Size(); ++i)
                {
                    if (arr.GetAt(i).ValueType() != JsonValueType::Object)
                        continue;
                    auto o = arr.GetAt(i).GetObject();
                    ChartLink l;
                    l.url = winrt::to_string(o.GetNamedString(L"url", L""));
                    l.name = winrt::to_string(o.GetNamedString(L"name", L""));
                    l.doc = winrt::to_string(o.GetNamedString(L"doc", L""));
                    if (!l.url.empty())
                        chart_links.push_back(std::move(l));
                }
            }
            free(raw);
        }
        // Room for a long keyed url: a truncated read fails the equality test
        // below and silently reverts the pick to the built-in chart.
        char active[8192];
        active_chart_link.clear();
        if (lk_store_load_chartlink_active(active, sizeof active))
        {
            for (auto const &l : chart_links)
                if (l.url == active)
                    active_chart_link = active;
        }
    }

    void MainWindow::SaveChartLinks()
    {
        JsonArray arr;
        for (auto const &l : chart_links)
        {
            JsonObject o;
            o.SetNamedValue(L"url", JsonValue::CreateStringValue(winrt::to_hstring(l.url)));
            o.SetNamedValue(L"name", JsonValue::CreateStringValue(winrt::to_hstring(l.name)));
            if (!l.doc.empty())
                o.SetNamedValue(L"doc", JsonValue::CreateStringValue(winrt::to_hstring(l.doc)));
            arr.Append(o);
        }
        lk_store_save_chartlinks(winrt::to_string(arr.Stringify()).c_str());
        lk_store_save_chartlink_active(active_chart_link.c_str());
    }

    void MainWindow::SelectChartLink(std::string const &url)
    {
        active_chart_link = url;
        SaveChartLinks();
        PushChartLink();
    }

    void MainWindow::RemoveChartLink(std::string const &url)
    {
        chart_links.erase(std::remove_if(chart_links.begin(), chart_links.end(),
                                         [&](ChartLink const &l) { return l.url == url; }),
                          chart_links.end());
        if (active_chart_link == url)
            active_chart_link.clear();
        SaveChartLinks();
        PushChartLink();
        if (SettingsOpen())
            BuildSettingsPage();
    }

    // Add a chart by its style link. The link is read ONCE here — a dead or
    // non-style link is refused now, at the form, not discovered later as a
    // blank chart. The new chart is picked immediately: adding it is the
    // request to sail on it.
    void MainWindow::AddChartLink(std::string const &raw)
    {
        std::string trimmed = raw;
        while (!trimmed.empty() && isspace((unsigned char)trimmed.back()))
            trimmed.pop_back();
        while (!trimmed.empty() && isspace((unsigned char)trimmed.front()))
            trimmed.erase(trimmed.begin());
        if (trimmed.empty())
            return;
        for (auto const &l : chart_links)
        {
            if (l.url == trimmed)
            {
                SelectChartLink(trimmed);
                return;
            }
        }
        chart_link_error.clear();
        auto queue = DispatcherQueue();
        std::thread([this, queue, trimmed] {
            auto url = std::make_shared<std::string>();
            auto name = std::make_shared<std::string>();
            auto doc = std::make_shared<std::string>();
            bool found = false;
            try
            {
                found = ProbeChartLink(trimmed, *url, *name, *doc);
            }
            catch (...)
            {
                // A fetched document with a key of the wrong type throws out
                // of GetNamedString; hostile JSON must not take the app down.
            }
            queue.TryEnqueue([this, found, url, name, doc] {
                if (!found)
                {
                    chart_link_error = "No chart style or tile source at that link.";
                    if (SettingsOpen())
                        BuildSettingsPage();
                    return;
                }
                bool have = false;
                for (auto const &l : chart_links)
                    have = have || l.url == *url;
                if (!have)
                    chart_links.push_back({ *url, *name, *doc });
                SelectChartLink(*url);
                if (SettingsOpen())
                    BuildSettingsPage();
            });
        }).detach();
    }

    // Re-read a linked chart and rebuild what was frozen when it was added: a
    // TileJSON link's wrapper was GENERATED from what the publisher served
    // that day. A link that does not answer leaves the chart exactly as it
    // was — a lost connection must not cost the mariner the chart they are
    // sailing on.
    void MainWindow::RefreshChartLink(std::string const &url)
    {
        bool known = false;
        for (auto const &l : chart_links)
            known = known || l.url == url;
        if (!known)
            return;
        chart_link_error.clear();
        bool was_picked = active_chart_link == url;
        auto queue = DispatcherQueue();
        std::thread([this, queue, url, was_picked] {
            auto n_url = std::make_shared<std::string>();
            auto name = std::make_shared<std::string>();
            auto doc = std::make_shared<std::string>();
            bool found = false;
            try
            {
                found = ProbeChartLink(url, *n_url, *name, *doc);
            }
            catch (...)
            {
                // As in AddChartLink: wrong-typed JSON throws, and it must
                // be treated as "did not answer" rather than a crash.
            }
            queue.TryEnqueue([this, found, url, was_picked, n_url, name, doc] {
                if (!found)
                {
                    chart_link_error = "That link didn't answer. The chart is unchanged.";
                    if (SettingsOpen())
                        BuildSettingsPage();
                    return;
                }
                for (auto &l : chart_links)
                    if (l.url == url)
                        l = { *n_url, *name, *doc };
                // A refresh can resolve to the sibling style.json that
                // another entry already carries. Keep one entry per url: the
                // first copy takes the refreshed document instead of a
                // duplicate row appearing.
                {
                    std::vector<ChartLink> unique;
                    for (auto &l : chart_links)
                    {
                        bool have = false;
                        for (auto &u : unique)
                            if (u.url == l.url)
                            {
                                u = l; // the later (refreshed) document wins
                                have = true;
                            }
                        if (!have)
                            unique.push_back(std::move(l));
                    }
                    chart_links = std::move(unique);
                }
                if (was_picked)
                {
                    active_chart_link = *n_url;
                    SaveChartLinks();
                    PushChartLink();
                }
                else
                {
                    SaveChartLinks();
                }
                if (SettingsOpen())
                    BuildSettingsPage();
            });
        }).detach();
    }

    // Draw whatever is picked now. A style link is fetched fresh on every
    // push, which is also what keeps a publisher's edits showing up.
    void MainWindow::PushChartLink()
    {
        uint64_t epoch = ++chart_link_epoch;
        if (active_chart_link.empty())
        {
            AltTilesDetach();
            lk_controller_alt_style_set(controller, nullptr);
            ScaleBarCredit().Text(L"");
            ScaleBarCredit().Visibility(Visibility::Collapsed);
            return;
        }
        std::string doc;
        for (auto const &l : chart_links)
            if (l.url == active_chart_link)
                doc = l.doc;
        std::string link = active_chart_link;
        auto queue = DispatcherQueue();
        std::thread([this, queue, epoch, link, doc] {
            auto json = std::make_shared<std::string>();
            auto sources = std::make_shared<
                std::map<std::string, std::pair<std::vector<std::string>, bool>>>();
            auto credit = std::make_shared<std::string>();
            auto packs = std::make_shared<std::vector<FetchedSpritePack>>();
            std::string raw = doc;
            bool ok = false;
            try
            {
                ok = !raw.empty() || FetchText(link, raw, true);
                std::vector<SpritePackRef> pack_refs;
                // Only a style the mariner keeps on disk may read files its
                // sources name; one off the network may not.
                ok = ok && ResolveStyle(raw, *json, *sources, *credit, pack_refs,
                                        LooksLikeFileLink(link));
                // The sprite packs ride along: fetched here, off the UI
                // thread, so applying is instant.
                if (ok)
                    *packs = FetchSpritePacks(pack_refs);
            }
            catch (...)
            {
                // Wrong-typed JSON throws out of GetNamedString; a hostile
                // style must be treated as "did not answer" rather than a
                // crash.
                ok = false;
            }
            queue.TryEnqueue([this, epoch, link, ok, json, sources, credit, packs] {
                // The epoch guards the race the mariner can cause: picking a
                // second chart while the first is still being fetched. The
                // slower fetch must not win.
                if (epoch != chart_link_epoch || active_chart_link != link)
                    return;
                if (!ok)
                {
                    // A lost connection must not cost the mariner their
                    // picked chart. The selection is kept (the next open or
                    // re-pick retries it) and the Lookout chart is shown in
                    // the meantime.
                    chart_link_error =
                        "That chart didn't answer. Showing the Lookout chart until it does.";
                    AltTilesDetach();
                    lk_controller_alt_style_set(controller, nullptr);
                    ScaleBarCredit().Text(L"");
                    ScaleBarCredit().Visibility(Visibility::Collapsed);
                    if (SettingsOpen())
                        BuildSettingsPage();
                    return;
                }
                chart_link_error.clear();
                ScaleBarCredit().Text(winrt::to_hstring(*credit));
                ScaleBarCredit().Visibility(credit->empty() ? Visibility::Collapsed
                                                            : Visibility::Visible);
                {
                    std::lock_guard<std::mutex> g(alt_mu);
                    alt_sources = *sources;
                    alt_logged.clear();
                    alt_live = true;
                }
                lk_controller_set_tile_provider(controller, TileThunk, this);
                if (!lk_controller_alt_style_set(controller, json->c_str()))
                {
                    fprintf(stderr, "shell: alt chart style refused\n");
                }
                else
                {
                    // AFTER the style: setting one clears the previous
                    // style's packs, so this order is what makes the icons
                    // stick.
                    for (auto const &p : *packs)
                    {
                        int n = lk_controller_alt_sprite_pack(
                            controller, p.prefix.c_str(),
                            p.json.data(), p.json.size(),
                            reinterpret_cast<char const *>(p.png.data()), p.png.size());
                        fprintf(stderr, "shell: sprite pack '%s': %d cells\n", p.prefix.c_str(), n);
                    }
                }
            });
        }).detach();
    }

    // Stop answering, before the handle closes: a fetch landing later finds
    // the provider gone, never a dying engine.
    void MainWindow::AltTilesDetach()
    {
        {
            std::lock_guard<std::mutex> g(alt_mu);
            alt_live = false;
            alt_sources.clear();
            alt_logged.clear();
        }
        lk_controller_set_tile_provider(controller, nullptr, nullptr);
    }

    // One tile lookout wants. Called on its render thread with its lock held:
    // look the source up, start the fetch, return. Every ask is ANSWERED —
    // bytes, "no tile there", or "failed" — because a tile nobody answers is
    // a hole in the chart that never fills.
    void MainWindow::TileRequest(std::string source, uint64_t id, int z, int x, int y)
    {
        std::string url;
        {
            std::lock_guard<std::mutex> g(alt_mu);
            if (!alt_live)
                return; // the provider is being detached; the core fails the rest
            auto it = alt_sources.find(source);
            if (it != alt_sources.end())
                url = TileUrl(it->second.first, it->second.second, z, x, y);
            if (url.empty())
            {
                if (alt_logged.insert("fail:" + source).second)
                    fprintf(stderr, "shell: alt tiles: %s - no url template; failing its tiles\n",
                            source.c_str());
            }
            else if (alt_logged.insert("ask:" + source).second)
            {
                fprintf(stderr, "shell: alt tiles: %s -> %s\n", source.c_str(), url.c_str());
            }
        }
        if (url.empty())
        {
            lk_controller_tile_respond(controller, id, nullptr, 0, kTileFailed);
            return;
        }
        g_tile_pool.Run([this, url, id] {
            {
                // If the provider was detached while this task sat in the
                // queue, skip the fetch as well as the answer. A backlog of
                // 20-second dead fetches would stall live tiles behind it.
                std::lock_guard<std::mutex> g(alt_mu);
                if (!alt_live)
                    return;
            }
            std::vector<uint8_t> bytes;
            int code = FetchUrl(winrt::to_hstring(url).c_str(), bytes);
            // Under the lock, so a handle closing mid-answer is not answered
            // into; tile_respond takes no lock of the core's own.
            std::lock_guard<std::mutex> g(alt_mu);
            if (!alt_live)
                return;
            if (code == 200 && !bytes.empty())
                lk_controller_tile_respond(controller, id, bytes.data(), bytes.size(), kTileBytes);
            else if (code == 404 || code == 204 || code == 200)
                // The publisher genuinely has no tile there — a hole in their
                // coverage, not a fault, and remembered as one.
                lk_controller_tile_respond(controller, id, nullptr, 0, kTileNone);
            else
                lk_controller_tile_respond(controller, id, nullptr, 0, kTileFailed);
        });
    }
}
