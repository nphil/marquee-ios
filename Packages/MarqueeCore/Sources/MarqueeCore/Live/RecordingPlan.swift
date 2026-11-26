import Foundation

/// Whether an airing is the first showing of its episode or a repeat.
public enum AiringFreshness: String, Sendable, Hashable, Codable {
    case new, rerun

    /// The badge text.
    public var badge: String { self == .new ? "NEW" : "RERUN" }
}

extension ScheduledRecording {
    /// NEW when the episode first aired on the day of this airing, RERUN when it aired earlier, nil when Plex
    /// gave no original air date (a movie, or a guide without one). Both days are read in `calendar`, so a phone
    /// far from the broadcast's time zone can see a first showing a day off.
    public func freshness(calendar: Calendar = .current) -> AiringFreshness? {
        guard let first = Self.dayNumber(originallyAvailableAt) else { return nil }
        let airing = calendar.dateComponents([.year, .month, .day], from: start)
        guard let year = airing.year, let month = airing.month, let day = airing.day else { return nil }
        return first >= year * 10_000 + month * 100 + day ? .new : .rerun
    }

    /// "2026-11-26" as 20261126.
    static func dayNumber(_ text: String?) -> Int? {
        guard let text, text.count >= 10 else { return nil }
        let parts = [text.prefix(4), text.dropFirst(5).prefix(2), text.dropFirst(8).prefix(2)].map { Int($0) }
        guard let year = parts[0], let month = parts[1], let day = parts[2] else { return nil }
        return year * 10_000 + month * 100 + day
    }
}

/// How an upcoming airing stands.
public enum UpcomingStatus: String, Sendable, Hashable {
    case scheduled, recording, paused

    public var label: String {
        switch self {
        case .scheduled: "Scheduled"
        case .recording: "Recording now"
        case .paused: "Paused"
        }
    }
}

/// One row of Upcoming.
public struct UpcomingRecording: Identifiable, Hashable, Sendable {
    public var id: String { recording.id }
    public var recording: ScheduledRecording
    public var freshness: AiringFreshness?
    public var status: UpcomingStatus
    /// The conflict this airing is part of, when it overlaps others beyond the tuners.
    public var conflictID: String?
    /// Plex will not record this airing: the recordings that outrank it hold every tuner.
    public var losesToConflict: Bool

    public var isConflict: Bool { conflictID != nil }
}

/// The upcoming airings of one calendar day, by start time.
public struct UpcomingDay: Identifiable, Hashable, Sendable {
    /// "2026-11-26".
    public var id: String
    /// Midnight of the day in the calendar's time zone.
    public var start: Date
    public var items: [UpcomingRecording]
}

/// Airings that ask for more tuners than the DVR has, at the same time.
public struct RecordingConflict: Identifiable, Hashable, Sendable {
    public var id: String
    /// The stretch where the demand is over the tuners.
    public var window: DateInterval
    public var tuners: Int
    /// Every airing in the overlap, the ones Plex records first first.
    public var grabs: [ScheduledRecording]
    /// The airings Plex will not record: the lowest-priority ones the tuners cannot take.
    public var losers: [ScheduledRecording]

    /// "Evening News won't record: Storm Watch has the only tuner then."
    public var sentence: String {
        let loserIDs = Set(losers.map(\.id))
        let winners = grabs.filter { !loserIDs.contains($0.id) }
        let have = Set(winners.map(\.title)).count == 1 ? "has" : "have"
        let tuner = tuners == 1 ? "the only tuner" : "all \(tuners) tuners"
        return "\(Self.names(losers)) won't record: \(Self.names(winners)) \(have) \(tuner) then."
    }

    private static func names(_ grabs: [ScheduledRecording]) -> String {
        var seen = Set<String>()
        let titles = grabs.map(\.title).filter { seen.insert($0).inserted }
        switch titles.count {
        case 0: return "Nothing"
        case 1: return titles[0]
        case 2: return "\(titles[0]) and \(titles[1])"
        default: return titles.dropLast().joined(separator: ", ") + " and " + titles[titles.count - 1]
        }
    }
}

