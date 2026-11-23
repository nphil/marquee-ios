import Foundation

/// A title's chapters as the player's progress bar shows them: a cut at each chapter start, and the name of
/// the chapter under the thumb while scrubbing. A title with fewer than two chapters has none of it.
public struct ChapterMarks: Sendable, Equatable {
    /// Cuts closer than this share of the title to each other or to either end are left out: they would
    /// draw as a sliver.
    public static let minimumGap = 0.0005

    /// Chapters in playback order, one per start.
    private let starts: [Int]
    private let names: [String]
    private let length: TimeInterval

    public init(_ chapters: [PlexChapter], duration: TimeInterval) {
        length = duration.isFinite ? max(0, duration) : 0
        var seen: Set<Int> = []
        let ordered = chapters
            .filter { $0.start >= 0 && seen.insert($0.start).inserted }
            .sorted { $0.start < $1.start }
        guard ordered.count >= 2 else {
            starts = []
            names = []
            return
        }
        starts = ordered.map(\.start)
        names = ordered.enumerated().map { position, chapter in
            let title = chapter.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return title.isEmpty ? "Chapter \(position + 1)" : title
        }
    }

    /// Whether the title has chapters to show.
    public var isShown: Bool { !starts.isEmpty }

    /// Where each chapter after the first starts, as a share of the title, ascending.
    public var cutFractions: [Double] {
        guard length > 0 else { return [] }
        var cuts: [Double] = []
        for start in starts.dropFirst() {
            let fraction = Double(start) / 1000 / length
            guard fraction > Self.minimumGap, fraction < 1 - Self.minimumGap else { continue }
            if let last = cuts.last, fraction - last < Self.minimumGap { continue }
            cuts.append(fraction)
        }
        return cuts
    }

    /// The chapter `time` (seconds) falls in; the first for a time before it.
    private func position(at time: TimeInterval) -> Int? {
        guard isShown, time.isFinite else { return nil }
        let milliseconds = Int(max(0, time) * 1000)
        return starts.lastIndex { $0 <= milliseconds } ?? 0
    }

    /// The chapter's title, or "Chapter N" when it has none; nil for a title without chapters.
    public func name(at time: TimeInterval) -> String? {
        position(at: time).map { names[$0] }
    }

    /// Whether moving the playhead from `from` to `to` passes a chapter start.
    public func crossesStart(from: TimeInterval, to: TimeInterval) -> Bool {
        guard let before = position(at: from), let after = position(at: to) else { return false }
        return before != after
    }
}
