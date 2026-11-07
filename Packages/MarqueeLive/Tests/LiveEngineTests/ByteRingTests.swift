import Foundation
import Testing
@testable import LiveEngine

struct ByteRingTests {
    private func readAll(_ ring: ByteRing) -> [UInt8] {
        var out: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 5)
        while case .bytes(let count) = buffer.withUnsafeMutableBytes({ ring.read(into: $0) }) {
            out += buffer.prefix(count)
        }
        return out
    }

    @Test func wrapsAroundAndEnds() {
        let ring = ByteRing(capacity: 8)
        ring.write(Data([1, 2, 3, 4, 5, 6]))
        var buffer = [UInt8](repeating: 0, count: 4)
        #expect(buffer.withUnsafeMutableBytes { ring.read(into: $0) } == .bytes(4))
        ring.write(Data([7, 8, 9, 10, 11]))
        ring.finish()
        #expect(readAll(ring) == [5, 6, 7, 8, 9, 10, 11])
        #expect(ring.counts == ByteRing.Counts(written: 11, buffered: 0, dropped: 0))
    }

    @Test func overflowDropsTheOldestBytes() {
        let ring = ByteRing(capacity: 4)
        ring.write(Data([1, 2, 3]))
        ring.write(Data([4, 5, 6]))
        ring.write(Data([7, 8, 9, 10, 11, 12]))
        ring.finish()
        #expect(readAll(ring) == [9, 10, 11, 12])
        #expect(ring.counts.dropped == 8)
    }

    @Test func cancelWakesABlockedReader() async {
        let ring = ByteRing(capacity: 16)
        let reader = Task.detached {
            var buffer = [UInt8](repeating: 0, count: 4)
            return buffer.withUnsafeMutableBytes { ring.read(into: $0) }
        }
        try? await Task.sleep(for: .milliseconds(10))
        ring.cancel()
        #expect(await reader.value == .cancelled)
    }
}
