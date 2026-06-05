import Foundation
import Network

// DaemonDiscovery finds the mcp-midi-controller on the LAN via Bonjour/mDNS, so
// neither the container app nor the two AUv3 extensions need a typed host. Each
// process runs its own browser (the App Group route can't share a host under
// xtool / free-Apple-ID signing — see git history), and all three converge on
// the same advertised daemon.
//
// The daemon advertises a Bonjour service of type `_mcpmidi._tcp` on its LAN
// port. Its **TXT record** carries metadata we surface in the shared status UI:
//
//   version=<daemon semver>           e.g. "1.4.2"
//   capabilities=<comma list>         e.g. "audio,midi,sessions"
//
// We resolve the service to a concrete `host:port` (via a throwaway NWConnection
// so we get the actual reachable address), then poll `GET /healthz` to confirm
// the daemon is reachable. The networking clients (TapStreamer, BrainController)
// read `currentHost` on every (re)connect attempt and the app's HTTP flows use
// it too.
//
// Requires `NSBonjourServices` (listing `_mcpmidi._tcp`) and
// `NSLocalNetworkUsageDescription` in every bundle's Info.plist, plus the
// per-app Local Network permission.
public final class DaemonDiscovery: ObservableObject, @unchecked Sendable {
    /// One browser per process is plenty; everything shares this instance.
    public static let shared = DaemonDiscovery()

    /// The Bonjour service type the daemon advertises. Keep in sync with
    /// mcp-midi-controller's advertiser.
    public static let serviceType = "_mcpmidi._tcp"

    /// Snapshot of what we know about the daemon, for the shared status UI.
    public struct Status: Equatable, Sendable {
        /// Resolved `host:port` (numeric), or nil while still searching.
        public var host: String?
        /// `GET /healthz` succeeded against `host` recently.
        public var reachable: Bool
        /// Daemon version from the TXT record (or healthz), if advertised.
        public var version: String?
        /// Daemon capabilities from the TXT record (or healthz).
        public var capabilities: [String]

        public init(host: String? = nil, reachable: Bool = false,
                    version: String? = nil, capabilities: [String] = []) {
            self.host = host
            self.reachable = reachable
            self.version = version
            self.capabilities = capabilities
        }

        /// True once a daemon has been found on the network.
        public var discovered: Bool { host != nil }
    }

    /// Observed by SwiftUI (always mutated on the main actor).
    @Published public private(set) var status = Status()

    /// Thread-safe `host:port` for the networking clients' reconnect loops.
    private let hostBox = OSAllocatedUnfairLockBox<String?>(nil)
    public var currentHost: String? { hostBox.value }

    private let queue = DispatchQueue(label: "com.teemow.auv3probe.discovery")
    private var browser: NWBrowser?
    private var resolver: NWConnection?
    private var started = false
    private var selectedName: String?
    // TXT metadata for the currently selected service.
    private var txtVersion: String?
    private var txtCapabilities: [String] = []
    private var healthTimer: DispatchSourceTimer?
    // Reachability tracked on `queue` (the @Published `status` is only safe to
    // touch on main, so we keep our own copy here for the guard + streak).
    private var lastReachable = false
    private var unreachableStreak = 0
    /// Consecutive failed health polls (~5s each) before a discovered-but-
    /// unreachable host is treated as stale and re-resolved.
    private static let maxUnreachableBeforeReResolve = 3

    public init() {}

