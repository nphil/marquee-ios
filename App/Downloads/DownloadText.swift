import Foundation
import MarqueeCore

/// The words on the Downloads screen's rows, so a row and its spoken label say the same things.
enum DownloadText {
    /// "1.4 GB", in the iPhone's file-size style.
    static func size(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }

    /// "5 · Name" on its show's page, where the number says which episode it is; otherwise the name.
    static func title(_ record: DownloadRecord, numbered: Bool) -> String {
        guard numbered, let index = record.episodeIndex else { return record.title }
        return "\(index) · \(record.title)"
    }

    /// Under the title: an episode's show and code (`named`, away from its show's page) or a movie's year,
    /// then the running time.
    static func line(_ record: DownloadRecord, named: Bool) -> String? {
        var parts: [String?] = []
        if record.type == .episode {
            if named { parts += [record.showTitle, record.seasonEpisode] }
        } else {
            parts.append(record.year.map(String.init))
        }
        parts.append(ItemText.runtime(record.duration))
        let line = parts.compactMap(\.self).joined(separator: " · ")
        return line.isEmpty ? nil : line
    }

    /// "1.4 GB · 1080p · Original": what it takes, the picture's size and how it was made.
    static func facts(_ record: DownloadRecord) -> String {
        factParts(record, estimate: "~").joined(separator: " · ")
    }

    /// Until the server has given the file's length, the size is an estimate, marked as one.
    private static func factParts(_ record: DownloadRecord, estimate: String) -> [String] {
        var parts: [String] = []
        if let bytes = record.totalBytes, bytes > 0 {
            parts.append((record.length == nil && record.phase != .done ? estimate : "") + size(bytes))
        }
        if let resolution = record.resolution { parts.append(resolution) }
        parts.append(quality(record.quality))
        return parts
    }

    /// "Original", or the bitrate a conversion was asked for; its picture size is named beside it.
    static func quality(_ quality: DownloadQuality) -> String {
        switch quality {
        case .original: "Original"
        case .converted(let preset): preset.maxBitrateKbps.map { "\($0 / 1000) Mbps" } ?? preset.title
        }
    }

    /// What a download that is not finished is doing; nil once it is done.
    static func state(_ record: DownloadRecord) -> String? {
        switch record.phase {
        case .waiting: "Waiting"
        case .converting: record.conversion?.progress.map { "Converting · \(percent($0))" } ?? "Converting"
        case .downloading: record.fraction.map { "Downloading · \(percent($0))" } ?? "Downloading"
        case .paused: "Paused"
        case .failed(let reason): "Failed · \(reason)"
        case .done: nil
        }
    }

    /// How far a download that is not finished has come, 0…1: the server's conversion while it converts.
    static func progress(_ record: DownloadRecord) -> Double? {
        record.phase == .converting ? record.conversion?.progress : record.fraction
    }

    /// What VoiceOver reads for a row: the title with its place, what it is, then the state or how far
    /// it was watched. Commas where the screen has dots, which VoiceOver would read out.
    static func spoken(_ record: DownloadRecord, named: Bool) -> String {
        var parts: [String?] = []
        if record.type == .episode {
            if named { parts += [record.showTitle, record.seasonIndex.map { "Season \($0)" }] }
            parts.append(record.episodeIndex.map { "Episode \($0)" })
        }
        parts.append(record.title)
        if record.type != .episode { parts.append(record.year.map(String.init)) }
        if record.duration >= 30_000 {
            parts.append(Duration.milliseconds(record.duration).formatted(.units(allowed: [.hours, .minutes], width: .wide)))
        }
        parts += factParts(record, estimate: "about ")
        if let state = state(record) {
            parts.append(state.replacing(" · ", with: ", "))
        } else if record.watchedFraction != nil {
            parts.append(ItemText.spokenLeft(max(1, Int((Double(record.duration - record.watch.offset) / 60_000).rounded(.up)))))
        } else if record.watch.watched {
            parts.append("watched")
        }
        return parts.compactMap(\.self).joined(separator: ", ")
    }

    private static func percent(_ value: Double) -> String {
        "\(Int(min(max(value, 0), 1) * 100))%"
    }
}
