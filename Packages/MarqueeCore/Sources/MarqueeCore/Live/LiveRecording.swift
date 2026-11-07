import Foundation

/// One way to record an airing, from `/media/subscriptions/template`: this episode, the whole show
/// or the movie.
public struct RecordOption: Identifiable, Hashable, Sendable {
    public enum Kind: Int, Sendable {
        case movie = 1, show = 2, episode = 4
    }

    public var id: Int { type }
    /// Plex's metadata type code of what is recorded.
    public var type: Int
    public var kind: Kind? { Kind(rawValue: type) }
    /// Plex's name for it, e.g. "This Episode" or "All Episodes".
    public var title: String
    public var librarySectionTitle: String?
    public var targetLibrarySectionID: Int?
    public var targetSectionLocationID: Int?
    public var settings: [RecordSetting]
    /// The `hints[…]` and `params[…]` the server wants back, percent-encoded.
    var parameters: String

    public init(
        type: Int,
        title: String,
        librarySectionTitle: String? = nil,
        targetLibrarySectionID: Int? = nil,
        targetSectionLocationID: Int? = nil,
        settings: [RecordSetting] = [],
        parameters: String = ""
    ) {
        self.type = type
        self.title = title
        self.librarySectionTitle = librarySectionTitle
        self.targetLibrarySectionID = targetLibrarySectionID
        self.targetSectionLocationID = targetSectionLocationID
        self.settings = settings
        self.parameters = parameters
    }

    public func setting(_ id: String) -> RecordSetting? {
        settings.first { $0.id == id }
    }
}

/// A recording preference: `startOffsetMinutes`, `onlyNewAirings`, `minVideoQuality` and the rest.
public struct RecordSetting: Identifiable, Hashable, Sendable {
    public struct Choice: Hashable, Sendable {
        public var value: String
        public var label: String
    }

    public var id: String
    public var label: String
    /// `int`, `bool` or `text`.
    public var type: String
    public var value: String
    public var isHidden: Bool
    /// From `enumValues` "0:New and Repeat Airings|1:New Airings Only".
    public var choices: [Choice]

    public init(id: String, label: String, type: String, value: String, isHidden: Bool = false, choices: [Choice] = []) {
        self.id = id
        self.label = label
        self.type = type
        self.value = value
        self.isHidden = isHidden
        self.choices = choices
    }

    static func choices(_ text: String?) -> [Choice] {
        guard let text, !text.isEmpty else { return [] }
        return text.split(separator: "|").compactMap { pair -> Choice? in
            let parts = pair.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return Choice(value: String(parts[0]), label: String(parts[1]))
        }
    }
}

/// A recording rule (`MediaSubscription`): one episode, a whole show or a movie.
public struct RecordingRule: Identifiable, Hashable, Sendable {
    public var id: String
    public var type: Int
    /// The show or movie; "This Episode" style names are replaced by what is recorded.
    public var title: String
    /// "New Airings Only" and the like.
    public var airingsType: String?
    public var librarySectionTitle: String?
    /// The library the recordings go into; the Recorded list reads it.
    public var targetLibrarySectionID: Int?
    public var thumb: String?
    public var settings: [RecordSetting]
    /// The airings this rule has scheduled or is recording.
    public var recordings: [ScheduledRecording]

    public init(
        id: String,
        type: Int,
        title: String,
        airingsType: String? = nil,
        librarySectionTitle: String? = nil,
        targetLibrarySectionID: Int? = nil,
        thumb: String? = nil,
        settings: [RecordSetting] = [],
        recordings: [ScheduledRecording] = []
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.airingsType = airingsType
        self.librarySectionTitle = librarySectionTitle
        self.targetLibrarySectionID = targetLibrarySectionID
        self.thumb = thumb
        self.settings = settings
        self.recordings = recordings
    }

    /// A rule for a whole show rather than one airing.
    public var isSeries: Bool { type == RecordOption.Kind.show.rawValue }
}

/// One airing the DVR will record, is recording or has recorded (`MediaGrabOperation`).
public struct ScheduledRecording: Identifiable, Hashable, Sendable {
    public enum Status: String, Sendable {
        case inactive, scheduled, inprogress, complete, cancelled, error, postprocessing, paused, unknown
    }

    /// The grab operation; cancelling one airing deletes it.
    public var id: String
    public var ruleID: String?
    public var status: Status
    public var channelKey: String?
    public var channelNumber: String?
    public var channelCallSign: String?
    public var title: String
    public var episodeTitle: String?
    public var season: Int?
    public var episode: Int?
    public var guid: String?
    public var thumb: String?
    public var start: Date
    public var end: Date

    public init(
        id: String,
        ruleID: String? = nil,
        status: Status,
        channelKey: String? = nil,
        channelNumber: String? = nil,
        channelCallSign: String? = nil,
        title: String,
        episodeTitle: String? = nil,
        season: Int? = nil,
        episode: Int? = nil,
        guid: String? = nil,
        thumb: String? = nil,
        start: Date,
        end: Date
    ) {
        self.id = id
        self.ruleID = ruleID
        self.status = status
        self.channelKey = channelKey
        self.channelNumber = channelNumber
        self.channelCallSign = channelCallSign
        self.title = title
        self.episodeTitle = episodeTitle
        self.season = season
        self.episode = episode
        self.guid = guid
        self.thumb = thumb
        self.start = start
        self.end = end
    }

    /// Still ahead or under way: shown under Scheduled and counted by the recording guard.
    public var isUpcoming: Bool {
        [.inactive, .scheduled, .inprogress, .paused].contains(status)
    }

    public func covers(_ airing: LiveAiring) -> Bool {
        guard let channelKey else { return false }
        return channelKey == airing.channelKey && abs(start.timeIntervalSince(airing.start)) < 60
    }
}

/// How the guide marks an airing (§6.10).
public enum RecordingMark: Sendable, Hashable {
    /// This airing alone will record.
    case scheduled
    /// A series rule will record it.
    case series
    case recording
    case failed
    case recorded
}

/// The DVR's rules and scheduled airings, for record glyphs.
public struct LiveRecordings: Sendable, Hashable {
    public var rules: [RecordingRule]
    public var scheduled: [ScheduledRecording]

    public init(rules: [RecordingRule] = [], scheduled: [ScheduledRecording] = []) {
        self.rules = rules
        self.scheduled = scheduled
    }

    public func mark(for airing: LiveAiring) -> RecordingMark? {
        guard let recording = scheduled.first(where: { $0.covers(airing) && $0.status != .cancelled }) else { return nil }
        switch recording.status {
        case .inprogress, .postprocessing: return .recording
        case .error: return .failed
        case .complete: return .recorded
        case .cancelled: return nil
        case .inactive, .scheduled, .paused, .unknown:
            let rule = rules.first { $0.id == recording.ruleID }
            return rule?.isSeries == true ? .series : .scheduled
        }
    }

    /// The scheduled airing behind `airing`, for cancelling it.
    public func recording(of airing: LiveAiring) -> ScheduledRecording? {
        scheduled.first { $0.covers(airing) && $0.isUpcoming }
    }

    public func rule(_ id: String?) -> RecordingRule? {
        rules.first { $0.id == id }
    }
}
