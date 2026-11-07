import Foundation

// The JSON of the live endpoints, read as leniently as the rest of the client, then turned into the
// public live types.

struct LiveEnvelope<Content: Decodable>: Decodable {
    let container: Content

    enum CodingKeys: String, CodingKey { case container = "MediaContainer" }
}

struct WireDVRList: Decodable {
    let dvrs: [LiveDVR]

    enum CodingKeys: String, CodingKey { case dvrs = "Dvr" }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let wire: [WireDVR] = c.list(.dvrs)
        dvrs = wire.compactMap(\.dvr)
    }
}

struct WireDVR: Decodable {
    let dvr: LiveDVR?

    enum CodingKeys: String, CodingKey {
        case key, uuid, lineupTitle, title, epgIdentifier
        case devices = "Device", settings = "Setting"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let devices: [WireDevice] = c.list(.devices)
        let settings: [WireSetting] = c.list(.settings)
        guard let key = c.string(.key), let epg = c.string(.epgIdentifier) else {
            dvr = nil
            return
        }
        func minutes(_ id: String) -> Int {
            settings.first { $0.setting.id == id }.flatMap { Int($0.setting.value) } ?? 0
        }
        dvr = LiveDVR(
            key: key,
            uuid: c.string(.uuid) ?? "",
            title: c.string(.lineupTitle) ?? c.string(.title) ?? "",
            epgIdentifier: epg,
            devices: devices.compactMap(\.device),
            mappings: devices.flatMap(\.mappings),
            startOffsetMinutes: minutes("startOffsetMinutes"),
            endOffsetMinutes: minutes("endOffsetMinutes")
        )
    }
}

struct WireDevice: Decodable {
    let device: TunerDevice?
    let mappings: [LiveChannelMapping]

    enum CodingKeys: String, CodingKey {
        case key, uuid, uri, make, model, modelNumber, deviceId, title, tuners, status
        case mappings = "ChannelMapping"
    }

    struct Mapping: Decodable {
        let channelKey: String?
        let number: String?
        let isEnabled: Bool

        enum CodingKeys: String, CodingKey { case channelKey, deviceIdentifier, enabled }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            channelKey = c.string(.channelKey)
            number = c.string(.deviceIdentifier)
            isEnabled = c.bool(.enabled) ?? false
        }
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let key = c.string(.key) ?? ""
        let wire: [Mapping] = c.list(.mappings)
        mappings = wire.compactMap { mapping in
            guard let channelKey = mapping.channelKey, let number = mapping.number else { return nil }
            return LiveChannelMapping(channelKey: channelKey, deviceKey: key, number: number, isEnabled: mapping.isEnabled)
        }
        guard !key.isEmpty, let uri = c.string(.uri).flatMap(URL.init(string:)) else {
            device = nil
            return
        }
        let makeModel = [c.string(.make), c.string(.model)].compactMap { $0 }.filter { !$0.isEmpty }
        let name = c.string(.title) ?? (makeModel.isEmpty ? c.string(.deviceId) : makeModel.joined(separator: " "))
        // Current servers say "alive" or "dead"; older ones "1" or "0".
        let status = c.string(.status)?.lowercased() ?? "alive"
        device = TunerDevice(
            key: key,
            uuid: c.string(.uuid) ?? "",
            uri: uri,
            name: name ?? "Tuner",
            tunerCount: max(c.int(.tuners) ?? 1, 1),
            isAlive: status != "dead" && status != "0"
        )
    }
}

struct WireSetting: Decodable {
    let setting: RecordSetting

    enum CodingKeys: String, CodingKey { case id, label, type, value, hidden, enumValues }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let value = c.string(.value) ?? c.bool(.value).map { $0 ? "true" : "false" } ?? ""
        setting = RecordSetting(
            id: c.string(.id) ?? "",
            label: c.string(.label) ?? "",
            type: c.string(.type) ?? "text",
            value: value,
            isHidden: c.bool(.hidden) ?? false,
            choices: RecordSetting.choices(c.string(.enumValues))
        )
    }
}

struct WireChannelList: Decodable {
    let channels: [WireChannel]

    enum CodingKeys: String, CodingKey { case channels = "Channel" }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channels = c.list(.channels)
    }
}

/// A lineup channel (`/lineups/dvr/channels`).
struct WireChannel: Decodable, Hashable {
    let key: String
    let number: String?
    let callSign: String
    let title: String
    let logo: String?
    let isHD: Bool

    enum CodingKeys: String, CodingKey { case id, gridKey, vcn, callSign, title, thumb, isHd }

