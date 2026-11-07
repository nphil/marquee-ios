import Foundation
import UIKit

/// Scene thumbnails from a Plex BIF file (`/library/parts/<id>/indexes/sd`): a header, an index of
/// (timestamp, offset) pairs and the JPEG frames they point at.
struct Trickplay: Sendable {
    private struct Frame: Sendable {
        var time: TimeInterval
        var bytes: Range<Int>
    }

    private let data: Data
    private let frames: [Frame]

    private static let magic: [UInt8] = [0x89, 0x42, 0x49, 0x46, 0x0D, 0x0A, 0x1A, 0x0A]
    private static let indexStart = 64

    init?(data: Data) {
        let frames = data.withUnsafeBytes { raw -> [Frame] in
            func word(_ offset: Int) -> UInt32? {
                guard offset >= 0, offset + 4 <= raw.count else { return nil }
                return UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            }
            guard raw.count > Self.indexStart, raw.prefix(8).elementsEqual(Self.magic),
                  let count = word(12), let multiplier = word(16)
            else { return [] }
            // A zero multiplier means timestamps in seconds.
            let unit = TimeInterval(multiplier == 0 ? 1000 : multiplier) / 1000
            var frames: [Frame] = []
            frames.reserveCapacity(Int(min(count, 100_000)))
            for index in 0..<Int(count) {
                let entry = Self.indexStart + index * 8
                // The list ends with a 0xFFFFFFFF timestamp whose offset closes the last frame.
                guard let stamp = word(entry), stamp != .max, let start = word(entry + 4), let end = word(entry + 12) else { break }
                guard end > start, Int(end) <= raw.count else { break }
                frames.append(Frame(time: TimeInterval(stamp) * unit, bytes: Int(start)..<Int(end)))
            }
            return frames
        }
        guard !frames.isEmpty else { return nil }
        self.data = data
        self.frames = frames
    }

    var count: Int { frames.count }

    /// The frame shown at `time`: the last one that starts at or before it.
    func index(at time: TimeInterval) -> Int {
        var low = 0
        var high = frames.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if frames[middle].time <= time { low = middle } else { high = middle - 1 }
        }
        return low
    }

    func image(at index: Int) -> UIImage? {
        guard frames.indices.contains(index) else { return nil }
        let range = frames[index].bytes
        return UIImage(data: data.subdata(in: data.startIndex + range.lowerBound..<data.startIndex + range.upperBound))
    }
}
