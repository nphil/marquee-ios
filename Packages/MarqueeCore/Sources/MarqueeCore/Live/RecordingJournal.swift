import Foundation

/// How a recording that did not happen ended.
public enum RecordingOutcome: String, Sendable, Hashable, Codable {
    case failed, skipped, missed, stopped

    public var label: String {
        switch self {
        case .failed: "Failed"
        case .skipped: "Skipped"
        case .missed: "Missed"
        case .stopped: "Stopped early"
        }
    }
}

/// One airing that was not recorded, with the reason in plain words: a row of History.
public struct HistoryEntry: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var outcome: RecordingOutcome
    public var title: String
    public var episodeTitle: String?
    public var episodeCode: String?
    /// "7.1 WABC".
    public var channel: String?
    /// When the airing was due to start.
    public var airedAt: Date
    /// When the app found out.
    public var noted: Date
    public var reason: String
}

/// A recording that started, finished or failed, ready for a notification.
public struct RecordingEvent: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable {
        case started, finished, failed
    }

    /// Stable for one airing and kind, so a notification is posted once.
    public var id: String
    public var kind: Kind
    public var title: String
    public var body: String
    public var recording: ScheduledRecording
}

/// What the DVR was seen doing, kept between looks so that a change can be told from a state: a recording
/// that began, ended, failed or vanished since the last look. The app saves `encoded()` and reads it back.
/// Plex lists no record of finished or failed airings, so History comes from what this journal saw.
public struct RecordingJournal: Sendable, Hashable, Codable {
    /// The airings on the last look that are ahead, under way or recently over.
    public private(set) var seen: [ScheduledRecording] = []
    /// The airings the last look saw lose a tuner conflict.
    private var losers: [String] = []
    public private(set) var history: [HistoryEntry] = []
    public private(set) var checkedAt: Date?

    public init() {}

    static let keptHistory = 50
    static let historyDays: TimeInterval = 30 * 86_400
    static let keptSeenDays: TimeInterval = 2 * 86_400
    /// A grab can leave the list a little before its end when the server closes it early.
    static let endSlack: TimeInterval = 120

    public static func decoded(_ data: Data?) -> RecordingJournal {
        data.flatMap { try? JSONDecoder().decode(RecordingJournal.self, from: $0) } ?? RecordingJournal()
    }

    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    // MARK: Looking