    init(key: String, number: String?, callSign: String, title: String, logo: String?, isHD: Bool) {
        self.key = key
        self.number = number
        self.callSign = callSign
        self.title = title
        self.logo = logo
        self.isHD = isHD
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = c.string(.id) ?? c.string(.gridKey) ?? ""
        number = c.string(.vcn)
        callSign = c.string(.callSign) ?? ""
        title = c.string(.title) ?? ""
        logo = c.string(.thumb).flatMap { $0.isEmpty ? nil : $0 }
        isHD = c.bool(.isHd) ?? false
    }
}

struct WireGrid: Decodable {
    let airings: [LiveAiring]

    enum CodingKeys: String, CodingKey { case items = "Metadata" }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let items: [WireAiringItem] = c.list(.items)
        airings = items.flatMap(\.airings)
    }
}

/// A guide programme with one `Media` per channel it airs on.
struct WireAiringItem: Decodable {
    let airings: [LiveAiring]
    let title: String
    let episodeTitle: String?
    let season: Int?
    let episode: Int?
    let guid: String?
    let thumb: String?

    enum CodingKeys: String, CodingKey {
        case ratingKey, key, guid, type, title, grandparentTitle, parentIndex, index, year, summary
        case thumb, grandparentThumb, art, grandparentArt, contentRating
        case genres = "Genre", media = "Media"
    }

    struct Media: Decodable {
        let id: String?
        let channelKey: String?
        let start: Date?
        let end: Date?
        let isNew: Bool
        let resolution: Int?
        let channelNumber: String?
        let channelCallSign: String?

        enum CodingKeys: String, CodingKey {
            case id, channelIdentifier, beginsAt, endsAt, premiere, videoResolution, channelVcn, channelCallSign
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = c.string(.id)
            channelKey = c.string(.channelIdentifier)
            start = c.date(.beginsAt)
            end = c.date(.endsAt)
            isNew = c.bool(.premiere) ?? false
            resolution = c.int(.videoResolution)
            channelNumber = c.string(.channelVcn)
            channelCallSign = c.string(.channelCallSign)
        }
    }

    let media: [Media]

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = LiveAiring.Kind(rawValue: c.string(.type) ?? "") ?? .other
        let ownTitle = c.string(.title) ?? ""
        let showTitle = c.string(.grandparentTitle)
        if kind == .episode, let showTitle, !showTitle.isEmpty {
            title = showTitle
            episodeTitle = ownTitle.isEmpty || ownTitle == showTitle ? nil : ownTitle
        } else {
            title = ownTitle
            episodeTitle = nil
        }
        season = kind == .episode ? c.int(.parentIndex) : nil
        episode = kind == .episode ? c.int(.index) : nil
        guid = c.string(.guid)
        let ownThumb = c.string(.thumb)
        thumb = kind == .episode ? c.string(.grandparentThumb) ?? ownThumb : ownThumb
        media = c.list(.media)
        let ratingKey = c.string(.ratingKey) ?? ""
        let key = c.string(.key) ?? ""
        let year = c.int(.year)
        let summary = c.string(.summary)
        let art = c.string(.art) ?? c.string(.grandparentArt)
        let rating = c.string(.contentRating)
        let genres = c.tags(.genres)
        let title = title, episodeTitle = episodeTitle, season = season, episode = episode, guid = guid, thumb = thumb
        airings = media.compactMap { media in
            guard let id = media.id, let channelKey = media.channelKey, let start = media.start, let end = media.end, end > start else {
                return nil
            }
            return LiveAiring(
                id: id,
                channelKey: channelKey,
                ratingKey: ratingKey,
                key: key,
                guid: guid ?? "",
                kind: kind,
                title: title,
                episodeTitle: episodeTitle,
                season: season,
                episode: episode,
                year: year,
                summary: summary,
                start: start,
                end: end,
                isNew: media.isNew,
                isHD: (media.resolution ?? 0) >= 720,
                genres: genres,
                thumb: thumb,
                art: art,
                contentRating: rating
            )
        }
    }
}

/// A tune's answer. PMS 1.43.5 sends a rolling `MediaSubscription` whose one `MediaGrabOperation`
/// carries the tuned session as its `Metadata`.
struct WireTune: Decodable {
    let grabKey: String?
    let ratingKey: String?
    let uuid: String?
    let videoCodec: String?
    let videoHeight: Int?
    let isInterlaced: Bool
    let audioCodec: String?
    let audioChannels: Int?

    enum CodingKeys: String, CodingKey { case subscriptions = "MediaSubscription" }

