import Foundation

/// The channels in lineup order and each channel's airings by start time, for the span loaded so far.
/// A value: the app replaces it as wider spans arrive.
public struct LiveGuide: Sendable, Equatable, Codable {
    public private(set) var channels: [LiveChannel]
    /// Per channel key, sorted by start, without overlaps.
    public private(set) var airings: [String: [LiveAiring]]
    /// The loaded span.
    public private(set) var from: Date
    public private(set) var to: Date

    public init(channels: [LiveChannel], airings: [LiveAiring], from: Date, to: Date) {
        self.channels = channels
        self.airings = Self.byChannel(airings)
        self.from = from
        self.to = to
    }

    public static let empty = LiveGuide(channels: [], airings: [], from: .distantPast, to: .distantPast)

    public var isEmpty: Bool { channels.isEmpty }

    public func channel(_ key: String) -> LiveChannel? {
        channels.first { $0.id == key }
    }

    /// The airing on `channelKey` at `date`.
    public func airing(on channelKey: String, at date: Date) -> LiveAiring? {
        guard let list = airings[channelKey] else { return nil }
        let index = Self.firstEnding(after: date, in: list)
        guard index < list.count, list[index].start <= date else { return nil }
        return list[index]
    }

    /// The first airing on `channelKey` that starts at or after `date`.
    public func next(on channelKey: String, after date: Date) -> LiveAiring? {
        guard let list = airings[channelKey] else { return nil }
        let index = Self.firstEnding(after: date, in: list)
        return list[index...].first { $0.start >= date }
    }

    /// The airing at `date` and the one after it.
    public func nowAndNext(on channelKey: String, at date: Date) -> (now: LiveAiring?, next: LiveAiring?) {
        let now = airing(on: channelKey, at: date)
        return (now, next(on: channelKey, after: now?.end ?? date))
    }

    /// Airings on `channelKey` that overlap `from`…`to`.
    public func airings(on channelKey: String, from: Date, to: Date) -> ArraySlice<LiveAiring> {
        guard let list = airings[channelKey] else { return [] }
        let first = Self.firstEnding(after: from, in: list)
        var last = first
        while last < list.count, list[last].start < to { last += 1 }
        return list[first..<last]
    }

    /// This guide with `airings` loaded for `from`…`to`: within that span they replace what was there.
    public func merging(_ newAirings: [LiveAiring], from: Date, to: Date, channels newChannels: [LiveChannel]? = nil) -> LiveGuide {
        var kept: [LiveAiring] = []
        for list in airings.values {
            kept += list.filter { $0.end <= from || $0.start >= to }
        }
        var guide = LiveGuide(
            channels: newChannels ?? channels,
            airings: kept + newAirings,
            from: isEmpty ? from : min(self.from, from),
            to: isEmpty ? to : max(self.to, to)
        )
        if newChannels != nil {
            let keys = Set(guide.channels.map(\.id))
            guide.airings = guide.airings.filter { keys.contains($0.key) }
        }
        return guide
    }

    /// Without airings that ended before `date`.
    public func trimmed(before date: Date) -> LiveGuide {
        var guide = self
        guide.airings = airings.mapValues { list in list.filter { $0.end > date } }
        guide.from = max(from, date)
        return guide
    }

    /// Airings grouped by channel, sorted, with duplicates and overlaps resolved toward the later start.
    private static func byChannel(_ airings: [LiveAiring]) -> [String: [LiveAiring]] {
        var grouped: [String: [LiveAiring]] = [:]
        for airing in airings { grouped[airing.channelKey, default: []].append(airing) }
        return grouped.mapValues { list in
            var result: [LiveAiring] = []
            for airing in list.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
                if let last = result.last, last.id == airing.id || (last.start == airing.start) {
                    result[result.count - 1] = airing
                } else if let last = result.last, last.end > airing.start {
                    // Guides overlap at the edges of a refresh; the later airing wins its start.
                    var cut = last
                    cut.end = airing.start
                    result[result.count - 1] = cut
                    result.append(airing)
                } else {
                    result.append(airing)
                }
            }
            return result
        }
    }

    /// Index of the first airing in `list` that ends after `date`.
    private static func firstEnding(after date: Date, in list: [LiveAiring]) -> Int {
        var low = 0, high = list.count
        while low < high {
            let mid = (low + high) / 2
            if list[mid].end <= date { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

/// The last guide of each DVR on disk, so the tab draws at once and works with the server away.
public actor GuideCache {
    /// How far back the guide keeps ended airings (the grid shows up to 2 h back).
    public static let history: TimeInterval = 2 * 60 * 60

    private let directory: URL
    private let now: @Sendable () -> Date

    public init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
    }

    /// The saved guide re-anchored to now: airings that ended more than `history` ago are dropped.
    /// Nil when nothing was saved or nothing in it reaches now.
    public func load(server: String, dvr: String) -> LiveGuide? {
        guard let data = try? Data(contentsOf: file(server: server, dvr: dvr)),
              let guide = try? JSONDecoder().decode(LiveGuide.self, from: data) else { return nil }
        let now = now()
        guard guide.to > now else { return nil }
        return guide.trimmed(before: now.addingTimeInterval(-Self.history))
    }

    public func save(_ guide: LiveGuide, server: String, dvr: String) {
        guard let data = try? JSONEncoder().encode(guide) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file(server: server, dvr: dvr), options: .atomic)
    }

    private func file(server: String, dvr: String) -> URL {
        let name = "\(server)-\(dvr)".map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        return directory.appendingPathComponent(String(name) + ".json")
    }
}
