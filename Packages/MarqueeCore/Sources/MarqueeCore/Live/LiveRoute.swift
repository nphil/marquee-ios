import Foundation

/// How a channel plays: the phone reading the tuner, or a Plex tune.
public enum LiveRoute: Sendable, Hashable {
    case direct(URL)
    case plex(PlexRouteReason)
    /// Copy-protected: neither path can play it.
    case protectedChannel
}

/// Why a channel goes through Plex, in the order the rules are checked.
public enum PlexRouteReason: Sendable, Hashable {
    /// Settings › Video & Playback › Live TV › Direct from Tuner is off.
    case setting
    case awayFromHome
    /// The tuner did not answer `discover.json` in time.
    case tunerUnreachable
    /// The device's grabber is not HDHomeRun-compatible.
    case notHDHomeRun
    case airPlay
    /// The lineup names a codec the phone cannot decode.
    case unsupportedCodec
    /// A Plex recording needs the tuner now or within 2 minutes.
    case recording
}

/// What the route decision looks at besides the channel.
public struct RouteContext: Sendable {
    public var prefersPlex: Bool
    public var isOnHomeNetwork: Bool
    /// `discover.json` answered within 0.5 s (the app caches the answer for 60 s).
    public var tunerReachable: Bool
    public var usesAirPlayVideo: Bool
    /// The tuner's own lineup entry for the channel, when known.
    public var lineup: HDHomeRunChannel?
    public var dvr: LiveDVR?
    public var recordings: [ScheduledRecording]
    public var now: Date

    public init(
        prefersPlex: Bool = false,
        isOnHomeNetwork: Bool,
        tunerReachable: Bool,
        usesAirPlayVideo: Bool = false,
        lineup: HDHomeRunChannel? = nil,
        dvr: LiveDVR? = nil,
        recordings: [ScheduledRecording] = [],
        now: Date = Date()
    ) {
        self.prefersPlex = prefersPlex
        self.isOnHomeNetwork = isOnHomeNetwork
        self.tunerReachable = tunerReachable
        self.usesAirPlayVideo = usesAirPlayVideo
        self.lineup = lineup
        self.dvr = dvr
        self.recordings = recordings
        self.now = now
    }
}

/// Picks Direct or Plex before every tune (`docs/LIVE-TV.md` §2.2). The first matching rule wins.
public struct LiveRouteDecider: Sendable {
    /// A recording starting this soon counts as using the tuner.
    public static let recordingLead: TimeInterval = 120

    public init() {}

    public func route(_ channel: LiveChannel, _ context: RouteContext) -> LiveRoute {
        if context.prefersPlex { return .plex(.setting) }
        if !context.isOnHomeNetwork { return .plex(.awayFromHome) }
        if !context.tunerReachable { return .plex(.tunerUnreachable) }
        if !channel.device.speaksHDHomeRun { return .plex(.notHDHomeRun) }
        if context.usesAirPlayVideo { return .plex(.airPlay) }
        if let lineup = context.lineup, !lineup.phoneDecodes { return .plex(.unsupportedCodec) }
        if context.lineup?.isProtected == true { return .protectedChannel }
        if recordingsNeedTuner(channel, context) { return .plex(.recording) }
        return .direct(channel.device.streamURL(channel))
    }

    /// Recordings that may take this device's tuners now or within `recordingLead`, against the
    /// device's tuner count with the phone's stream added.
    private func recordingsNeedTuner(_ channel: LiveChannel, _ context: RouteContext) -> Bool {
        let device = channel.device
        let horizon = context.now.addingTimeInterval(Self.recordingLead)
        let busy = context.recordings.filter { recording in
            guard recording.isUpcoming, recording.start <= horizon, recording.end > context.now else { return false }
            guard let key = recording.channelKey, let dvr = context.dvr else { return true }
            return dvr.device(device, carries: key)
        }
        return device.tunerCount < busy.count + 1
    }
}