    struct Subscription: Decodable {
        let grabs: [Grab]
        enum CodingKeys: String, CodingKey { case grabs = "MediaGrabOperation" }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            grabs = c.list(.grabs)
        }
    }

    struct Grab: Decodable {
        let key: String?
        let item: Item?
        enum CodingKeys: String, CodingKey { case key, item = "Metadata" }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = c.string(.key)
            item = try? c.decodeIfPresent(Item.self, forKey: .item)
        }
    }

    struct Item: Decodable {
        let ratingKey: String?
        let media: [Media]
        enum CodingKeys: String, CodingKey { case ratingKey, media = "Media" }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ratingKey = c.string(.ratingKey)
            media = c.list(.media)
        }
    }

    struct Media: Decodable {
        let uuid: String?
        let parts: [Part]
        enum CodingKeys: String, CodingKey { case uuid, parts = "Part" }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            uuid = c.string(.uuid)
            parts = c.list(.parts)
        }
    }

    struct Part: Decodable {
        let streams: [Stream]
        enum CodingKeys: String, CodingKey { case streams = "Stream" }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            streams = c.list(.streams)
        }
    }

    struct Stream: Decodable {
        let type: Int?
        let codec: String?
        let height: Int?
        let scanType: String?
        let channels: Int?
        enum CodingKeys: String, CodingKey { case streamType, codec, height, scanType, channels }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = c.int(.streamType)
            codec = c.string(.codec)
            height = c.int(.height)
            scanType = c.string(.scanType)
            channels = c.int(.channels)
        }
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let subscriptions: [Subscription] = c.list(.subscriptions)
        let grab = subscriptions.first?.grabs.first
        let item = grab?.item
        let media = item?.media.first
        let streams = media?.parts.first?.streams ?? []
        let video = streams.first { $0.type == 1 }
        let audio = streams.first { $0.type == 2 }
        grabKey = grab?.key
        ratingKey = item?.ratingKey
        uuid = media?.uuid
        videoCodec = video?.codec
        videoHeight = video?.height
        isInterlaced = video?.scanType == "interlaced"
        audioCodec = audio?.codec
        audioChannels = audio?.channels
    }
}

struct WireProviders: Decodable {
    let providers: [Provider]

    enum CodingKeys: String, CodingKey { case providers = "MediaProvider" }

    struct Provider: Decodable {
        let identifier: String?
        let features: [Feature]
        enum CodingKeys: String, CodingKey { case identifier, features = "Feature" }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            identifier = c.string(.identifier)
            features = c.list(.features)
        }
    }

    struct Feature: Decodable {
        let type: String?
        let filters: [Filter]
        enum CodingKeys: String, CodingKey { case type, filters = "GridChannelFilter" }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = c.string(.type)
            filters = c.list(.filters)
        }
    }

    struct Filter: Decodable {
        let title: String?
        let key: String?
        enum CodingKeys: String, CodingKey { case title, key }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = c.string(.title)
            key = c.string(.key)
        }
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        providers = c.list(.providers)
    }

    func filters(for epgIdentifier: String) -> [LiveChannelFilter] {
        let provider = providers.first { $0.identifier == epgIdentifier }
        let grid = provider?.features.first { $0.type == "grid" }
        return (grid?.filters ?? []).compactMap { filter in
            guard let title = filter.title, let key = filter.key else { return nil }
            return LiveChannelFilter(title: title, key: key)
        }
    }
}

struct WireTemplates: Decodable {
    let options: [RecordOption]

    enum CodingKeys: String, CodingKey { case templates = "SubscriptionTemplate" }

    struct Template: Decodable {
        let subscriptions: [WireSubscription]
        enum CodingKeys: String, CodingKey { case subscriptions = "MediaSubscription" }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            subscriptions = c.list(.subscriptions)
        }
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let templates: [Template] = c.list(.templates)
        options = templates.flatMap(\.subscriptions).compactMap(\.option)
    }
}

struct WireSubscriptions: Decodable {
    let rules: [RecordingRule]

    enum CodingKeys: String, CodingKey { case subscriptions = "MediaSubscription" }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let wire: [WireSubscription] = c.list(.subscriptions)
        rules = wire.compactMap(\.rule)
    }
}

/// A `MediaSubscription`: a template's record option, or a rule once created.
struct WireSubscription: Decodable {
    let option: RecordOption?
    let rule: RecordingRule?

    enum CodingKeys: String, CodingKey {
        case key, type, title, parameters, airingsType, librarySectionTitle, targetLibrarySectionID, targetSectionLocationID
        case directory = "Directory", video = "Video", settings = "Setting", grabs = "MediaGrabOperation"
    }

