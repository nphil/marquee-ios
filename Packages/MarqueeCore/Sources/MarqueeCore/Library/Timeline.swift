import Foundation

public enum PlaybackState: String, Sendable, Hashable {
    case playing, paused, buffering, stopped
}

/// One `/:/timeline` report: where playback is, so Continue Watching and the server's session list
/// stay current. Plex marks the item watched past about 90 %.
public struct TimelineUpdate: Sendable, Hashable {
    public var ratingKey: String
    public var key: String
    public var state: PlaybackState
    /// Milliseconds.
    public var time: Int
    public var duration: Int
    public var playQueueItemID: Int?
    /// The transcode session, so the server ties the report to it.
    public var sessionIdentifier: String?

    public init(item: PlexMetadata, state: PlaybackState, time: Int, duration: Int, sessionIdentifier: String? = nil) {
        ratingKey = item.ratingKey
        key = item.key.isEmpty ? "/library/metadata/\(item.ratingKey)" : item.key
        self.state = state
        self.time = time
        self.duration = duration
        playQueueItemID = item.playQueueItemID
        self.sessionIdentifier = sessionIdentifier
    }

    var queryItems: [URLQueryItem] {
        var items = [
            URLQueryItem(name: "ratingKey", value: ratingKey),
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "state", value: state.rawValue),
            URLQueryItem(name: "time", value: String(time)),
            URLQueryItem(name: "duration", value: String(duration)),
        ]
        if let playQueueItemID { items.append(URLQueryItem(name: "playQueueItemID", value: String(playQueueItemID))) }
        return items
    }
}

/// When a timeline report is due: on every change of state, and every `interval` while the state holds.
/// A stop is reported once.
public struct TimelineCadence: Sendable {
    public var interval: Duration
    private var lastState: PlaybackState?
    private var lastReport: ContinuousClock.Instant?

    public init(interval: Duration = .seconds(10)) {
        self.interval = interval
    }

    /// Whether to report `state` now; a due report counts as sent.
    public mutating func shouldReport(_ state: PlaybackState, at now: ContinuousClock.Instant) -> Bool {
        if state == .stopped, lastState == .stopped { return false }
        let due = state != lastState || lastReport.map { now - $0 >= interval } ?? true
        if due {
            lastState = state
            lastReport = now
        }
        return due
    }
}

/// Reports one item's playback to the server at the `TimelineCadence`. The player calls `update` on every
/// state change and about once a second; a report that fails is dropped, and the next one is due an
/// interval later.
public actor TimelineReporter {
    private let library: PlexLibrary
    private let item: PlexMetadata
    private let sessionIdentifier: String?
    private var cadence: TimelineCadence

    public init(library: PlexLibrary, item: PlexMetadata, sessionIdentifier: String? = nil, interval: Duration = .seconds(10)) {
        self.library = library
        self.item = item
        self.sessionIdentifier = sessionIdentifier
        cadence = TimelineCadence(interval: interval)
    }

    /// - Parameters:
    ///   - time: Playback position in milliseconds.
    ///   - duration: Item length in milliseconds.
    public func update(_ state: PlaybackState, time: Int, duration: Int) async {
        guard cadence.shouldReport(state, at: .now) else { return }
        let update = TimelineUpdate(item: item, state: state, time: time, duration: duration, sessionIdentifier: sessionIdentifier)
        try? await library.reportTimeline(update)
    }
}
