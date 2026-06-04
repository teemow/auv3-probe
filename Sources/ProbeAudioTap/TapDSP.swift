import Foundation
import AVFoundation
import AudioToolbox
import Atomics
import ProbeKit

// TapDSP holds the realtime state for ProbeAudioTap: a transparent passthrough
// plus a tap that downmixes to mono, decimates, and pushes samples into a
// lock-free ring for the networking thread to drain. Like BrainEngine, it is a
// separate object from the AUAudioUnit so the render closure can capture it
// without a retain cycle.
//
// Realtime discipline: the render block pulls input straight into the output
// buffers (zero-copy passthrough), then computes block peak/RMS and writes
// decimated mono samples into the preallocated ring — no allocation, no locks.
// If the ring is full (the network thread fell behind) the overflow is dropped:
// a stalled tap must never glitch the audio path.

final class TapDSP: @unchecked Sendable {
    /// ~1 second of decimated mono audio at the default decimation keeps latency
    /// low while tolerating network hiccups.
    static let ringCapacity = 48_000

    let ring = RealtimeRing(capacity: ringCapacity)

    /// Keep only every `decimation`-th mono sample (integer downsample). 1 = off.
    /// Atomic because it is set live from the UI stepper / streamer queue while
    /// the render thread reads it; the render snapshots it once per call.
    let decimation = ManagedAtomic<Int>(4)

    /// Whether the tap is actively capturing (set by the UI / config).
    let capturing = ManagedAtomic<Bool>(false)

    // Block features, stored as Float bit patterns so they are atomically
    // readable by the UI / streamer without locking.
    let peakBits = ManagedAtomic<UInt32>(0)
    let rmsBits = ManagedAtomic<UInt32>(0)

    // Render-thread-only carry-over.
    private var decimationPhase = 0
    private var scratch: UnsafeMutableBufferPointer<Float>?

    /// Allocate the per-render mono scratch buffer (called from
    /// allocateRenderResources, off the realtime thread).
    func prepare(maxFrames: Int) {
        scratch?.deallocate()
        let buf = UnsafeMutableBufferPointer<Float>.allocate(capacity: max(1, maxFrames))
        buf.initialize(repeating: 0)
        scratch = buf
        decimationPhase = 0
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

    /// Compute features + push decimated mono samples. Realtime-safe.
    private func tap(_ outputData: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        guard capturing.load(ordering: .relaxed), frameCount > 0, let scratch = scratch else { return }
        let abl = UnsafeMutableAudioBufferListPointer(outputData)
        guard abl.count > 0 else { return }

        let channels = abl.count
        // Snapshot the decimation factor once per render call (it can change live).
        let dec = Swift.max(1, decimation.load(ordering: .relaxed))
        // Treat each buffer as one channel of deinterleaved Float (the standard
        // AUv3 stream format). Guard against unexpected interleaving.
        var monoCount = 0
        var peak: Float = 0
        var sumSquares: Float = 0

        let frames = Swift.min(frameCount, scratch.count * dec + dec)
        var phase = decimationPhase
        for frame in 0..<frameCount where frame < frames {
            var mix: Float = 0
            for ch in 0..<channels {
                if let data = abl[ch].mData {
                    let p = data.assumingMemoryBound(to: Float.self)
                    mix += p[frame]
                }
            }
            mix /= Float(channels)
            let a = abs(mix)
            if a > peak { peak = a }
            sumSquares += mix * mix

            // Integer decimation: keep one in every `decimation` samples.
            if phase == 0 {
                if monoCount < scratch.count {
                    scratch[monoCount] = mix
                    monoCount += 1
                }
            }
            phase += 1
            if phase >= dec { phase = 0 }
        }
        decimationPhase = phase

        let rms = sqrt(sumSquares / Float(frameCount))
        peakBits.store(peak.bitPattern, ordering: .relaxed)
        rmsBits.store(rms.bitPattern, ordering: .relaxed)

        if monoCount > 0 {
            ring.write(scratch.baseAddress!, count: monoCount)
        }
    }
}
