import AVFoundation
import CoreMedia
import MarqueeCore
import os
import SwiftUI
import UIKit
import VideoEngine

/// The engine's events and FFmpeg's lines in the unified log. The remux's sources name only the host
/// and file, so no token reaches the log.
enum EngineLog {
    static let logger: EngineLogger = {
        let log = Logger(subsystem: "com.nphil.marquee", category: "engine")
        return EngineLogger(
            event: { tag, fields in
                let text = fields.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
                log.info("\(tag, privacy: .public) \(text, privacy: .public)")
            },
            message: { line in
                log.debug("\(line, privacy: .public)")
            }
        )
    }()
}

/// Fetches a file from the server with the authorization headers, so the token stays out of the URL.
enum PlexFetch {
    struct Status: LocalizedError {
        let code: Int
        var errorDescription: String? { "The server answered \(code)." }
    }

    static func data(_ path: String, library: PlexLibrary, session: URLSession) async throws -> Data {
        let base = try await library.connection.connection().uri
        guard let url = PlexURL.make(base: base, path: path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        for (name, value) in library.authorizationHeaders() { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw Status(code: http.statusCode) }
        return data
    }
}

/// One subtitle cue for the overlay, its WebVTT markup turned into italic, bold and underlined runs.
struct TextCue: Sendable, Equatable {
    var start: TimeInterval
    var end: TimeInterval
    var text: AttributedString
}

/// A downloaded subtitle file, ready to draw or to hand to the remux.
struct SidecarContents: Sendable {
    var cues: [TextCue]
    var bitmaps: SubtitleOverlayTrack?
    /// The text as a remux rendition.
    var sidecar: SidecarSubtitles
}

enum SidecarLoader {
    struct Unsupported: LocalizedError {
        let format: String
        var errorDescription: String? { "\(format.uppercased()) subtitle files can't be shown." }
    }

    /// Downloads an external subtitle stream (`/library/streams/<id>`) and reads it. The temporary
    /// file is deleted once read.
    static func load(_ track: SubtitleTrack, key: String, library: PlexLibrary, session: URLSession) async throws -> SidecarContents {
        let format = track.codec.lowercased()
        guard let ext = fileExtension(format) else { throw Unsupported(format: format.isEmpty ? "unknown" : format) }
        let data = try await PlexFetch.data(key, library: library, session: session)
        let file = FileManager.default.temporaryDirectory.appending(path: "marquee-subtitle-\(UUID().uuidString).\(ext)")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let contents = try await SubtitleFile.read(fileURL: file)
        return SidecarContents(
            cues: contents.cues.map { TextCue(start: $0.start, end: $0.end, text: CueText.attributed($0.text)) },
            bitmaps: contents.bitmaps.isEmpty ? nil : SubtitleOverlayTrack(contents.bitmaps),
            sidecar: SidecarSubtitles(
                name: name(track),
                language: track.language.code ?? "und",
                isForced: track.kind == .onScreenText,
                isHearingImpaired: track.kind == .captions,
                cues: contents.cues
            )
        )
    }

    /// The rendition name the remux lists a downloaded track under; unique per stream id.
    static func name(_ track: SubtitleTrack) -> String {
        "\(track.label) [\(track.id)]"
    }

    /// Plex names a sidecar's format by codec. VobSub needs its .idx and .sub pair, which one stream
    /// download cannot give.
    private static func fileExtension(_ codec: String) -> String? {
        switch codec {
        case "srt", "subrip": "srt"
        case "ass": "ass"
        case "ssa": "ssa"
        case "vtt", "webvtt": "vtt"
        case "smi", "sami": "smi"
        case "pgs", "hdmv_pgs_subtitle", "sup": "sup"
        default: nil
        }
    }
}

/// WebVTT cue text as the engine writes it: `<i>`, `<b>` and `<u>` tags, with `&`, `<` and `>` escaped.
enum CueText {
    static func attributed(_ markup: String) -> AttributedString {
        var result = AttributedString()
        var italic = 0, bold = 0, underline = 0
        var rest = Substring(markup)
        while !rest.isEmpty {
            if rest.first == "<", let close = rest.firstIndex(of: ">") {
                switch rest[rest.index(after: rest.startIndex)..<close].lowercased() {
                case "i": italic += 1
                case "/i": italic = max(0, italic - 1)
                case "b": bold += 1
                case "/b": bold = max(0, bold - 1)
                case "u": underline += 1
                case "/u": underline = max(0, underline - 1)
                default: break
                }
                rest = rest[rest.index(after: close)...]
                continue
            }
            let end = rest.firstIndex(of: "<") ?? rest.endIndex
            var run = AttributedString(unescape(rest[..<end]))
            var intent: InlinePresentationIntent = []
            if italic > 0 { intent.insert(.emphasized) }
            if bold > 0 { intent.insert(.stronglyEmphasized) }
            if !intent.isEmpty { run.inlinePresentationIntent = intent }
            if underline > 0 { run.underlineStyle = .single }
            result += run
            rest = rest[end...]
        }
        return result
    }

