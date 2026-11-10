import Foundation
import Testing
@testable import LiveEngine

/// Each write is one TS packet of a single value, so what a reader gets reads back as those values.
final class TimeshiftBufferTests {
    private let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private let clock = TestClock()

    deinit { try? FileManager.default.removeItem(at: temporary) }

    private var folder: URL { temporary.appendingPathComponent("buffer") }

    /// Two packets to a segment, so the reads cross segment files.
    private func buffer(
        limits: TimeshiftBuffer.Limits = TimeshiftBuffer.Limits(bytes: 1 << 20, seconds: 3600), onDisk: Bool = true
    ) -> TimeshiftBuffer {
        TimeshiftBuffer(folder: onDisk ? folder : nil, limits: limits, segmentBytes: 2 * 188) { [clock] in clock.now }
    }

    private func write(_ values: ClosedRange<UInt8>, to buffer: TimeshiftBuffer) {
        for value in values {
            clock.now = Double(value)
            buffer.write(Data(repeating: value, count: 188))
        }
    }

    /// The packets due now, and what the reader says after them.
    private func due(_ reader: TimeshiftReader) -> (packets: [UInt8], then: TimeshiftReader.Poll) {
        var bytes: [UInt8] = []
        var target = [UInt8](repeating: 0, count: 4096)
        while true {
            let poll = target.withUnsafeMutableBytes { reader.poll(into: $0) }
            guard case .bytes(let count) = poll else {
                return (stride(from: 0, to: bytes.count, by: 188).map { bytes[$0] }, poll)
            }
            bytes += target.prefix(count)
        }
    }

    @Test func pauseHoldsTheBytesAndResumesFromTheSameOne() {
        let buffer = buffer()
        let reader = buffer.reader(delay: 0, preroll: 0)
        write(0...0, to: buffer)
        #expect(due(reader) == ([0], .wait(until: nil)))
        clock.now = 1
        reader.setPaused(true)
        write(1...3, to: buffer)
        #expect(due(reader) == ([], .wait(until: nil)))
        clock.now = 4
        reader.setPaused(false)
        #expect(reader.delay == 3)
        // Each packet comes the pause's length after it arrived.
        #expect(due(reader) == ([1], .wait(until: 5)))
        clock.now = 5
        #expect(due(reader) == ([2], .wait(until: 6)))
    }

    @Test func goingBackStartsWithThePrerollAtOnceThenKeepsThePace() {
        let buffer = buffer()
        write(0...9, to: buffer)
        clock.now = 10
        let reader = buffer.reader(delay: 5, preroll: 1)
        #expect(reader.delay == 5)
        #expect(due(reader) == ([4, 5], .wait(until: 11)))
        clock.now = 11
        #expect(due(reader) == ([6], .wait(until: 12)))
    }

    @Test func goingLiveStartsAtTheNewestBytes() {
        let buffer = buffer()
        write(0...9, to: buffer)
        clock.now = 10
        let reader = buffer.reader(delay: 0, preroll: 1)
        #expect(reader.delay == 0)
        #expect(due(reader) == ([9], .wait(until: nil)))
    }

    @Test func theByteCapDeletesTheOldestSegment() throws {
        let buffer = buffer(limits: TimeshiftBuffer.Limits(bytes: 4 * 188, seconds: 3600))
        write(0...5, to: buffer)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(files == ["376.ts", "752.ts"])
        #expect(due(buffer.reader(delay: 60, preroll: 0)).packets.first == 2)
    }

    @Test func theTimeCapDropsWhatCameEarlier() {
        let buffer = buffer(limits: TimeshiftBuffer.Limits(bytes: 1 << 20, seconds: 3), onDisk: false)
        write(0...5, to: buffer)
        #expect(due(buffer.reader(delay: 60, preroll: 0)).packets.first == 2)
    }

    @Test func aPauseLongerThanTheBufferPlaysOnFromTheFarthestPointKept() {
        let buffer = buffer(limits: TimeshiftBuffer.Limits(bytes: 20 * 188, seconds: 3600))
        let reader = buffer.reader(delay: 0, preroll: 0)
        write(0...0, to: buffer)
        #expect(due(reader).packets == [0])
        reader.setPaused(true)
        write(1...39, to: buffer)
        // The next evictions keep from packet 22, 17 s back; less the margin, 12 s.
        #expect(buffer.reach == 12)
        reader.setPaused(false)
        #expect(due(reader) == ([27], .wait(until: 40)))
        #expect(reader.delay == 12)
    }

    @Test func discardDeletesTheFolderAndCancelsAWaitingRead() async {
        let buffer = buffer()
        let reader = buffer.reader(delay: 0, preroll: 0)
        write(0...0, to: buffer)
        #expect(due(reader).packets == [0])
        let read = Task.detached {
            var target = [UInt8](repeating: 0, count: 188)
            return target.withUnsafeMutableBytes { reader.read(into: $0) }
        }
        buffer.discard()
        #expect(await read.value == .cancelled)
        #expect(buffer.isDiscarded)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func leftoversOfAnEarlierRunAreDeletedAndNewBuffersKept() throws {
        let root = TimeshiftBuffer.root(in: temporary)
        let leftover = root.appendingPathComponent("earlier")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data([0]).write(to: leftover.appendingPathComponent("0.ts"))
        let queue = DispatchQueue(label: "leftovers")
        queue.suspend()
        TimeshiftBuffer.removeLeftovers(in: temporary, on: queue)
        // Made after the folders were listed, before they are deleted.
        let current = root.appendingPathComponent("current")
        _ = TimeshiftBuffer(folder: current, limits: .inMemory)
        queue.resume()
        queue.sync {}
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(FileManager.default.fileExists(atPath: current.path))
    }

    @Test func aFolderThatCannotBeMadeKeepsTheBytesInMemory() throws {
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        try Data().write(to: folder)
        let buffer = TimeshiftBuffer(
            folder: folder.appendingPathComponent("under a file"), limits: .inMemory, segmentBytes: 2 * 188
        ) { [clock] in clock.now }
        #expect(!buffer.isOnDisk)
        let reader = buffer.reader(delay: 0, preroll: 0)
        write(0...2, to: buffer)
        #expect(due(reader).packets == [0, 1, 2])
    }
}
