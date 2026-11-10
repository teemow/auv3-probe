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
// We resolve the service to a concrete `host:port` (via throwaway NWConnections,
// one per IP family, so we get addresses that actually accept a connection and
// can prefer IPv4 over a link-local IPv6 — see DaemonAddress), then poll
// `GET /healthz` to confirm the daemon is reachable. The networking clients
// (TapStreamer, BrainController) read `currentHost` on every (re)connect attempt
// and the app's HTTP flows use it too.
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
        /// True when `host` is a user-typed override rather than a Bonjour
        /// discovery (the fallback for networks where mDNS is blocked).
        public var manual: Bool

        public init(host: String? = nil, reachable: Bool = false,
                    version: String? = nil, capabilities: [String] = [],
                    manual: Bool = false) {
            self.host = host
            self.reachable = reachable
            self.version = version
            self.capabilities = capabilities
            self.manual = manual
        }

        /// True once a daemon has been found on the network.
        public var discovered: Bool { host != nil }
    }

    /// Observed by SwiftUI (always mutated on the main actor).
    @Published public private(set) var status = Status()

    /// UserDefaults key for the persisted manual host override.
    private static let manualKey = "com.teemow.auv3probe.manualHost"

    /// Thread-safe `host:port` for the networking clients' reconnect loops.
    private let hostBox = OSAllocatedUnfairLockBox<String?>(nil)
    /// A user-typed `host:port` override that wins over Bonjour discovery, for
    /// LANs where mDNS is blocked. Persisted so it survives relaunch.
    private let manualBox = OSAllocatedUnfairLockBox<String?>(
        UserDefaults.standard.string(forKey: DaemonDiscovery.manualKey))

    /// The effective host every client and HTTP flow uses: the manual override
    /// when set, otherwise the auto-discovered address.
    public var currentHost: String? { manualBox.value ?? hostBox.value }

    /// The raw manual override (`host:port`), or nil when relying on discovery.
    public var manualHost: String? { manualBox.value }

    private let queue = DispatchQueue(label: "com.teemow.auv3probe.discovery")
    private var browser: NWBrowser?
    /// In-flight resolve probes (one per IP family) for the selected service.
    private var resolvers: [NWConnection] = []
    /// Addresses the current resolve has produced so far.
    private var candidates: [DaemonAddress] = []
    /// `host:port` strings whose health polls kept failing, oldest first. Kept
    /// across re-resolves so the next pick moves off a dead address.
    private var failedHosts: [String] = []
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
    // At most one health poll in flight: if a `healthz()` runs longer than the
    // poll interval, the next tick is skipped rather than stacking requests.
    private var healthInFlight = false
    /// Consecutive failed health polls (~5s each) before a discovered service
    /// whose address is unreachable (or never resolved) is re-resolved.
    private static let maxUnreachableBeforeReResolve = 3

    public init() {}

    /// Begin browsing (idempotent — safe to call from every view/AU).
    public func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            startBrowserLocked()
            startHealthPollLocked()
            // Surface a persisted manual override immediately on launch.
            if manualBox.value != nil {
                publishLocked(hostOverride: hostBox.value)
            }
        }
    }

    // MARK: - Manual host override (mDNS-blocked fallback)

    /// Set (or clear, with nil/empty) the manual `host:port` override. Persists
    /// across launches, takes precedence over discovery while set, and triggers
    /// an immediate reachability check so the UI reflects it at once.
    public func setManualHost(_ raw: String?) {
        let normalized = Self.normalizeManual(raw)
        queue.async { [self] in
            manualBox.value = normalized
            if let normalized {
                UserDefaults.standard.set(normalized, forKey: Self.manualKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.manualKey)
                // Re-browse so discovery can re-resolve a fresh address now that
                // nothing is overriding it (browse results may not change again).
                restartBrowserLocked()
            }
            unreachableStreak = 0
            lastReachable = false
            publishLocked(hostOverride: hostBox.value, reachable: false)
            pollHealth()
        }
    }

    /// Normalize a typed host into `host:port`: trim, drop any `http(s)://`
    /// scheme and trailing slash, bracket a bare IPv6 address, and default the
    /// port to the daemon's `:7800` when none is given. Returns nil for empty
    /// input.
    static func normalizeManual(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        if let range = s.range(of: "://") { s = String(s[range.upperBound...]) }
        if s.hasSuffix("/") { s.removeLast() }
        if s.isEmpty { return nil }
        // Bracketed IPv6 (`[::1]` or `[::1]:7800`) — only add a port if absent.
        if s.hasPrefix("[") {
            return s.contains("]:") ? s : "\(s):7800"
        }
        // Bare IPv6 (`fe80::1%en0`): more than one colon can't be host:port,
        // so it is all address — bracket it and add the default port.
        if s.filter({ $0 == ":" }).count > 1 {
            return "[\(s)]:7800"
        }
        // Plain host / IPv4: a single colon means a port is present.
        return s.contains(":") ? s : "\(s):7800"
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
        cancelResolversLocked()
        hostBox.value = nil
        lastReachable = false
        unreachableStreak = 0
        publishLocked(hostOverride: nil)
    }

    // MARK: - Resolution (service -> host:port)

    /// Resolve the service with one probe connection per IP family. A plain
    /// `.tcp` probe returns whichever address Happy Eyeballs connects first,
    /// which on a dual-stack LAN is often a link-local IPv6 address; probing
    /// each family lets DaemonAddress prefer IPv4. Each probe that connects
    /// offers its address; the best one so far becomes `hostBox`, so a better
    /// address that answers a moment later still replaces a worse one.
    private func resolve(_ endpoint: NWEndpoint) {
        cancelResolversLocked()
        for version in [NWProtocolIP.Options.Version.v4, .v6] {
            let params = NWParameters.tcp
            params.includePeerToPeer = false
            if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                ip.version = version
            }
            let conn = NWConnection(to: endpoint, using: params)
            resolvers.append(conn)
            conn.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                // Ignore late events from probes a newer resolve replaced.
                guard self.resolvers.contains(where: { $0 === conn }) else { return }
                switch state {
                case .ready:
                    if let remote = conn.currentPath?.remoteEndpoint,
                       case let .hostPort(host, port) = remote {
                        self.offerLocked(Self.address(host: host, port: port))
                    }
                    conn.cancel()
                case .waiting, .failed:
                    // No address of this family answers (an IPv4-only daemon in
                    // the IPv6 probe, say). The other probe may still succeed;
                    // if neither does, the health poll re-resolves later.
                    conn.cancel()
                case .cancelled:
                    self.resolvers.removeAll { $0 === conn }
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
    }

    private func cancelResolversLocked() {
        let old = resolvers
        resolvers = []
        candidates = []
        old.forEach { $0.cancel() }
    }

    /// Add a resolved address and switch `hostBox` to the best one so far.
    private func offerLocked(_ address: DaemonAddress) {
        if !candidates.contains(address) { candidates.append(address) }
        guard let best = DaemonAddress.preferred(candidates, failed: failedHosts) else { return }
        let resolved = best.hostPort
        guard resolved != hostBox.value else { return }
        hostBox.value = resolved
        // Fresh address: give it a clean slate before health polls.
        unreachableStreak = 0
        publishLocked(hostOverride: resolved)
    }

    /// The probe's remote endpoint as a DaemonAddress, zone included.
    private static func address(host: NWEndpoint.Host, port: NWEndpoint.Port) -> DaemonAddress {
        var text: String
        switch host {
        case .ipv4(let addr): text = "\(addr)"
        case .ipv6(let addr):
            text = "\(addr)"
            // Keep the scope even if the description leaves it out: a
            // link-local address is unreachable without it.
            if !text.contains("%"), let interface = addr.interface {
                text += "%\(interface.name)"
            }
        case .name(let name, _): text = name
        @unknown default: text = "\(host)"
        }
        return DaemonAddress(text, port: port.rawValue)
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
        guard !healthInFlight else { return }
        guard let host = currentHost, let client = DaemonClient(host: host) else {
            updateReachable(false)
            return
        }
        healthInFlight = true
        Task { [weak self] in
            let reachable = (try? await client.healthz()) != nil
            self?.updateReachable(reachable)
        }
    }

    private func updateReachable(_ reachable: Bool) {
        queue.async { [self] in
            healthInFlight = false
            if reachable {
                unreachableStreak = 0
                if manualBox.value == nil, let host = hostBox.value {
                    failedHosts.removeAll { $0 == host }
                }
            } else if manualBox.value == nil && selectedName != nil {
                // Only re-resolve discovered hosts. A manual override is the
                // user's deliberate choice — leave it pinned even when
                // unreachable so the UI keeps showing it (and keeps polling).
                // A service that was found but never resolved counts too, so
                // probes that gave up (no permission yet, no route) get retried.
                unreachableStreak += 1
                if unreachableStreak >= Self.maxUnreachableBeforeReResolve {
                    // A discovered host that stays unreachable is most likely
                    // stale (the daemon moved address, or the resolved address
                    // can't be dialled). Remember it as failed so the next
                    // resolve prefers another address, then drop it and
                    // re-browse so the next result re-resolves.
                    if let dead = hostBox.value {
                        failedHosts = DaemonAddress.recordFailure(dead, in: failedHosts)
                    }
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
        let manual = manualBox.value
        // A manual override wins over the discovered address; its TXT metadata
        // is unknown (we didn't browse it), so present it without caps/version.
        let host = manual ?? hostOverride
        let version = manual == nil ? txtVersion : nil
        let caps = manual == nil ? txtCapabilities : []
        let isManual = manual != nil
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            var next = self.status
            next.host = host
            next.version = version
            next.capabilities = caps
            next.manual = isManual
            if let reachable = reachable { next.reachable = reachable }
            if host == nil { next.reachable = false }
            if next != self.status { self.status = next }
        }
    }
}
