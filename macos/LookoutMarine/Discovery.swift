//  Discovery.swift — what is already answering on the boat's network.
//
//  A Signal K server, and some NMEA gateways, announce themselves over DNS-SD.
//  A plugin's connection list declares the service types it accepts, the core
//  passes that through in the registry, and this browses for them so the
//  mariner adds a source with one tap instead of typing an address.
//
//  A FOUND SERVICE IS KEPT BY NAME, never by the address behind it. A lease
//  turns over and the number changes; the name is what keeps a saved row
//  pointed at the same machine. `net_posix.lookup` is getaddrinfo, which
//  resolves a `.local` name here through mDNSResponder, and every reconnect
//  resolves again.
//
//  That is also why this uses NetService. It has been deprecated since macOS
//  12, and it is still the only API on this platform that hands back the SRV
//  target's HOST NAME: NWBrowser resolves a service through an NWConnection,
//  which knows the address it connected to and not the name it came from.

import Foundation
import Combine

/// One service on the network, resolved far enough to fill in a row.
struct DiscoveredService: Identifiable, Equatable {
    /// The service type it answered for, which is what ties it to a list.
    let service: String
    /// What the server calls itself. It becomes the row's name.
    let name: String
    /// The host name, with the trailing dot taken off.
    let host: String
    let port: Int

    var id: String { "\(service)/\(name)" }
}

/// Browses the local network for the service types the loaded plugins declare.
/// It runs while the settings window is open and not a moment longer: a browse
/// nobody is watching is a radio left on.
@MainActor
final class Discovery: NSObject, ObservableObject {
    @Published private(set) var found: [DiscoveredService] = []

    /// Longest a resolve is given before it is given up on. A host that has
    /// not answered by then is not one the mariner can connect to either.
    private let resolveTimeout: TimeInterval = 5

    private var browsers: [String: NetServiceBrowser] = [:]
    /// The services being resolved. Held because a NetService stops resolving
    /// the moment nothing owns it.
    private var resolving: Set<NetService> = []

    /// Browse for exactly these service types and no others. Idempotent, so a
    /// caller may hand it the same list on every pass.
    func browse(_ services: [String]) {
        let want = Set(services.map(Self.normalize))
        for type in browsers.keys.filter({ !want.contains($0) }) {
            browsers.removeValue(forKey: type)?.stop()
            found.removeAll { $0.service == type }
            // A resolve in flight for this type would otherwise answer after
            // the browse stopped and put the find back.
            for service in resolving.filter({ Self.normalize($0.type) == type }) {
                service.stop()
                resolving.remove(service)
            }
        }
        for type in want where browsers[type] == nil {
            let browser = NetServiceBrowser()
            browser.delegate = self
            browsers[type] = browser
            browser.searchForServices(ofType: type, inDomain: "local.")
        }
    }

    /// Stop looking, and forget what was found. What is on the network is only
    /// true while something is watching it.
    func stop() {
        for browser in browsers.values { browser.stop() }
        browsers.removeAll()
        for service in resolving { service.stop() }
        resolving.removeAll()
        found.removeAll()
    }

    /// A service type as this compares them: no trailing dot, whichever way
    /// the manifest and the platform each wrote it.
    private static func normalize(_ type: String) -> String {
        type.hasSuffix(".") ? String(type.dropLast()) : type
    }
}

// The browser and its resolves are scheduled on the main run loop, which is
// where these arrive.
extension Discovery: NetServiceBrowserDelegate, NetServiceDelegate {
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser,
                                       didFind service: NetService,
                                       moreComing: Bool) {
        MainActor.assumeIsolated {
            service.delegate = self
            resolving.insert(service)
            service.resolve(withTimeout: resolveTimeout)
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser,
                                       didRemove service: NetService,
                                       moreComing: Bool) {
        MainActor.assumeIsolated {
            let type = Self.normalize(service.type)
            resolving.remove(service)
            found.removeAll { $0.service == type && $0.name == service.name }
        }
    }

    nonisolated func netServiceDidResolveAddress(_ service: NetService) {
        MainActor.assumeIsolated {
            resolving.remove(service)
            let type = Self.normalize(service.type)
            // Nothing is browsing for this any more: the window shut, or the
            // plugin that wanted it went away while the resolve was in flight.
            guard browsers[type] != nil else { return }
            guard let hostName = service.hostName, service.port > 0 else { return }
            let host = hostName.hasSuffix(".") ? String(hostName.dropLast()) : hostName
            let entry = DiscoveredService(service: type,
                                          name: service.name,
                                          host: host,
                                          port: service.port)
            // One server answers on every interface it holds. The second
            // answer is the same machine, so it replaces the first rather than
            // showing up beside it.
            if let at = found.firstIndex(where: { $0.id == entry.id }) {
                found[at] = entry
            } else {
                found.append(entry)
            }
        }
    }

    nonisolated func netService(_ service: NetService,
                                didNotResolve errorDict: [String: NSNumber]) {
        MainActor.assumeIsolated { _ = resolving.remove(service) }
    }
}