/// What the Recordings screen shows from the DVR's rules and scheduled airings: Upcoming by day, the
/// conflicts, and another airing to switch a conflict to.
public struct RecordingPlan: Sendable {
    public let recordings: LiveRecordings
    /// How many channels the DVR records at once; nil when the DVR is not known, so nothing can conflict.
    public let tuners: Int?
    private let defaultStart: Int
    private let defaultEnd: Int

    public init(_ recordings: LiveRecordings, dvr: LiveDVR?) {
        self.recordings = recordings
        tuners = dvr?.tuners
        defaultStart = dvr?.startOffsetMinutes ?? 0
        defaultEnd = dvr?.endOffsetMinutes ?? 0
    }

    private init(_ recordings: LiveRecordings, like other: RecordingPlan) {
        self.recordings = recordings
        tuners = other.tuners
        defaultStart = other.defaultStart
        defaultEnd = other.defaultEnd
    }

    // MARK: Upcoming

    /// The airings still ahead or recording, by day. A conflicting airing says which conflict it is in.
    public func upcoming(now: Date, calendar: Calendar = .current) -> [UpcomingDay] {
        let found = conflicts(now: now)
        var conflictOf: [String: String] = [:]
        for conflict in found {
            for grab in conflict.grabs { conflictOf[grab.id] = conflict.id }
        }
        let losers = Set(found.flatMap { $0.losers.map(\.id) })
        let rows = recordings.scheduled
            .filter { $0.isUpcoming && $0.end > now }
            .sorted { ($0.start, $0.id) < ($1.start, $1.id) }
            .map { grab in
                UpcomingRecording(
                    recording: grab,
                    freshness: grab.freshness(calendar: calendar),
                    status: grab.status == .inprogress ? .recording : grab.status == .paused ? .paused : .scheduled,
                    conflictID: conflictOf[grab.id],
                    losesToConflict: losers.contains(grab.id)
                )
            }
        var days: [UpcomingDay] = []
        for row in rows {
            let midnight = calendar.startOfDay(for: row.recording.start)
            if let last = days.last, last.start == midnight {
                days[days.count - 1].items.append(row)
            } else {
                days.append(UpcomingDay(id: Self.dayID(midnight, calendar), start: midnight, items: [row]))
            }
        }
        return days
    }

