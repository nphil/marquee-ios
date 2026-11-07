import Foundation
@testable import MarqueeCore

/// Anonymised answers of the live endpoints, shaped like the home server's (docs/LIVE-TV.md §1.1).
enum LiveFixtures {
    /// 8:00 PM on the fixture day.
    static let eight = Date(timeIntervalSince1970: 1_800_000_000)

    static func at(minutes: Double) -> Date { eight.addingTimeInterval(minutes * 60) }

    static func seconds(_ minutes: Double) -> Int { Int(at(minutes: minutes).timeIntervalSince1970) }

    static var dvrs: [String: Any] { ["size": 1, "Dvr": [[
        "key": "12",
        "uuid": "dvr-uuid-1",
        "language": "eng",
        "lineupTitle": "Antenna",
        "lineup": "lineup://tv.plex.providers.epg.cloud/OTA-00000#Antenna",
        "refreshedAt": 1_799_990_000,
        "epgIdentifier": "tv.plex.providers.epg.cloud:5",
        "Device": [
            [
                "key": "21", "uuid": "device://tv.plex.grabbers.hdhomerun/1055AAAA", "uri": "http://192.0.2.42:5004",
                "protocol": "livetv", "status": "alive", "state": "enabled", "make": "LumaTV", "model": "LumaTuner",
                "tuners": "1",
                "ChannelMapping": [
                    ["channelKey": "aaa-0201", "deviceIdentifier": "2.1", "enabled": "1", "lineupIdentifier": "002"],
                    ["channelKey": "aaa-0401", "deviceIdentifier": "4.1", "enabled": "1", "lineupIdentifier": "004"],
                    ["channelKey": "aaa-1001", "deviceIdentifier": "10.1", "enabled": "1", "lineupIdentifier": "010"],
                    ["channelKey": "aaa-0501", "deviceIdentifier": "5.1", "enabled": "0", "lineupIdentifier": "005"],
                ],
            ],
            [
                "key": "22", "uuid": "device://tv.plex.grabbers.hdhomerun/1044BBBB", "uri": "http://192.0.2.43",
                "status": "dead", "make": "Silicondust", "model": "HDHomeRun CONNECT", "tuners": 2,
                "ChannelMapping": [
                    ["channelKey": "aaa-0201", "deviceIdentifier": "2.1", "enabled": "1"],
                    ["channelKey": "aaa-0701", "deviceIdentifier": "7.1", "enabled": true],
                ],
            ],
        ],
        "Setting": [
            ["id": "startOffsetMinutes", "value": 2],
            ["id": "endOffsetMinutes", "value": "5"],
            ["id": "minVideoQuality", "value": 0],
        ],
    ]]] }

    static var channels: [String: Any] { ["size": 5, "Channel": [
        channel("aaa-1001", "10.1", "WDDD", "Movies Plus", hd: false),
        channel("aaa-0201", "2.1", "WAAA", "Network A", hd: true),
        channel("aaa-0401", "4.1", "WBBB", "Network B", hd: true),
        channel("aaa-0501", "5.1", "WEEE", "Shopping", hd: false),
        channel("aaa-0701", "7.1", "WCCC", "Network C", hd: true),
    ]] }

    static func channel(_ key: String, _ number: String, _ callSign: String, _ title: String, hd: Bool) -> [String: Any] {
        [
            "id": key, "gridKey": key, "vcn": number, "isHd": hd ? "1" : "0", "callSign": callSign, "title": title,
            "language": "en", "thumb": "https://provider-static.plex.tv/epg/logos/\(callSign.lowercased()).png",
        ]
    }

    static var grid: [String: Any] { ["size": 3, "Metadata": [
        [
            "ratingKey": "plex%3A%2F%2Fepisode%2Fnews12", "key": "/tv.plex.providers.epg.cloud:5/metadata/news12",
            "guid": "plex://episode/news12", "type": "episode", "title": "Storm Watch", "grandparentTitle": "Evening News",
            "parentIndex": 3, "index": 12, "year": 2027, "summary": "Weather and the day's headlines.",
            "thumb": "https://metadata-static.plex.tv/episode-news12.jpg",
            "grandparentThumb": "https://metadata-static.plex.tv/show-news.jpg",
            "Genre": [["tag": "News"]],
            "Channel": [["id": 31, "filter": "channel=31", "tag": "2.1 WAAA (Network A)"]],
            "Media": [media("901", "aaa-0201", "2.1", "WAAA", from: 0, to: 30, premiere: true, resolution: "720")],
        ],
        [
            "ratingKey": "plex%3A%2F%2Fmovie%2Froad", "key": "/tv.plex.providers.epg.cloud:5/metadata/road",
            "guid": "plex://movie/road", "type": "movie", "title": "The Long Road", "year": 1998,
            "thumb": "https://metadata-static.plex.tv/movie-road.jpg",
            "Genre": [["tag": "Drama"], ["tag": "Movie"]],
            "Media": [
                media("902", "aaa-0401", "4.1", "WBBB", from: -15, to: 105, premiere: false, resolution: "480"),
                // A simulcast on a channel no device maps.
                media("903", "zzz-9901", "51.1", "WZZZ", from: -15, to: 105, premiere: false, resolution: "480"),
            ],
        ],
        [
            "ratingKey": "plex%3A%2F%2Fepisode%2Fquiz", "key": "/tv.plex.providers.epg.cloud:5/metadata/quiz",
            "guid": "plex://episode/quiz", "type": "episode", "title": "Quiz Night", "grandparentTitle": "Quiz Night",
            "grandparentThumb": "https://metadata-static.plex.tv/show-quiz.jpg",
            "Media": [media("904", "aaa-0201", "2.1", "WAAA", from: 30, to: 60, premiere: false, resolution: "720")],
        ],
    ]] }