    /// Begin browsing (idempotent — safe to call from every view/AU).
    public func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            startBrowserLocked()
            startHealthPollLocked()
        }
    }

    // MARK: - Browsing

    private func startBrowserLocked() {
        let params = NWParameters()
        params.includePeerToPeer = false
        // `.bonjourWithTXTRecord` (not plain `.bonjour`) is required for the
        // result metadata to carry the TXT record (version / capabilities).
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: params)
        browser.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            if case .failed = state {
                // mDNS hiccup or permission not yet granted — rebuild shortly.
                self.queue.asyncAfter(deadline: .now() + 2) { self.restartBrowserLocked() }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handle(results: results)
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    private func restartBrowserLocked() {
        browser?.cancel()
        browser = nil
        startBrowserLocked()
    }

    private func handle(results: Set<NWBrowser.Result>) {
        // Prefer a stable choice: keep the current service if still present,
        // otherwise pick the lowest-named one for determinism.
        let services = results.compactMap { result -> (name: String, result: NWBrowser.Result)? in
            if case let .service(name, _, _, _) = result.endpoint { return (name, result) }
            return nil
        }
        guard !services.isEmpty else {
            clearSelectionLocked()
            return
        }
        let chosen = services.first(where: { $0.name == selectedName })
            ?? services.sorted(by: { $0.name < $1.name }).first!

        // Read TXT metadata (version / capabilities) from the browse result.
        if case let .bonjour(txt) = chosen.result.metadata {
            txtVersion = txtString(txt, "version")
            txtCapabilities = (txtString(txt, "capabilities") ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }

        if chosen.name != selectedName || currentHost == nil {
            selectedName = chosen.name
            resolve(chosen.result.endpoint)
        } else {
            // Same service, possibly refreshed TXT — republish metadata.
            publishLocked(hostOverride: currentHost)
        }
    }

    private func clearSelectionLocked() {
        selectedName = nil
        txtVersion = nil
        txtCapabilities = []
        resolver?.cancel()
        resolver = nil
        hostBox.value = nil
        lastReachable = false
        unreachableStreak = 0
        publishLocked(hostOverride: nil)
    }

    // MARK: - Resolution (service -> host:port)

    private func resolve(_ endpoint: NWEndpoint) {
        resolver?.cancel()
        let conn = NWConnection(to: endpoint, using: .tcp)
        resolver = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                if let remote = conn.currentPath?.remoteEndpoint,
                   case let .hostPort(host, port) = remote {
                    let resolved = self.format(host: host, port: port)
                    self.hostBox.value = resolved
                    // Fresh address: give it a clean slate before health polls.
                    self.unreachableStreak = 0
                    self.publishLocked(hostOverride: resolved)
                }
                conn.cancel()
            case .failed, .cancelled:
                if self.resolver === conn { self.resolver = nil }
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func format(host: NWEndpoint.Host, port: NWEndpoint.Port) -> String {
        var raw: String
        var isIPv6 = false
        switch host {
        case .ipv4(let addr): raw = "\(addr)"
        case .ipv6(let addr): raw = "\(addr)"; isIPv6 = true
        case .name(let name, _): raw = name
        @unknown default: raw = "\(host)"
        }
        // Drop any scope/zone id (e.g. "192.168.2.204%en0" or "fe80::1%en0");
        // URLSession routes via the default interface on a single-LAN device.
        if let zone = raw.firstIndex(of: "%") { raw = String(raw[..<zone]) }
        if raw.contains(":") { isIPv6 = true }
        return isIPv6 ? "[\(raw)]:\(port.rawValue)" : "\(raw):\(port.rawValue)"
    }

    private func txtString(_ txt: NWTXTRecord, _ key: String) -> String? {
        if case let .string(value) = txt.getEntry(for: key) { return value }
        return nil
    }

    // MARK: - Reachability (healthz)

    private func startHealthPollLocked() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 5)
        timer.setEventHandler { [weak self] in self?.pollHealth() }
        healthTimer = timer
        timer.resume()
    }

    private func pollHealth() {
        guard let host = currentHost, let client = DaemonClient(host: host) else {
            updateReachable(false)
            return
        }
        Task { [weak self] in
            do {
                try await client.healthz()
                self?.updateReachable(true)
            } catch {
                self?.updateReachable(false)
            }
        }
    }

    private func updateReachable(_ reachable: Bool) {
        queue.async { [self] in
            if reachable {
                unreachableStreak = 0
            } else if currentHost != nil {
                unreachableStreak += 1
                if unreachableStreak >= Self.maxUnreachableBeforeReResolve {
                    // A discovered host that stays unreachable is most likely
                    // stale (the daemon moved address, or the cached resolution
                    // went bad). Drop it and re-browse so the next result
                    // re-resolves a fresh address rather than retrying a dead one.
                    clearSelectionLocked()
                    restartBrowserLocked()
                    return
                }
            }
            guard lastReachable != reachable else { return }
            lastReachable = reachable
            publishLocked(hostOverride: currentHost, reachable: reachable)
        }
    }

    // MARK: - Publish

    /// Build a `Status` from the current selection and push it to the main actor.
    /// `reachable` defaults to the last known value so metadata refreshes don't
    /// clobber it. Must be called on `queue`.
    private func publishLocked(hostOverride: String?, reachable: Bool? = nil) {
        let version = txtVersion
        let caps = txtCapabilities
        let host = hostOverride
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            var next = self.status
            next.host = host
            next.version = version
            next.capabilities = caps
            if let reachable = reachable { next.reachable = reachable }
            if host == nil { next.reachable = false }
            if next != self.status { self.status = next }
        }
    }
}