    private static func dayID(_ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let (year, month, day) = (parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        return "\(year)-\(month < 10 ? "0" : "")\(month)-\(day < 10 ? "0" : "")\(day)"
    }

    // MARK: Conflicts

    /// The minutes this airing's rule starts early and ends late, or the DVR's own when the rule names none.
    public func padding(of grab: ScheduledRecording) -> (start: Int, end: Int) {
        let rule = recordings.rule(grab.ruleID)
        func minutes(_ id: String, _ fallback: Int) -> Int {
            max(rule?.setting(id).flatMap { Int($0.value) } ?? fallback, 0)
        }
        return (minutes("startOffsetMinutes", defaultStart), minutes("endOffsetMinutes", defaultEnd))
    }

    private struct Rank: Comparable {
        let tier: Int
        let order: Int
        let start: Date
        let id: String

        static func < (left: Rank, right: Rank) -> Bool {
            (left.tier, left.order, left.start, left.id) < (right.tier, right.order, right.start, right.id)
        }
    }

    private struct Entry {
        let grab: ScheduledRecording
        let start: Date
        let end: Date
        let rank: Rank
    }

    /// Airings whose padded times overlap on more channels than the DVR has tuners. Overlapping airings of one
    /// channel share a tuner, as Plex shares it among viewers of one channel. The airing under way and then the
    /// rules higher in the list keep their tuner; the rest cannot record.
    public func conflicts(now: Date) -> [RecordingConflict] {
        guard let tuners else { return [] }
        let entries = recordings.scheduled.compactMap { grab -> Entry? in
            guard grab.isUpcoming else { return nil }
            let pad = padding(of: grab)
            let start = grab.start.addingTimeInterval(-Double(pad.start) * 60)
            let end = max(grab.end, grab.start).addingTimeInterval(Double(pad.end) * 60)
            guard end > now else { return nil }
            return Entry(grab: grab, start: start, end: end, rank: rank(of: grab))
        }
        guard entries.count > tuners else { return [] }
        let edges = Array(Set(entries.flatMap { [$0.start, $0.end] })).sorted()
        var spans: [(from: Date, to: Date, active: [Entry], losers: [Entry])] = []
        for (from, to) in zip(edges, edges.dropFirst()) {
            let active = entries.filter { $0.start <= from && $0.end >= to }
            guard active.count > tuners else { continue }
            let groups = Dictionary(grouping: active) { $0.grab.channelKey ?? "airing \($0.grab.id)" }.values
                .map { $0.sorted { $0.rank < $1.rank } }
                .sorted { $0[0].rank < $1[0].rank }
            guard groups.count > tuners else { continue }
            spans.append((from, to, active, groups.dropFirst(tuners).flatMap { $0 }))
        }
        var merged: [(from: Date, to: Date, active: [String: Entry], losers: [String: Entry])] = []
        for span in spans {
            let ids = Set(span.active.map(\.grab.id))
            if var last = merged.last, last.to == span.from, !ids.isDisjoint(with: last.active.keys) {
                last.to = span.to
                for entry in span.active { last.active[entry.grab.id] = entry }
                for entry in span.losers { last.losers[entry.grab.id] = entry }
                merged[merged.count - 1] = last
            } else {
                merged.append((
                    span.from, span.to,
                    Dictionary(uniqueKeysWithValues: span.active.map { ($0.grab.id, $0) }),
                    Dictionary(uniqueKeysWithValues: span.losers.map { ($0.grab.id, $0) })
                ))
            }
        }
        return merged.map { conflict in
            let ordered = conflict.active.values.sorted { $0.rank < $1.rank }.map(\.grab)
            return RecordingConflict(
                id: ordered.map(\.id).sorted().joined(separator: "+"),
                window: DateInterval(start: conflict.from, end: conflict.to),
                tuners: tuners,
                grabs: ordered,
                losers: conflict.losers.values.sorted { $0.rank < $1.rank }.map(\.grab)
            )
        }
    }

    private func rank(of grab: ScheduledRecording) -> Rank {
        if grab.status == .inprogress { return Rank(tier: 0, order: 0, start: grab.start, id: grab.id) }
        let index = recordings.rules.firstIndex { $0.id == grab.ruleID }
        return Rank(tier: index == nil ? 2 : 1, order: index ?? 0, start: grab.start, id: grab.id)
    }

    // MARK: Another airing

    /// Other airings of the episode `grab` records, still ahead, that fit the tuners: switching to one frees
    /// the tuner without losing the episode. The earliest first.
    public func alternatives(to grab: ScheduledRecording, in guide: [LiveAiring], now: Date) -> [LiveAiring] {
        let before = Set(conflicts(now: now).flatMap { $0.losers.map(\.id) })
        let candidates = guide.filter { airing in
            airing.start > now && Self.isSameEpisode(airing, as: grab)
                && !(airing.channelKey == grab.channelKey && abs(airing.start.timeIntervalSince(grab.start)) < 60)
                && !recordings.scheduled.contains { $0.isUpcoming && $0.covers(airing) }
        }
        return candidates.filter { airing in
            let probe = ScheduledRecording(
                id: "alternative", ruleID: grab.ruleID, status: .scheduled, channelKey: airing.channelKey,
                title: airing.title, start: airing.start, end: airing.end
            )
            let others = recordings.scheduled.filter { $0.id != grab.id } + [probe]
            let after = Set(
                RecordingPlan(LiveRecordings(rules: recordings.rules, scheduled: others), like: self)
                    .conflicts(now: now).flatMap { $0.losers.map(\.id) }
            )
            return !after.contains("alternative") && after.isSubset(of: before)
        }
        .sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    }

    static func isSameEpisode(_ airing: LiveAiring, as grab: ScheduledRecording) -> Bool {
        if let guid = grab.guid, !guid.isEmpty, !airing.guid.isEmpty { return airing.guid == guid }
        guard airing.title.caseInsensitiveCompare(grab.title) == .orderedSame else { return false }
        if let name = grab.episodeTitle, let other = airing.episodeTitle {
            return name.caseInsensitiveCompare(other) == .orderedSame
        }
        if let code = grab.episodeCode { return code == airing.episodeCode }
        return grab.episodeTitle == nil && airing.episodeTitle == nil
    }
}