    /// Compares the DVR now with the last look and returns what changed. The first look reports nothing, since
    /// an airing already recording was not seen to start.
    public mutating func observe(_ recordings: LiveRecordings, dvr: LiveDVR?, now: Date) -> [RecordingEvent] {
        let isFirst = checkedAt == nil
        let plan = RecordingPlan(recordings, dvr: dvr)
        let nowLosing = Set(plan.conflicts(now: now).flatMap { $0.losers.map(\.id) })
        let before = Dictionary(seen.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        let current = Dictionary(recordings.scheduled.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        let tunerDown = dvr.map { !$0.devices.isEmpty && $0.devices.allSatisfy { !$0.isAlive } } ?? false
        var events: [RecordingEvent] = []

        for grab in recordings.scheduled {
            let was = before[grab.id]?.status
            switch grab.status {
            case .inprogress where was != .inprogress && !isFirst:
                events.append(Self.event(.started, grab, "Recording started", Self.line(grab)))
            case .complete where was != .complete && !isFirst:
                events.append(Self.event(.finished, grab, "Recording finished", Self.line(grab)))
            case .error where was != .error:
                let reason = Self.failureReason(losing: losers.contains(grab.id) || nowLosing.contains(grab.id), tunerDown: tunerDown)
                add(.failed, grab, reason, now)
                if !isFirst { events.append(Self.event(.failed, grab, "Recording failed", "\(Self.line(grab)). \(reason)")) }
            default: break
            }
        }

        for old in seen where current[old.id] == nil {
            switch old.status {
            case .inprogress, .postprocessing:
                if now >= old.end.addingTimeInterval(-Self.endSlack) {
                    events.append(Self.event(.finished, old, "Recording finished", Self.line(old)))
                } else {
                    let reason = "Plex stopped it before the end: the rule was changed or deleted, or the tuner was lost."
                    add(.stopped, old, reason, now)
                    events.append(Self.event(.failed, old, "Recording stopped early", "\(Self.line(old)). \(reason)"))
                }
            case .scheduled, .inactive, .paused:
                let lost = losers.contains(old.id)
                if now < old.start {
                    add(.skipped, old, lost
                        ? "Another recording was using the only tuner at that time."
                        : "The airing was skipped, or its rule was changed or deleted.", now)
                } else if now < old.end.addingTimeInterval(-Self.endSlack) {
                    add(.missed, old, lost
                        ? "Another recording was using the only tuner, so this one never started."
                        : "Plex didn't start this recording.", now)
                }
            default: break
            }
        }

        let cutoff = now.addingTimeInterval(-Self.keptSeenDays)
        seen = recordings.scheduled.filter { $0.end > cutoff }
        losers = Array(nowLosing)
        checkedAt = now
        history = history.filter { $0.noted > now.addingTimeInterval(-Self.historyDays) }
            .sorted { $0.noted > $1.noted }
            .prefix(Self.keptHistory).map { $0 }
        return events
    }

    /// Records that the user skipped or stopped `grab`, so the next look does not report it as lost.
    public mutating func noteSkipped(_ grab: ScheduledRecording, at now: Date) {
        seen.removeAll { $0.id == grab.id }
        add(grab.status == .inprogress ? .stopped : .skipped, grab,
            grab.status == .inprogress ? "You stopped this recording." : "You skipped this airing.", now)
    }

    private mutating func add(_ outcome: RecordingOutcome, _ grab: ScheduledRecording, _ reason: String, _ now: Date) {
        let id = "\(grab.id).\(outcome.rawValue)"
        guard !history.contains(where: { $0.id == id }) else { return }
        history.insert(
            HistoryEntry(
                id: id, outcome: outcome, title: grab.title, episodeTitle: grab.episodeTitle, episodeCode: grab.episodeCode,
                channel: Self.channel(grab), airedAt: grab.start, noted: now, reason: reason
            ),
            at: 0
        )
    }

    // MARK: Words

    static func failureReason(losing: Bool, tunerDown: Bool) -> String {
        if losing { return "Another recording was using the only tuner." }
        if tunerDown { return "The tuner wasn't responding." }
        return "Plex couldn't record this airing."
    }

    static func channel(_ grab: ScheduledRecording) -> String? {
        let text = [grab.channelNumber, grab.channelCallSign].compactMap { $0 }.joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    /// "Jimmy Kimmel Live! · 7.1 WABC".
    static func line(_ grab: ScheduledRecording) -> String {
        [grab.title, channel(grab)].compactMap { $0 }.joined(separator: " · ")
    }

    private static func event(_ kind: RecordingEvent.Kind, _ grab: ScheduledRecording, _ title: String, _ body: String) -> RecordingEvent {
        RecordingEvent(id: "\(grab.id).\(kind.rawValue)", kind: kind, title: title, body: body, recording: grab)
    }

    // MARK: History

    /// The journal's History and the one-off rules that cannot record what the guide shows soon. Newest first.
    public func entries(recordings: LiveRecordings, guide: [LiveAiring], now: Date) -> [HistoryEntry] {
        (history + Self.mismatches(recordings, guide: guide, now: now)).sorted { $0.noted > $1.noted }
    }

    /// A rule for one episode names that episode only. When the guide shows a first airing of the same show in
    /// the next day and a half that is not that episode, nothing records it: this says so, so a Record tap on
    /// tonight's show that scheduled another night's rerun does not go unexplained.
    static func mismatches(_ recordings: LiveRecordings, guide: [LiveAiring], now: Date) -> [HistoryEntry] {
        let horizon = now.addingTimeInterval(36 * 3_600)
        var found: [HistoryEntry] = []
        for rule in recordings.rules where rule.type == RecordOption.Kind.episode.rawValue {
            guard let grab = recordings.scheduled.first(where: { $0.ruleID == rule.id && $0.isUpcoming && $0.end > now }) else { continue }
            let candidate = guide.first { airing in
                airing.start > now && airing.start < horizon && airing.isNew
                    && airing.title.caseInsensitiveCompare(grab.title) == .orderedSame
                    && !RecordingPlan.isSameEpisode(airing, as: grab)
                    && !recordings.scheduled.contains { $0.isUpcoming && $0.covers(airing) }
            }
            guard let candidate else { continue }
            let wanted = grab.episodeTitle.map { "“\($0)”" } ?? grab.episodeCode ?? "one episode"
            found.append(HistoryEntry(
                id: "mismatch.\(rule.id).\(candidate.id)", outcome: .skipped, title: candidate.title,
                episodeTitle: candidate.episodeTitle, episodeCode: candidate.episodeCode, channel: nil,
                airedAt: candidate.start, noted: now,
                reason: "This rule only records \(wanted). This airing is a different episode, so it isn't recorded. "
                    + "Edit the rule and choose New Episodes to record it."
            ))
        }
        return found
    }
}