    static func media(
        _ id: String, _ channel: String, _ number: String, _ callSign: String,
        from: Double, to: Double, premiere: Bool, resolution: String
    ) -> [String: Any] {
        [
            "id": Int(id)!, "beginsAt": seconds(from), "endsAt": String(seconds(to)), "premiere": premiere,
            "onAir": false, "audioChannels": 2, "videoResolution": resolution, "channelID": 31,
            "channelIdentifier": channel, "channelVcn": number, "channelCallSign": callSign,
            "channelTitle": "\(number) \(callSign)", "protocol": "livetv",
        ]
    }

    static var tune: [String: Any] { ["size": 1, "Metadata": [[
        "ratingKey": "live-77",
        "live": true,
        "genuineMediaAnalysis": true,
        "Media": [[
            "uuid": "sess-1111",
            "Part": [["Stream": [
                ["streamType": 1, "codec": "mpeg2video", "height": 480, "width": 704, "scanType": "interlaced", "frameRate": 29.97],
                ["streamType": 2, "codec": "ac3", "channels": 6, "samplingRate": 48000],
            ]]],
        ]],
    ]]] }

    static var template: [String: Any] { ["size": 1, "SubscriptionTemplate": [["MediaSubscription": [
        [
            "parameters": "hints%5Bguid%5D=plex%3A%2F%2Fepisode%2Fnews12&hints%5BgrandparentTitle%5D=Evening%20News&hints%5BratingKey%5D=plex%253A%252F%252Fepisode%252Fnews12&params%5BairingChannels%5D=aaa-0201%253D2%25252E1%252520WAAA&params%5BmediaProviderID%5D=13",
            "type": 4, "targetLibrarySectionID": 2, "targetSectionLocationID": 3, "title": "This Episode",
            "librarySectionTitle": "TV Shows",
            "Video": ["title": "Storm Watch", "grandparentTitle": "Evening News", "type": "episode"],
            "Setting": [
                ["id": "startOffsetMinutes", "label": "Start recording", "type": "int", "value": "0", "hidden": false],
                ["id": "endOffsetMinutes", "label": "Stop recording", "type": "int", "value": "0", "hidden": false],
                ["id": "oneShot", "label": "", "type": "bool", "value": "true", "hidden": true],
            ],
        ],
        [
            "parameters": "hints%5Bguid%5D=plex%3A%2F%2Fshow%2Fnews&hints%5Btype%5D=2&params%5BlibraryType%5D=2",
            "type": 2, "targetLibrarySectionID": 2, "title": "All Episodes", "airingsType": "New Airings Only",
            "librarySectionTitle": "TV Shows",
            "Directory": ["title": "Evening News", "type": "show"],
            "Setting": [
                [
                    "id": "onlyNewAirings", "label": "Airings", "type": "int", "value": "1", "hidden": false,
                    "enumValues": "0:New and Repeat Airings|1:New Airings Only",
                ],
                ["id": "oneShot", "type": "bool", "value": false, "hidden": true],
            ],
        ],
    ]]]] }

    static func grab(_ id: String, rule: String, status: String, from: Double, to: Double, channel: String = "aaa-0201") -> [String: Any] {
        [
            "id": id, "mediaSubscriptionID": Int(rule)!, "status": status, "grabberIdentifier": "tv.plex.grabbers.hdhomerun",
            "Metadata": [
                "type": "episode", "title": "Storm Watch", "grandparentTitle": "Evening News", "parentIndex": 3, "index": 12,
                "guid": "plex://episode/news12", "grandparentThumb": "https://metadata-static.plex.tv/show-news.jpg",
                "Media": [["beginsAt": seconds(from), "endsAt": seconds(to), "channelIdentifier": channel, "channelVcn": "2.1", "channelCallSign": "WAAA"]],
            ],
        ]
    }

    static var scheduled: [String: Any] { ["size": 2, "MediaGrabOperation": [
        grab("grab-2", rule: "31", status: "scheduled", from: 1440, to: 1470),
        grab("grab-1", rule: "31", status: "inprogress", from: 0, to: 30),
    ]] }

    static var subscriptions: [String: Any] { ["size": 1, "MediaSubscription": [[
        "key": "31", "type": 2, "title": "All Episodes", "airingsType": "New Airings Only", "librarySectionTitle": "TV Shows",
        "Directory": ["title": "Evening News", "type": "show", "thumb": "https://metadata-static.plex.tv/show-news.jpg"],
        "Setting": [["id": "onlyNewAirings", "type": "int", "value": "1", "enumValues": "0:New and Repeat Airings|1:New Airings Only"]],
        "MediaGrabOperation": [grab("grab-2", rule: "31", status: "scheduled", from: 1440, to: 1470)],
    ]]] }

    static var providers: [String: Any] { ["size": 2, "MediaProvider": [
        ["identifier": "com.plexapp.plugins.library", "Feature": [["type": "content", "key": "/library/sections"]]],
        [
            "identifier": "tv.plex.providers.epg.cloud:5", "protocols": "livetv", "epgSource": "Gracenote",
            "Feature": [
                ["type": "content", "key": "/tv.plex.providers.epg.cloud:5/sections"],
                [
                    "type": "grid", "key": "/tv.plex.providers.epg.cloud:5/grid",
                    "GridChannelFilter": [
                        ["key": "/tv.plex.providers.epg.cloud:5/lineups/dvr/channels?genre=genre_news", "title": "News", "genreRatingKey": "genre_news"],
                        ["key": "/tv.plex.providers.epg.cloud:5/lineups/dvr/channels?genre=genre_movies", "title": "Movies", "genreRatingKey": "genre_movies"],
                    ],
                ],
            ],
        ],
    ]] }
}
