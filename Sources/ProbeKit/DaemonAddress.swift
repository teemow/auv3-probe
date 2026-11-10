import Foundation

// DaemonAddress is one numeric address a Bonjour resolve produced for the
// daemon, plus the rules DaemonDiscovery uses to pick between several of them
// and to turn the winner into the `host:port` string every client parses.
//
// It is plain value logic on strings (no Network.framework types), so the
// address choice and the host formatting are unit-testable on their own.
//
// Why the ranking matters: a dual-stack daemon resolves to an IPv4 address and
// often only a link-local IPv6 one (fe80::/10). A link-local address is only
// routable together with its zone (`%en0`); without the zone the HTTP client
// has no interface to send it on, and the daemon looks unreachable even though
// Bonjour found it. So IPv4 wins, a link-local IPv6 address keeps its zone, and
// addresses whose health checks kept failing go to the back of the queue.
struct DaemonAddress: Equatable, Sendable {
    /// The numeric address (or name) without brackets or zone.
    let address: String
    /// The scope/zone id (`en0`, or a numeric index) Network.framework attached,
    /// if any.
    let zone: String?
    let port: UInt16

    /// Parse an address as Network.framework prints it: `192.168.1.5`,
    /// `192.168.1.5%en0`, `fe80::1%en0`, `2001:db8::1` (brackets tolerated).
    init(_ text: String, port: UInt16) {
        var raw = text.trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("["), raw.hasSuffix("]") {
            raw = String(raw.dropFirst().dropLast())
        }
        if let percent = raw.firstIndex(of: "%") {
            let zone = String(raw[raw.index(after: percent)...])
            self.zone = zone.isEmpty ? nil : zone
            raw = String(raw[..<percent])
        } else {
            self.zone = nil
        }
        self.address = raw
        self.port = port
    }

    /// How usable an address is for an HTTP client on the LAN, best first.
    enum Kind: Int, Comparable, Sendable {
        /// IPv4 (or a hostname): routes without any interface hint.
        case ipv4
        /// Global or unique-local IPv6: routes without a zone.
        case ipv6Routable
        /// Link-local IPv6 that still carries its zone, so it can be dialled.
        case ipv6LinkLocalScoped
        /// Self-assigned IPv4 (169.254/16): only works when both ends lack DHCP.
        case ipv4LinkLocal
        /// Link-local IPv6 without a zone: no interface to send it on.
        case ipv6LinkLocalUnscoped

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var isIPv6: Bool { address.contains(":") }

    /// fe80::/10 — the first 16-bit group is fe80…febf.
    var isIPv6LinkLocal: Bool {
        guard isIPv6 else { return false }
        let first = address.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        guard let group = UInt16(first, radix: 16) else { return false }
        return group & 0xffc0 == 0xfe80
    }

    var kind: Kind {
        if isIPv6 {
            if isIPv6LinkLocal { return zone == nil ? .ipv6LinkLocalUnscoped : .ipv6LinkLocalScoped }
            return .ipv6Routable
        }
        return address.hasPrefix("169.254.") ? .ipv4LinkLocal : .ipv4
    }

    /// The `host:port` string DaemonClient parses. IPv6 is bracketed. Only a
    /// link-local IPv6 address keeps its zone (`[fe80::1%en0]:7800`): it is
    /// unreachable without one, and every other address routes fine without.
    var hostPort: String {
        guard isIPv6 else { return "\(address):\(port)" }
        if isIPv6LinkLocal, let zone {
            return "[\(address)%\(zone)]:\(port)"
        }
        return "[\(address)]:\(port)"
    }

    /// Pick the address to use from what a resolve produced.
    ///
    /// Addresses not in `failed` win over those that are; among them the best
    /// `kind` wins, and ties keep resolve order. When every candidate has failed
    /// before, the one that failed longest ago is retried, so repeated
    /// re-resolves rotate through the addresses instead of retrying one forever.
    ///
    /// - Parameter failed: `hostPort` strings whose health checks kept failing,
    ///   oldest failure first.
    static func preferred(_ candidates: [DaemonAddress], failed: [String] = []) -> DaemonAddress? {
        let fresh = candidates.enumerated().filter { !failed.contains($0.element.hostPort) }
        if let best = fresh.min(by: { ($0.element.kind, $0.offset) < ($1.element.kind, $1.offset) }) {
            return best.element
        }
        return candidates.min(by: {
            (failed.firstIndex(of: $0.hostPort) ?? .max) < (failed.firstIndex(of: $1.hostPort) ?? .max)
        })
    }

    /// Record `hostPort` as the newest failure in a failure list (moving it to
    /// the end if already present), keeping at most `limit` entries.
    static func recordFailure(_ hostPort: String, in failed: [String], limit: Int = 8) -> [String] {
        var next = failed.filter { $0 != hostPort }
        next.append(hostPort)
        return Array(next.suffix(limit))
    }
}