    struct Subject: Decodable {
        let title: String?
        let thumb: String?
        enum CodingKeys: String, CodingKey { case title, grandparentTitle, type, thumb, grandparentThumb }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let isEpisode = c.string(.type) == "episode"
            title = isEpisode ? c.string(.grandparentTitle) ?? c.string(.title) : c.string(.title)
            thumb = isEpisode ? c.string(.grandparentThumb) ?? c.string(.thumb) : c.string(.thumb)
        }
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = c.int(.type) ?? 0
        let ownTitle = c.string(.title) ?? ""
        let settings: [WireSetting] = c.list(.settings)
        let subject = (try? c.decodeIfPresent(Subject.self, forKey: .directory)) ?? (try? c.decodeIfPresent(Subject.self, forKey: .video))
        let section = c.string(.librarySectionTitle)
        option = c.string(.parameters).map { parameters in
            RecordOption(
                type: type,
                title: ownTitle,
                librarySectionTitle: section,
                targetLibrarySectionID: c.int(.targetLibrarySectionID),
                targetSectionLocationID: c.int(.targetSectionLocationID),
                settings: settings.map(\.setting),
                parameters: parameters
            )
        }
        let id = c.string(.key)
        let grabs: [WireGrab] = c.list(.grabs)
        rule = id.map { id in
            RecordingRule(
                id: id,
                type: type,
                title: subject?.title ?? ownTitle,
                airingsType: c.string(.airingsType),
                librarySectionTitle: section,
                targetLibrarySectionID: c.int(.targetLibrarySectionID),
                thumb: subject?.thumb,
                settings: settings.map(\.setting),
                recordings: grabs.compactMap { $0.recording(rule: id) }
            )
        }
    }
}

struct WireGrabList: Decodable {
    let recordings: [ScheduledRecording]

    enum CodingKeys: String, CodingKey { case grabs = "MediaGrabOperation" }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let grabs: [WireGrab] = c.list(.grabs)
        recordings = grabs.compactMap { $0.recording(rule: nil) }
    }
}

/// A `MediaGrabOperation`: one airing being recorded, with the airing as its `Metadata`.
struct WireGrab: Decodable {
    let id: String?
    let ruleID: String?
    let status: ScheduledRecording.Status
    let item: Item?

    enum CodingKeys: String, CodingKey { case id, mediaSubscriptionID, status, metadata = "Metadata" }

    struct Item: Decodable {
        let title: String
        let episodeTitle: String?
        let season: Int?
        let episode: Int?
        let guid: String?
        let thumb: String?
        let media: WireAiringItem.Media?
        let channelKey: String?

        enum CodingKeys: String, CodingKey {
            case title, grandparentTitle, type, parentIndex, index, guid, thumb, grandparentThumb
            case media = "Media"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let isEpisode = c.string(.type) == "episode"
            let ownTitle = c.string(.title) ?? ""
            let showTitle = c.string(.grandparentTitle)
            if isEpisode, let showTitle, !showTitle.isEmpty {
                title = showTitle
                episodeTitle = ownTitle.isEmpty || ownTitle == showTitle ? nil : ownTitle
            } else {
                title = ownTitle
                episodeTitle = nil
            }
            season = isEpisode ? c.int(.parentIndex) : nil
            episode = isEpisode ? c.int(.index) : nil
            guid = c.string(.guid)
            thumb = isEpisode ? c.string(.grandparentThumb) ?? c.string(.thumb) : c.string(.thumb)
            let media: [WireAiringItem.Media] = c.list(.media)
            self.media = media.first
            channelKey = media.first?.channelKey
        }
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.string(.id)
        ruleID = c.string(.mediaSubscriptionID)
        status = ScheduledRecording.Status(rawValue: c.string(.status) ?? "") ?? .unknown
        item = try? c.decodeIfPresent(Item.self, forKey: .metadata)
    }

    func recording(rule: String?) -> ScheduledRecording? {
        guard let id, let item, let start = item.media?.start, let end = item.media?.end else { return nil }
        return ScheduledRecording(
            id: id,
            ruleID: ruleID ?? rule,
            status: status,
            channelKey: item.channelKey,
            channelNumber: item.media?.channelNumber,
            channelCallSign: item.media?.channelCallSign,
            title: item.title,
            episodeTitle: item.episodeTitle,
            season: item.season,
            episode: item.episode,
            guid: item.guid,
            thumb: item.thumb,
            start: start,
            end: end
        )
    }
}
