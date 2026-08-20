#include "pch.h"

#include "lk_discovery.h"

#include <windns.h>

#include <algorithm>
#include <mutex>

#pragma comment(lib, "dnsapi.lib")

namespace lkw
{
    namespace
    {
        std::wstring Wide(std::string const &s)
        {
            if (s.empty())
                return {};
            int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0);
            std::wstring out((size_t)n, L'\0');
            MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), out.data(), n);
            return out;
        }

        std::string Utf8(wchar_t const *s)
        {
            if (s == nullptr || *s == L'\0')
                return {};
            int len = (int)wcslen(s);
            int n = WideCharToMultiByte(CP_UTF8, 0, s, len, nullptr, 0, nullptr, nullptr);
            std::string out((size_t)n, '\0');
            WideCharToMultiByte(CP_UTF8, 0, s, len, out.data(), n, nullptr, nullptr);
            return out;
        }

        // A service type or host name as this keeps them: no trailing dot,
        // whichever way the manifest and the resolver each wrote it.
        std::string Trimmed(std::string name)
        {
            while (!name.empty() && name.back() == '.')
                name.pop_back();
            return name;
        }

        // What the server calls itself, out of the instance name DNS-SD carries.
        //
        // "Boat._signalk-ws._tcp.local" is the whole name, and the label in
        // front of the type is the part a mariner recognises. A dot inside that
        // label arrives escaped, because the name is a DNS name first.
        std::string InstanceLabel(std::string const &instance, std::string const &service)
        {
            std::string label = instance;
            size_t at = label.find("." + service);
            if (at != std::string::npos)
                label.erase(at);

            std::string out;
            out.reserve(label.size());
            for (size_t i = 0; i < label.size(); ++i)
            {
                if (label[i] == '\\' && i + 1 < label.size())
                    ++i;
                out.push_back(label[i]);
            }
            return out;
        }
    }

    // One call in flight.
    //
    // It OWNS a reference to the state, so a callback still on its way has
    // something to answer into. A resolve's context is freed by its own
    // callback. A browse answers many times over its life, so its context is
    // freed when the browse is cancelled: DnsServiceBrowseCancel ends the
    // operation, and the `stopped` flag covers anything already on a thread
    // pool thread when it does.
    struct Pending
    {
        std::shared_ptr<Discovery::State> state;
        std::string service;
        std::wstring query;          // kept alive for the length of the call
        DNS_SERVICE_CANCEL cancel{}; // a resolve's own; a browse uses the state's
    };

    struct Discovery::State
    {
        mutable std::mutex lock;
        std::vector<Discovered> found;
        uint64_t generation{ 0 };

        // One type being browsed: the handle its browse runs under, and the
        // context its callback reads.
        struct Browse
        {
            std::string service;
            DNS_SERVICE_CANCEL cancel{};
            Pending *context{ nullptr };
        };
        std::vector<Browse> browses;
        bool stopped{ false };

        bool Wants(std::string const &service) const
        {
            return std::any_of(browses.begin(), browses.end(),
                               [&](Browse const &b) { return b.service == service; });
        }
    };

    namespace
    {
        void WINAPI ResolveDone(DWORD status, PVOID context, PDNS_SERVICE_INSTANCE instance)
        {
            std::unique_ptr<Pending> pending(static_cast<Pending *>(context));
            if (status != ERROR_SUCCESS || instance == nullptr)
            {
                if (instance != nullptr)
                    DnsServiceFreeInstance(instance);
                return;
            }

            Discovered entry;
            entry.service = pending->service;
            entry.name = InstanceLabel(Utf8(instance->pszInstanceName), pending->service);
            entry.host = Trimmed(Utf8(instance->pszHostName));
            entry.port = instance->wPort;
            DnsServiceFreeInstance(instance);

            if (entry.host.empty() || entry.port <= 0 || entry.name.empty())
                return;

            {
                std::lock_guard<std::mutex> guard(pending->state->lock);
                auto &state = *pending->state;

                // Nothing is browsing for this any more: the window shut while
                // the resolve was in flight.
                if (state.stopped || !state.Wants(entry.service))
                    return;

                // One server answers on every interface it holds. The second
                // answer is the same machine, so it replaces the first rather
                // than showing up beside it.
                auto held = std::find_if(state.found.begin(), state.found.end(),
                                         [&](Discovered const &d) {
                                             return d.service == entry.service &&
                                                    d.name == entry.name;
                                         });
                if (held != state.found.end())
                    *held = entry;
                else
                    state.found.push_back(entry);
                state.generation++;
            }
        }

        void Resolve(std::shared_ptr<Discovery::State> const &state, std::string const &service,
                     wchar_t const *instance_name)
        {
            auto pending = std::make_unique<Pending>();
            pending->state = state;
            pending->service = service;
            pending->query = instance_name;

            DNS_SERVICE_RESOLVE_REQUEST request{};
            request.Version = DNS_QUERY_REQUEST_VERSION1;
            request.InterfaceIndex = 0;
            request.QueryName = pending->query.data();
            request.pResolveCompletionCallback = ResolveDone;
            request.pQueryContext = pending.get();

            if (DnsServiceResolve(&request, &pending->cancel) != DNS_REQUEST_PENDING)
                return; // nothing answered, and the context goes with this scope

            (void)pending.release(); // the callback owns it now
        }

        void WINAPI BrowseFound(DWORD status, PVOID context, PDNS_RECORD records)
        {
            auto *pending = static_cast<Pending *>(context);
            if (status != ERROR_SUCCESS || records == nullptr)
            {
                if (records != nullptr)
                    DnsRecordListFree(records, DnsFreeRecordList);
                return; // the browse stays live: it answers again as services come and go
            }

            {
                std::lock_guard<std::mutex> guard(pending->state->lock);
                if (pending->state->stopped)
                {
                    DnsRecordListFree(records, DnsFreeRecordList);
                    return;
                }
            }

            // A browse answers with the pointer records naming each instance;
            // where it answers is what the resolve is for.
            for (PDNS_RECORD record = records; record != nullptr; record = record->pNext)
            {
                if (record->wType != DNS_TYPE_PTR || record->Data.PTR.pNameHost == nullptr)
                    continue;
                Resolve(pending->state, pending->service, record->Data.PTR.pNameHost);
            }
            DnsRecordListFree(records, DnsFreeRecordList);
        }
    }

    Discovery::Discovery() : state_(std::make_shared<State>()) {}

    Discovery::~Discovery() { Stop(); }

    uint64_t Discovery::Generation() const
    {
        std::lock_guard<std::mutex> guard(state_->lock);
        return state_->generation;
    }

    void Discovery::Browse(std::vector<std::string> const &services)
    {
        std::vector<std::string> want;
        for (auto const &service : services)
        {
            std::string type = Trimmed(service);
            if (!type.empty() && std::find(want.begin(), want.end(), type) == want.end())
                want.push_back(type);
        }

        std::vector<std::string> start;
        {
            std::lock_guard<std::mutex> guard(state_->lock);
            state_->stopped = false;

            // Anything no list asks for any more stops, and its finds go with it.
            for (size_t i = state_->browses.size(); i > 0; --i)
            {
                auto &browse = state_->browses[i - 1];
                if (std::find(want.begin(), want.end(), browse.service) != want.end())
                    continue;

                std::string gone = browse.service;
                DnsServiceBrowseCancel(&browse.cancel);
                delete browse.context;
                state_->browses.erase(state_->browses.begin() + (ptrdiff_t)(i - 1));
                state_->found.erase(std::remove_if(state_->found.begin(), state_->found.end(),
                                                   [&](Discovered const &d) {
                                                       return d.service == gone;
                                                   }),
                                    state_->found.end());
                state_->generation++;
            }
            for (auto const &type : want)
            {
                if (!state_->Wants(type))
                    start.push_back(type);
            }
        }

        for (auto const &type : start)
        {
            // The manifest names the type; DNS-SD asks for it in the local
            // domain, which is the only one a boat's network has.
            auto pending = std::make_unique<Pending>();
            pending->state = state_;
            pending->service = type;
            pending->query = Wide(type + ".local");

            DNS_SERVICE_BROWSE_REQUEST request{};
            request.Version = DNS_QUERY_REQUEST_VERSION1;
            request.InterfaceIndex = 0;
            request.QueryName = pending->query.c_str();
            request.pBrowseCallback = BrowseFound;
            request.pQueryContext = pending.get();

            std::lock_guard<std::mutex> guard(state_->lock);
            State::Browse browse;
            browse.service = type;
            browse.context = pending.get();
            state_->browses.push_back(std::move(browse));
            if (DnsServiceBrowse(&request, &state_->browses.back().cancel) != DNS_REQUEST_PENDING)
            {
                // No mDNS on this machine, or a type it would not take. Neither
                // is worth a line in the log, and neither is worth a retry.
                state_->browses.pop_back();
                continue;
            }
            (void)pending.release(); // freed when the browse is cancelled
        }
    }

    void Discovery::Stop()
    {
        std::vector<Discovered> dropped;
        {
            std::lock_guard<std::mutex> guard(state_->lock);
            state_->stopped = true;
            for (auto &browse : state_->browses)
            {
                DnsServiceBrowseCancel(&browse.cancel);
                delete browse.context;
            }
            state_->browses.clear();
            state_->found.swap(dropped);
            state_->generation++;
        }
    }

    std::vector<Discovered> Discovery::Found() const
    {
        std::lock_guard<std::mutex> guard(state_->lock);
        return state_->found;
    }
}
