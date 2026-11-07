import Foundation

/// Live TV and DVR of one server, through the library's chosen address and token. The endpoints and
/// identifiers are described in `docs/LIVE-TV.md` §1.
public struct PlexLiveTV: Sendable {
    public let library: PlexLibrary

    public init(library: PlexLibrary) {
        self.library = library
    }

    // MARK: Lineup and guide

    public func dvrs() async throws -> [LiveDVR] {
        try await get(WireDVRList.self, "/livetv/dvrs").dvrs
    }

    /// The lineup's channels that a device has enabled, in channel-number order.
    public func channels(_ dvr: LiveDVR) async throws -> [LiveChannel] {
        let lineup = try await get(WireChannelList.self, "/\(dvr.epgIdentifier)/lineups/dvr/channels").channels
        return Self.join(lineup, dvr)
    }

    /// Joins lineup channels to the devices' mappings by channel key. A channel no device has enabled
    /// is left out; the device's own number wins over the lineup's.
    static func join(_ lineup: [WireChannel], _ dvr: LiveDVR) -> [LiveChannel] {
        var seen = Set<String>()
        return lineup.compactMap { channel -> LiveChannel? in
            guard seen.insert(channel.key).inserted, let receiver = dvr.receiver(of: channel.key) else { return nil }
            return LiveChannel(
                id: channel.key,
                dvrKey: dvr.key,
                number: receiver.mapping.number.isEmpty ? channel.number ?? "" : receiver.mapping.number,
                callSign: channel.callSign,
                title: channel.title,
                logo: channel.logo,
                isHD: channel.isHD,
                device: receiver.device
            )
        }
        .sorted(by: LiveChannel.numberOrder)
    }

    /// The provider's channel genres (News, Sports, Movies…), for the guide's filter chips.
    public func channelFilters(_ dvr: LiveDVR) async throws -> [LiveChannelFilter] {
        try await get(WireProviders.self, "/media/providers").filters(for: dvr.epgIdentifier)
    }

    /// The keys of the channels in one genre.
    public func channelKeys(in filter: LiveChannelFilter) async throws -> Set<String> {
        let (path, query) = PlexLibrary.split(filter.key)
        let channels = try await get(WireChannelList.self, path, query).channels
        return Set(channels.map(\.key))
    }

    /// Airings on `channels` that overlap `from`…`to`, by start time. Programmes on channels the
    /// devices do not map (simulcasts in the provider's lineup) are dropped.
    public func guide(_ dvr: LiveDVR, channels: [LiveChannel], from: Date, to: Date) async throws -> [LiveAiring] {
        let query = [
            URLQueryItem(name: "type", value: "1,4"),
            URLQueryItem(name: "sort", value: "beginsAt"),
            // Plex filter operators: `endsAt>=T0` is the name `endsAt>` with the value T0.
            URLQueryItem(name: "endsAt>", value: String(Int(from.timeIntervalSince1970))),
            URLQueryItem(name: "beginsAt<", value: String(Int(to.timeIntervalSince1970))),
        ]
        let airings = try await get(WireGrid.self, "/\(dvr.epgIdentifier)/grid", query).airings
        let keys = Set(channels.map(\.id))
        return airings.filter { keys.contains($0.channelKey) }.sorted { $0.start < $1.start }
    }

    // MARK: Playback

    /// Asks the server to tune `channel`. The server holds one of the device's tuners until the stream
    /// stops.
    public func tune(_ channel: LiveChannel) async throws -> PlexLiveSession {
        let path = "/livetv/dvrs/\(channel.dvrKey)/channels/\(PlexURL.encode(channel.id))/tune"
        let response = try await library.send(.post, path, [], headers: [:])
        let tune = try PlexJSON.decode(LiveEnvelope<WireTune>.self, from: response.body).container
        guard let uuid = tune.uuid else { throw PlexError.decoding("tune without a session") }
        return PlexLiveSession(
            id: uuid,
            channel: channel,
            ratingKey: tune.ratingKey ?? "",
            videoCodec: tune.videoCodec,
            videoHeight: tune.videoHeight,
            isInterlaced: tune.isInterlaced,
            audioCodec: tune.audioCodec,
            audioChannels: tune.audioChannels
        )
    }

    /// The HLS URL of a tuned session. The transcode decision is asked first, as Plex's own app does,
    /// so a refusal arrives as an error rather than as a playlist that never loads.
    public func streamURL(_ request: TranscodeRequest) async throws -> URL {
        let location = try await library.connection.connection().isLocal ? "lan" : "wan"
        _ = try await library.send(.get, "/video/:/transcode/universal/decision", request.queryItems(location: location), headers: [:])
        return try await library.transcodeURL(request)
    }

