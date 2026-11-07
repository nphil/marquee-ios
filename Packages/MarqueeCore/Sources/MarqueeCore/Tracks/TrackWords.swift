import Foundation

/// Reads what a track is from its flags and the words in its title, since release groups name tracks
/// freely ("Signs / Songs", "English [CC]", "Dubtitles").
struct TrackWords {
    private let words: [String]
    private let text: String

    init(_ stream: PlexStream) {
        let texts = [stream.title, stream.displayTitle, stream.extendedDisplayTitle].compactMap { $0 }
        words = texts.joined(separator: " ").lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        text = words.joined(separator: " ")
    }

    /// Forced subtitles and signs-and-songs tracks: they carry only on-screen text and sung lines.
    var saysOnScreenText: Bool {
        words.contains { Self.forced.contains($0) || $0.hasPrefix("форс") }
    }

    var saysCommentary: Bool {
        words.contains { $0.hasPrefix("commentar") || $0.hasPrefix("комментари") }
    }

    var saysDub: Bool {
        words.contains { Self.dub.contains($0) }
    }

    var saysCaptions: Bool {
        words.contains { Self.captions.contains($0) } || Self.captionPhrases.contains { text.contains($0) }
    }

    var saysAudioDescription: Bool {
        words.contains { Self.audioDescription.contains($0) } || Self.audioDescriptionPhrases.contains { text.contains($0) }
    }

    private static let forced: Set<String> = ["forced", "forsed", "sign", "signs"]
    private static let dub: Set<String> = ["dub", "dubs", "dubbed", "dubtitle", "dubtitles"]
    private static let captions: Set<String> = ["sdh", "cc", "hoh"]
    private static let captionPhrases = ["hearing impaired", "closed caption", "deaf"]
    private static let audioDescription: Set<String> = ["ad", "dvs"]
    private static let audioDescriptionPhrases = [
        "audio description", "audio described", "described video", "descriptive audio", "descriptive video",
        "visually impaired",
    ]
}
