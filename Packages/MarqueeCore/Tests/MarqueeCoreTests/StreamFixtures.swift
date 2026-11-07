import Foundation
@testable import MarqueeCore

/// Plex stream JSON, as the server sends it.
enum Fixture {
    static func video(
        _ codec: String = "h264",
        bitDepth: Int = 8,
        chroma: String = "4:2:0",
        level: Int? = nil,
        frameRate: Double = 23.976,
        colorTrc: String? = nil,
        dolbyVision: (profile: Int, compatibility: Int)? = nil
    ) -> [String: Any] {
        var stream: [String: Any] = [
            "id": 1, "streamType": 1, "codec": codec, "bitDepth": bitDepth, "chromaSubsampling": chroma,
            "frameRate": frameRate, "width": 1920, "height": 1080,
        ]
        if let level { stream["level"] = level }
        if let colorTrc { stream["colorTrc"] = colorTrc }
        if let dolbyVision {
            stream["DOVIPresent"] = true
            stream["DOVIProfile"] = dolbyVision.profile
            stream["DOVIBLCompatID"] = dolbyVision.compatibility
        }
        return stream
    }

    static func audio(
        _ id: Int,
        _ language: String?,
        tag: String? = nil,
        title: String? = nil,
        codec: String = "aac",
        channels: Int = 2,
        isDefault: Bool = false,
        selected: Bool = false,
        visualImpaired: Bool = false
    ) -> [String: Any] {
        var stream: [String: Any] = [
            "id": id, "streamType": 2, "codec": codec, "channels": channels,
            "default": isDefault, "selected": selected, "visualImpaired": visualImpaired,
        ]
        if let language { stream["languageCode"] = language }
        if let tag { stream["languageTag"] = tag }
        if let title { stream["title"] = title }
        return stream
    }

    static func subtitle(
        _ id: Int,
        _ language: String?,
        tag: String? = nil,
        title: String? = nil,
        codec: String = "srt",
        external: Bool = false,
        forced: Bool = false,
        hearingImpaired: Bool = false,
        inVideo: Bool = false,
        isDefault: Bool = false,
        selected: Bool = false
    ) -> [String: Any] {
        var stream: [String: Any] = [
            "id": id, "streamType": 3, "codec": codec, "forced": forced, "hearingImpaired": hearingImpaired,
            "embeddedInVideo": inVideo ? "1" : "0", "default": isDefault, "selected": selected,
        ]
        if let language { stream["languageCode"] = language }
        if let tag { stream["languageTag"] = tag }
        if let title { stream["title"] = title }
        if external { stream["key"] = "/library/streams/\(id)" } else { stream["index"] = id }
        return stream
    }

    static func tracks(_ streams: [[String: Any]]) throws -> MediaTracks {
        MediaTracks(streams: try decode([PlexStream].self, streams))
    }
}