    public func reportTimeline(_ update: LiveTimelineUpdate) async throws {
        let headers = [PlexHeader.sessionIdentifier: update.transcodeSession]
        _ = try await library.send(.get, "/:/timeline", update.queryItems, headers: headers, idempotent: false)
    }

    /// Ends the server's stream, which lets go of the tuner.
    public func stopStream(transcodeSession: String) async throws {
        try await library.stopTranscode(session: transcodeSession)
    }

    // MARK: Recording

    /// The ways to record `airing`: this episode, the whole show, the movie. A user who may not
    /// record gets 401 or 403 (`PlexError`).
    public func recordOptions(_ airing: LiveAiring) async throws -> [RecordOption] {
        try await get(WireTemplates.self, "/media/subscriptions/template", [URLQueryItem(name: "guid", value: airing.guid)]).options
    }

    /// Creates the rule `option` describes. `values` override its settings by id, e.g.
    /// `["startOffsetMinutes": "2", "onlyNewAirings": "1"]`.
    @discardableResult
    public func record(_ option: RecordOption, values: [String: String] = [:]) async throws -> RecordingRule? {
        var query = [URLQueryItem(name: "type", value: String(option.type))]
        if let section = option.targetLibrarySectionID {
            query.append(URLQueryItem(name: "targetLibrarySectionID", value: String(section)))
        }
        if let location = option.targetSectionLocationID {
            query.append(URLQueryItem(name: "targetSectionLocationID", value: String(location)))
        }
        query += Self.queryItems(decoding: option.parameters)
        query += Self.prefs(option.settings, values)
        let response = try await library.send(.post, "/media/subscriptions", query, headers: [:])
        return try PlexJSON.decode(LiveEnvelope<WireSubscriptions>.self, from: response.body).container.rules.first
    }

    /// Changes a rule's settings.
    public func update(_ rule: RecordingRule, values: [String: String]) async throws {
        let prefs = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: "prefs[\($0.key)]", value: $0.value) }
        _ = try await library.send(.put, "/media/subscriptions/\(PlexURL.encode(rule.id))", prefs, headers: [:])
    }

    /// The DVR's rules, each with the airings it has scheduled.
    public func rules() async throws -> [RecordingRule] {
        try await get(WireSubscriptions.self, "/media/subscriptions", [URLQueryItem(name: "includeGrabs", value: "1")]).rules
    }

    /// Every airing due to record or recording now.
    public func scheduled() async throws -> [ScheduledRecording] {
        try await get(WireGrabList.self, "/media/subscriptions/scheduled").recordings.sorted { $0.start < $1.start }
    }

    /// Skips one airing. The server forgets the skip when it restarts.
    public func cancel(_ recording: ScheduledRecording) async throws {
        _ = try await library.send(.delete, "/media/grabbers/operations/\(PlexURL.encode(recording.id))", [], headers: [:])
    }

    /// Deletes a rule and its scheduled airings.
    public func delete(_ rule: RecordingRule) async throws {
        _ = try await library.send(.delete, "/media/subscriptions/\(PlexURL.encode(rule.id))", [], headers: [:])
    }

    // MARK: Transport

    private func get<T: Decodable>(_ type: T.Type, _ path: String, _ query: [URLQueryItem] = []) async throws -> T {
        let response = try await library.send(.get, path, query, headers: [:])
        return try PlexJSON.decode(LiveEnvelope<T>.self, from: response.body).container
    }

    /// `hints%5Bguid%5D=plex%3A…&params%5B…%5D=…` as query items, decoded once so that `PlexURL`
    /// encodes them back to the same bytes' meaning.
    static func queryItems(decoding encoded: String) -> [URLQueryItem] {
        encoded.split(separator: "&").compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawName = parts.first, !rawName.isEmpty else { return nil }
            let name = String(rawName).removingPercentEncoding ?? String(rawName)
            let value = parts.count > 1 ? String(parts[1]).removingPercentEncoding ?? String(parts[1]) : ""
            return URLQueryItem(name: name, value: value)
        }
    }

    /// Every setting of a record option as `prefs[id]=value`, hidden ones included (`oneShot` is what
    /// makes "This Episode" record one airing).
    static func prefs(_ settings: [RecordSetting], _ values: [String: String]) -> [URLQueryItem] {
        settings.filter { !$0.id.isEmpty }.map { setting in
            URLQueryItem(name: "prefs[\(setting.id)]", value: values[setting.id] ?? setting.value)
        }
    }
}
