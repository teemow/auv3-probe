import Foundation
import AVFoundation
import AudioToolbox
import Atomics
import ProbeKit

// TapDSP holds the realtime state for ProbeAudioTap: a transparent passthrough
// plus a tap that captures full-rate, full-fidelity audio — interleaved native
// float32 at the host sample rate, every channel — and pushes it into a
// lock-free ring for the networking thread to drain. Like BrainEngine, it is a
// separate object from the AUAudioUnit so the render closure can capture it
// without a retain cycle.
//
// Realtime discipline: the render block pulls input straight into the output
// buffers (zero-copy passthrough), then computes block peak/RMS and copies the
// channels interleaved into the preallocated scratch buffer and on into the ring
// — no allocation, no locks, no downmix, no decimation. If the ring is full (the
// network thread fell behind) the overflow is dropped: a stalled tap must never
// glitch the audio path.

final class TapDSP: @unchecked Sendable {
    /// ~2 seconds of interleaved stereo audio at 48 kHz (2 ch × 48000 × 2 s)
    /// keeps latency low while tolerating network hiccups at full fidelity.
    static let ringCapacity = 192_000

    let ring = RealtimeRing(capacity: ringCapacity)

    /// Whether the tap is actively capturing (set by the UI / config).
    let capturing = ManagedAtomic<Bool>(false)

    // Block features, stored as Float bit patterns so they are atomically
    // readable by the UI / streamer without locking.
    let peakBits = ManagedAtomic<UInt32>(0)
    let rmsBits = ManagedAtomic<UInt32>(0)

    // Render-thread-only scratch holding one render block's interleaved samples.
    private var scratch: UnsafeMutableBufferPointer<Float>?

    /// Allocate the per-render interleaved scratch buffer (called from
    /// allocateRenderResources, off the realtime thread). Sized for
    /// `maxFrames × channels` so a full render block can be interleaved without
    /// any realtime allocation.
    func prepare(maxFrames: Int, channels: Int) {
        scratch?.deallocate()
        let capacity = max(1, maxFrames) * max(1, channels)
        let buf = UnsafeMutableBufferPointer<Float>.allocate(capacity: capacity)
        buf.initialize(repeating: 0)
        scratch = buf
    }

    func teardown() {
        scratch?.deallocate()
        scratch = nil
    }

    /// Current peak/RMS as Floats (for the UI meter).
    var levels: (peak: Float, rms: Float) {
        (Float(bitPattern: peakBits.load(ordering: .relaxed)),
         Float(bitPattern: rmsBits.load(ordering: .relaxed)))
    }

    func makeRenderBlock() -> AUInternalRenderBlock {
        return { [self]
            actionFlags, timestamp, frameCount, outputBusNumber, outputData, eventListHead, pullInputBlock in
            _ = outputBusNumber
            _ = eventListHead

            guard let pull = pullInputBlock else {
                return kAudioUnitErr_NoConnection
            }
            // Pull input straight into the output buffers → transparent passthrough.
            let status = pull(actionFlags, timestamp, frameCount, 0, outputData)
            if status != noErr { return status }

            self.tap(outputData, frameCount: Int(frameCount))
            return noErr
        }
    }

    /// Compute features + push interleaved native-rate samples. Realtime-safe.
    private func tap(_ outputData: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        guard capturing.load(ordering: .relaxed), frameCount > 0, let scratch = scratch else { return }
        let abl = UnsafeMutableAudioBufferListPointer(outputData)
        let channels = abl.count
        guard channels > 0 else { return }

        // Each AUv3 buffer is one channel of deinterleaved Float. Clamp to the
        // scratch capacity (frames × channels) so we never overrun it.
        let maxFrames = scratch.count / channels
        let frames = Swift.min(frameCount, maxFrames)
        guard frames > 0 else { return }

        var peak: Float = 0
        var sumSquares: Float = 0
        var idx = 0
        for frame in 0..<frames {
            for ch in 0..<channels {
                var s: Float = 0
                if let data = abl[ch].mData {
                    s = data.assumingMemoryBound(to: Float.self)[frame]
                }
                scratch[idx] = s
                idx += 1
                let a = abs(s)
                if a > peak { peak = a }
                sumSquares += s * s
            }
        }

        let rms = idx > 0 ? sqrt(sumSquares / Float(idx)) : 0
        peakBits.store(peak.bitPattern, ordering: .relaxed)
        rmsBits.store(rms.bitPattern, ordering: .relaxed)

        if idx > 0 {
            ring.write(scratch.baseAddress!, count: idx)
        }
    }
}