    private static func unescape(_ text: Substring) -> String {
        guard text.contains("&") else { return String(text) }
        return text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: "\u{00A0}")
            .replacingOccurrences(of: "&lrm;", with: "\u{200E}")
            .replacingOccurrences(of: "&rlm;", with: "\u{200F}")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// Picks among an item's built-in audio and text tracks through AVFoundation. Runs off the main actor
/// so the selection groups, which are not Sendable, stay inside one function.
enum MediaSelection {
    enum Legible: Sendable, Equatable {
        case none
        /// A rendition of the remux, by the name it lists.
        case named(String)
        /// The captions carried in the video stream.
        case closedCaptions
        /// The n-th text track of the file, with its language for when the count does not match.
        case position(Int, language: String?)
    }

    static func select(audioPosition position: Int, language: String?, in item: AVPlayerItem, asset: AVAsset) async {
        guard let group = try? await asset.loadMediaSelectionGroup(for: .audible) else { return }
        let options = group.options
        let option = options.count > position ? options[position] : options.first { matches($0, language) }
        if let option { item.select(option, in: group) }
    }

    static func select(_ legible: Legible, in item: AVPlayerItem, asset: AVAsset) async {
        guard let group = try? await asset.loadMediaSelectionGroup(for: .legible) else { return }
        let option: AVMediaSelectionOption?
        switch legible {
        case .none:
            option = nil
        case .named(let name):
            option = group.options.first { $0.displayName == name }
        case .closedCaptions:
            option = group.options.first { $0.mediaType == .closedCaption }
        case .position(let index, let language):
            let text = group.options.filter { $0.mediaType != .closedCaption }
            option = text.count > index ? text[index] : text.first { matches($0, language) }
        }
        item.select(option, in: group)
    }

    private static func matches(_ option: AVMediaSelectionOption, _ language: String?) -> Bool {
        guard let language, let tag = option.extendedLanguageTag ?? option.locale?.identifier else { return false }
        return TrackLanguage(tag: tag).matches(TrackLanguage(tag: language))
    }
}

/// The subtitle style for text AVPlayer draws. Left to the system's caption settings until the profile
/// changes the style; `lifted` raises the line above the bottom chrome.
@MainActor
enum CaptionStyle {
    static func rules(for style: SubtitleStyle, lifted: Bool) -> [AVTextStyleRule]? {
        var attributes: [String: Any] = [:]
        if style != SubtitleStyle() {
            attributes[kCMTextMarkupAttribute_ForegroundColorARGB as String] = argb(PictureColours.subtitle(style.colour))
            attributes[kCMTextMarkupAttribute_BaseFontSizePercentageRelativeToVideoHeight as String] = style.size.heightFraction * 100
            attributes[kCMTextMarkupAttribute_CharacterEdgeStyle as String] = edge(style.edge)
            if style.isBold { attributes[kCMTextMarkupAttribute_BoldStyle as String] = true }
            if style.hasBackground {
                attributes[kCMTextMarkupAttribute_CharacterBackgroundColorARGB as String] = argb(PictureColours.subtitleBox)
            }
        }
        if style.position == .top {
            attributes[kCMTextMarkupAttribute_OrthogonalLinePositionPercentageRelativeToWritingDirection as String] = 10
        } else if lifted {
            attributes[kCMTextMarkupAttribute_OrthogonalLinePositionPercentageRelativeToWritingDirection as String] = 62
        }
        guard !attributes.isEmpty else { return nil }
        return AVTextStyleRule(textMarkupAttributes: attributes).map { [$0] }
    }

    private static func edge(_ edge: SubtitleStyle.Edge) -> String {
        switch edge {
        case .none: kCMTextMarkupCharacterEdgeStyle_None as String
        case .outline: kCMTextMarkupCharacterEdgeStyle_Uniform as String
        case .shadow: kCMTextMarkupCharacterEdgeStyle_DropShadow as String
        }
    }

    private static func argb(_ color: Color) -> [Double] {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [alpha, red, green, blue].map(Double.init)
    }
}

/// "1:02:03" or "4:05"; "0:04:05" with `hours` set, so the two times beside a long film's scrubber match.
func clockText(_ seconds: TimeInterval, hours: Bool = false) -> String {
    let total = Int(max(0, seconds.isFinite ? seconds : 0))
    let h = total / 3600, minutes = (total / 60) % 60, secs = total % 60
    return h > 0 || hours ? String(format: "%d:%02d:%02d", h, minutes, secs) : String(format: "%d:%02d", minutes, secs)
}
