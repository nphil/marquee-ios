import Foundation
import LiveEngine

/// A tuner without a network, for screenshots and UI tests: a slate, then a moving station picture with a tone,
/// written into a ring at the pace a tuner sends them until the ring's reader cancels it.
public enum SyntheticTuner {
    public static func feed(_ ring: ByteRing, slateSeconds: Double = 1) {
        let thread = Thread {
            defer { ring.finish() }
            guard let stream = try? SyntheticTS([.slate(seconds: slateSeconds), .station(seconds: 2)]) else { return }
            let started = ContinuousClock.now
            var origin: Double?
            var sent: Int64 = 0
            while !ring.isCancelled {
                // Each segment is spliced onto the next, so one more always waits behind the one going out.
                stream.append([.station(seconds: 2)])
                guard let chunk = try? stream.next() else { return }
                let base = sent
                for mark in chunk.marks where mark.end > sent {
                    let first = origin ?? mark.time
                    origin = first
                    let wait = started + .seconds(mark.time - first) - .now
                    if wait > .zero { Thread.sleep(forTimeInterval: wait / .seconds(1)) }
                    guard !ring.isCancelled else { return }
                    chunk.bytes.withUnsafeBytes { bytes in
                        ring.write(UnsafeRawBufferPointer(rebasing: bytes[Int(sent - base)..<Int(mark.end - base)]))
                    }
                    sent = mark.end
                }
            }
        }
        // As TunerConnection's queue: the pipeline's reader and the main thread wait on the ring's lock.
        thread.qualityOfService = .userInteractive
        thread.start()
    }
}
