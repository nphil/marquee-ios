import Foundation
import Libavutil

/// Where the engine's pictures and sound go, and the clock they play against: on the phone, sample-buffer renderers
/// on one synchronizer; in tests, a recorder with a hand-driven clock. Times are seconds on the stream's 90 kHz clock.
/// Called from the engine's threads, one call at a time per pipeline.
public protocol LiveOutput: AnyObject, Sendable {
    /// The presentation clock.
    var time: Double { get }
    /// Sets the rate and, when `time` is given, moves the clock there first.
    func setRate(_ rate: Double, time: Double?)
    /// A picture, NV12 or VideoToolbox-backed, borrowed for the call. `immediately` shows it now whatever the clock.
    func enqueueVideo(_ frame: UnsafeMutablePointer<AVFrame>, time: Double, immediately: Bool)
    /// Interleaved stereo Float32 at 48 kHz, borrowed for the call.
    func enqueueAudio(_ samples: UnsafeBufferPointer<Float>, time: Double)
    /// Drops everything queued. With `keepingImage` the picture on screen stays.
    func flush(keepingImage: Bool)
}

/// Passes calls to an output until closed; after `close()` returns, no call from the pipeline it was given to reaches
/// the output, so a replaced channel cannot draw over its successor.
public final class OutputGate: LiveOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var target: (any LiveOutput)?

    public init(_ output: any LiveOutput) {
        target = output
    }

    public func close() {
        lock.withLock { target = nil }
    }

    public var time: Double {
        lock.withLock { target?.time } ?? 0
    }

    public func setRate(_ rate: Double, time: Double?) {
        lock.withLock { target?.setRate(rate, time: time) }
    }

    public func enqueueVideo(_ frame: UnsafeMutablePointer<AVFrame>, time: Double, immediately: Bool) {
        lock.withLock { target?.enqueueVideo(frame, time: time, immediately: immediately) }
    }

    public func enqueueAudio(_ samples: UnsafeBufferPointer<Float>, time: Double) {
        lock.withLock { target?.enqueueAudio(samples, time: time) }
    }

    public func flush(keepingImage: Bool) {
        lock.withLock { target?.flush(keepingImage: keepingImage) }
    }
}
