import Foundation
import os

/// A tiny lock-protected box for a value shared between a background queue and
/// the UI thread (e.g. a last-error string). NOT for the realtime path — use the
/// lock-free rings/atomics there. Shared by ProbeAudioTap's TapStreamer and
/// ProbeMidiBrain's BrainController so both extensions reuse one helper.
public final class OSAllocatedUnfairLockBox<Value>: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<Value>
    public init(_ initial: Value) { lock = OSAllocatedUnfairLock(initialState: initial) }
    public var value: Value {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
}
