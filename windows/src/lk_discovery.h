// lk_discovery — what is already answering on the boat's network.
//
// A Signal K server announces itself over DNS-SD, and so do some NMEA
// gateways. A connection list declares the service types it accepts
// (lk_plugin_model.h), and this browses for them so the mariner can add a
// source without typing an address.
//
// Windows resolves a `.local` name in its own DNS client, and DnsServiceResolve
// hands back the SRV target, so A FIND CARRIES THE HOST NAME rather than the
// address behind it. A lease turns over and the address changes; the name still
// reaches the same machine.
//
// Plain Win32 and no WinRT, like the rest of src/: the pane that draws the
// finds is the only thing that should know about WinUI. The browse answers on
// thread pool threads and touches nothing the UI owns; a caller notices new
// finds by watching Generation(), which is what the settings pane's own poll
// already does for the connection lines.
#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace lkw
{
    // One service on the network, resolved far enough to fill in a row.
    struct Discovered
    {
        std::string service; // the type it answered for, which ties it to a list
        std::string name;    // what the server calls itself; it becomes the row's name
        std::string host;    // "boat.local"
        int port{ 0 };
    };

    class Discovery
    {
    public:
        // What the browse keeps between calls. Opaque here and named because
        // the callbacks in the implementation hold a share of it: a browse
        // cancelled with the window can still answer once afterwards.
        struct State;

        Discovery();
        ~Discovery();

        Discovery(Discovery const &) = delete;
        Discovery &operator=(Discovery const &) = delete;

        // Bumped whenever what has been found moves. A reader that draws the
        // finds keeps the number it drew and redraws when it changes.
        uint64_t Generation() const;

        // Browse for exactly these service types and no others. Idempotent, so
        // a caller may hand it the same list on every pass.
        void Browse(std::vector<std::string> const &services);

        // Stop looking and drop what was found.
        void Stop();

        // Everything resolved so far, copied under the lock: the browse runs on
        // its own threads and would otherwise move this under the reader.
        std::vector<Discovered> Found() const;

    private:
        std::shared_ptr<State> state_;
    };
}
