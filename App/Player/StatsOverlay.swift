import AVFoundation
import MarqueeCore
import SwiftUI

/// Stats for nerds: the route, the stream and how the player is keeping up, refreshed once a second.
/// Taps pass through to the picture.
struct StatsOverlay: View {
    let model: PlayerModel
    @Environment(\.theme) private var theme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            panel(lines())
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("player.stats")
    }

    private func panel(_ lines: [StatLine]) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.s3, verticalSpacing: 2) {
            ForEach(lines) { line in
                GridRow {
                    Text(line.label)
                        .foregroundStyle(theme.ink2)
                    Text(line.value)
                        .foregroundStyle(theme.ink)
                }
            }
        }
        .textRole(.caption)
        .monospaced()
        .padding(Space.s3)
        .background(theme.glassRaised, in: RoundedRectangle(cornerRadius: Radius.row))
        .overlay(RoundedRectangle(cornerRadius: Radius.row).strokeBorder(theme.edge, lineWidth: 1))
        // One layer redrawn once a second, rather than dozens of text layers composited over the video
        // every frame.
        .drawingGroup()
    }

    private func lines() -> [StatLine] {
        var lines: [StatLine] = []
        if let route = model.route {
            lines.append(StatLine("Route", route.title))
            if !route.reasons.isEmpty {
                lines.append(StatLine("Why", route.reasons.map(\.description).joined(separator: ", ")))
            }
        }
        if let video = model.part?.videoStream {
            lines.append(StatLine("Video", [video.formatSummary, video.sizeSummary, video.dynamicRange].compactMap { $0 }.joined(separator: " · ")))
        }
        if let audio = model.audio {
            var text = [audio.codec, audio.channels.map { "\($0) ch" }].compactMap { $0 }.joined(separator: " ")
            if model.route?.convertsAudio == true { text += " → converted" }
            lines.append(StatLine("Audio", text))
        }
        if let words = model.route?.subtitle.words {
            lines.append(StatLine("Subtitles", words))
        }
        let size = model.presentationSize
        if size.width > 0 {
            lines.append(StatLine("Display", "\(Int(size.width)) × \(Int(size.height)) · \(model.aspect.title)"))
        }
        if let bitrate = model.media?.bitrate {
            lines.append(StatLine("File rate", mbps(Double(bitrate) * 1000)))
        }
        if let item = model.player?.currentItem {
            if let event = item.accessLog()?.events.last {
                if event.observedBitrate > 0 { lines.append(StatLine("Network", mbps(event.observedBitrate))) }
                lines.append(StatLine("Dropped", "\(max(0, event.numberOfDroppedVideoFrames)) frames · \(max(0, event.numberOfStalls)) stalls"))
            }
            lines.append(StatLine("Buffer", "\(bufferAhead(item).formatted(.number.precision(.fractionLength(1)))) s"))
        }
        if let remux = model.remux {
            let progress = remux.progress
            let bytes = progress.bytesWritten.formatted(.byteCount(style: .file))
            lines.append(StatLine("Remux", "\(clockText(progress.mediaSeconds)) · \(bytes) · \(progress.packets) packets\(progress.isPaced ? " · paced" : "")"))
        }
        if let session = model.transcodeSession {
            lines.append(StatLine("Transcode", String(session.prefix(8))))
        }
        if lines.isEmpty {
            lines.append(StatLine("Route", "Choosing…"))
        }
        return lines
    }

    private func mbps(_ bitsPerSecond: Double) -> String {
        "\((bitsPerSecond / 1_000_000).formatted(.number.precision(.fractionLength(1)))) Mbps"
    }

    /// Seconds loaded past the playhead.
    private func bufferAhead(_ item: AVPlayerItem) -> Double {
        let now = item.currentTime()
        for value in item.loadedTimeRanges {
            let range = value.timeRangeValue
            if range.containsTime(now) {
                return max(0, (range.end - now).seconds)
            }
        }
        return 0
    }
}

private struct StatLine: Identifiable {
    let label: String
    let value: String
    var id: String { label }

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}
