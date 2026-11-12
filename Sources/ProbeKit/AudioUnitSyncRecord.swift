import Foundation

// What the audio units tab remembers across starts: which daemon it last sent
// the installed units to, and what became of each. iPadOS drops the app whenever
// another app has been in front for a while, and without this record every
// start read and sent all units again.
//
// A unit is known by its component id and version: a new or updated plugin is
// sent, one the daemon holds is not. A unit that failed is on record too, so
// the tab shows it at once, and is tried again once per start: a plugin that
// does not instantiate today may tomorrow. "resync" in the app forgets the
// record.

public struct AudioUnitSyncRecord: Codable, Equatable {
    /// What a run made of one unit.
    public enum Outcome: Codable, Equatable {
        case sent(params: Int, writable: Int)
        /// Read and sent, but it has no parameters to map.
        case empty
        /// It could not be read (it does not instantiate, say) or the daemon
        /// refused it.
        case failed(String)

        public var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    public struct Unit: Codable, Equatable {
        /// The component's version when it was read.
        public var version: String
        public var outcome: Outcome

        public init(version: String, outcome: Outcome) {
            self.version = version
            self.outcome = outcome
        }
    }

    /// An installed unit, as far as the record cares.
    public struct Installed: Equatable {
        public var id: String
        public var version: String

        public init(id: String, version: String) {
            self.id = id
            self.version = version
        }
    }

    /// The daemon the units went to, as the app reaches it (`host:port`).
    public var daemon: String
    /// Unit id → what the daemon was sent.
    public var units: [String: Unit]

    public init(daemon: String, units: [String: Unit] = [:]) {
        self.daemon = daemon
        self.units = units
    }

    /// What `daemon` was sent of this version of the unit, nil when nothing.
    public func outcome(of unit: Installed, daemon: String) -> Outcome? {
        guard daemon == self.daemon, let known = units[unit.id], known.version == unit.version else {
            return nil
        }
        return known.outcome
    }

    /// The installed units `daemon` does not hold: all of them for another
    /// daemon, else the new ones, the updated ones and those that failed.
    public func pending(_ installed: [Installed], daemon: String) -> [Installed] {
        installed.filter { outcome(of: $0, daemon: daemon)?.isFailure ?? true }
    }

    /// Note what a run made of a unit, for `daemon`. Another daemon than the
    /// recorded one starts the record over: it holds none of the units.
    public mutating func note(_ unit: Installed, outcome: Outcome, daemon: String) {
        if daemon != self.daemon {
            self = AudioUnitSyncRecord(daemon: daemon)
        }
        units[unit.id] = Unit(version: unit.version, outcome: outcome)
    }

    /// Drop units that are no longer installed.
    public mutating func prune(to installed: [Installed]) {
        let ids = Set(installed.map(\.id))
        units = units.filter { ids.contains($0.key) }
    }
}
