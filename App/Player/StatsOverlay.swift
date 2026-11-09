import AVFoundation
import MarqueeCore
import SwiftUI
import UIKit
import VideoEngine
import os

/// Stats for nerds: what is playing and how the player keeps up, refreshed twice a second. Two columns
/// in landscape. Only the Copy button takes touches; the rest passes through to the picture. Copy sits
/// beside the lines at the top: at large text sizes the panel runs down under the scrubber and bottom
/// row, which would otherwise cover it while the controls show.
struct StatsOverlay: View {
    let model: PlayerModel
    @Environment(\.theme) private var theme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var server: PlayerStats.Server?
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: Space.s3) {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                columns(stream: PlayerStats.stream(model, server: server), health: PlayerStats.health(model, server: server))
                    // One layer redrawn twice a second, rather than dozens of text layers composited over
                    // the video every frame.
                    .drawingGroup()
            }
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("player.stats")

            copyButton
        }
        .textRole(.caption)
        .monospaced()
        .padding(Space.s3)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.row).fill(theme.glassRaised)
                RoundedRectangle(cornerRadius: Radius.row).strokeBorder(theme.edge, lineWidth: 1)
            }
            .allowsHitTesting(false)
        }
        // Past XXXL the two columns no longer fit a landscape screen and the panel would hide the
        // picture it reports on.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .task(id: model.transcodeSession) {
            while !Task.isCancelled {
                server = await PlayerStats.Server.read(model)
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    @ViewBuilder
    private func columns(stream: [PlayerStats.Line], health: [PlayerStats.Line]) -> some View {
        if verticalSizeClass == .compact {
            HStack(alignment: .top, spacing: Space.s6) {
                grid(stream)
                grid(health)
            }
        } else {
            grid(stream + health)
        }
    }

    private func grid(_ lines: [PlayerStats.Line]) -> some View {
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
    }

    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = PlayerStats.report(model, server: server)
            Haptics.impact(.light)
            AccessibilityNotification.Announcement("Copied").post()
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                .fixedSize()
                .foregroundStyle(theme.ink)
                .frame(minWidth: Size.target, minHeight: Size.target, alignment: .topLeading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? "Copied" : "Copy stats")
        .accessibilityIdentifier("player.stats.copy")
    }
}

/// The stats overlay's lines and the text that Copy, and Playback Info's Copy Diagnostics, put on the
/// clipboard.
@MainActor
enum PlayerStats {
    struct Line: Identifiable {
        let label: String
        let value: String
        var id: String { label }

        init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
    }

    /// Facts that take a request: the server address in use and, while the server converts, its own
    /// account of the transcode.
    struct Server: Sendable {
        var connection: PlexConnection?
        var transcode: PlexTranscodeSession?
        /// The latest connection probe rounds, oldest first.
        var probes: [ProbeRound] = []

        @MainActor static func read(_ model: PlayerModel) async -> Server {
            let library = model.library
            let connection = await library.connection.currentConnection
            let probes = await library.connection.probeRounds
            guard let session = model.transcodeSession else { return Server(connection: connection, probes: probes) }
            return Server(connection: connection, transcode: try? await library.transcodeSession(session), probes: probes)
        }
    }

    /// What plays, and why.
    static func stream(_ model: PlayerModel, server: Server?) -> [Line] {
        var lines: [Line] = []
        if let route = model.route {
            lines.append(Line("Route", route.title))
            if !route.reasons.isEmpty {
                lines.append(Line("Why", route.reasons.map(\.description).joined(separator: ", ")))
            }
        } else {
            lines.append(Line("Route", "Choosing…"))
        }
        if let fallback = model.fallback {
            lines.append(Line("Fallback", fallback))
        }
        if let detail = model.failureDetail {
            lines.append(Line("Error", detail))
        }
        if let connection = model.streamConnection ?? server?.connection {
            lines.append(Line("Server", "\(connection.kindWord) · \(connection.displayAddress)"))
        }
        for (i, line) in (server?.probes.last?.lines ?? []).enumerated() {
            lines.append(Line("Probe \(i + 1)", line))
        }
        let file = [
            (model.part?.container ?? model.media?.container)?.uppercased(),
            model.media?.bitrate.map { mbps(Double($0) * 1000) },
            model.part?.size.map { Int64($0).formatted(.byteCount(style: .file)) },
        ].compactMap { $0 }
        if !file.isEmpty {
            lines.append(Line("File", file.joined(separator: " · ")))
        }
        if let video = model.part?.videoStream {
            let rate = video.frameRate.map { "\($0.formatted(.number.precision(.fractionLength(0...3)))) fps" }
            lines.append(Line("Video", [video.formatSummary, video.sizeSummary, rate].compactMap { $0 }.joined(separator: " · ")))
            var picture = [video.dynamicRange]
            if model.route?.reencodesVideo == true {
                picture.append("converted by the server")
            } else if let decode = model.capabilities.hardware?.decode, let support = decoder(for: video, in: decode) {
                picture.append(words(support))
            }
            lines.append(Line("Picture", picture.joined(separator: " · ")))
        }
        if let audio = model.audio {
            let format = [audio.codec.uppercased(), audio.channels.map { "\($0) ch" }].compactMap { $0 }.joined(separator: " ")
            let converted = server?.transcode?.audioDecision.map { $0 == "transcode" } ?? (model.route?.convertsAudio == true)
            lines.append(Line("Audio", "\(format) · \(converted ? "converted" : "copied")"))
        }
        lines.append(Line("Subtitles", model.route?.subtitle.words ?? "Off"))
        return lines
    }

    /// How playback keeps up, and how the phone is coping.
    static func health(_ model: PlayerModel, server: Server?) -> [Line] {
        var lines = [Line("Start", model.startTiming.summary)]
        let size = model.presentationSize
        if size.width > 0 {
            lines.append(Line("Display", "\(Int(size.width)) × \(Int(size.height)) · \(model.aspect.title)"))
        }
        if let item = model.player?.currentItem {
            if let event = item.accessLog()?.events.last {
                // A remux plays from the phone's own loopback server; the link that matters is the read
                // from the media server.
                if let remux = model.remux {
                    let rate = remux.progress.sourceBytesPerSecond
                    lines.append(Line("Network", rate.map { "\(mbps($0 * 8)) from the server" } ?? "–"))
                } else {
                    var network = event.observedBitrate > 0 ? mbps(event.observedBitrate) : "–"
                    if event.indicatedBitrate > 0 { network += " · stream \(mbps(event.indicatedBitrate))" }
                    lines.append(Line("Network", network))
                }
                lines.append(Line("Frames", "\(max(0, event.numberOfDroppedVideoFrames)) dropped · \(max(0, event.numberOfStalls)) stalls"))
            }
            lines.append(Line("Buffer", "\(bufferAhead(item).formatted(.number.precision(.fractionLength(1)))) s ahead"))
            if let errors = item.errorLog()?.events, let last = errors.last {
                lines.append(Line("Errors", "\(errors.count) · last \(last.errorDomain) \(last.errorStatusCode)"))
            }
        }
        if let remux = model.remux {
            let progress = remux.progress
            let lead = progress.mediaSeconds - (model.player?.currentTime().seconds ?? 0)
            let parts = [
                "lead \(lead.formatted(.number.precision(.fractionLength(1)))) s",
                progress.bytesWritten.formatted(.byteCount(style: .file)),
                "\(progress.packets.formatted()) packets",
                progress.isPaced ? "paced" : nil,
            ].compactMap { $0 }
            lines.append(Line("Remux", parts.joined(separator: " · ")))
        }
        if let session = model.transcodeSession {
            lines.append(Line("Transcode", server?.transcode.map(summary) ?? "session \(session.prefix(8))"))
        }
        var heat = thermal(ProcessInfo.processInfo.thermalState)
        if ProcessInfo.processInfo.isLowPowerModeEnabled { heat += " · Low Power Mode" }
        lines.append(Line("Heat", heat))
        // 0 where the process has no memory limit, as on the simulator, where it read "Zero kB free".
        let available = os_proc_available_memory()
        lines.append(Line("Memory", [
            footprint().map { "\($0.formatted(.byteCount(style: .memory))) used" },
            available > 0 ? "\(Int64(available).formatted(.byteCount(style: .memory))) free" : nil,
        ].compactMap { $0 }.joined(separator: " · ")))
        return lines
    }

    /// The overlay's lines, then the engine's recent measurements and this phone's hardware report.
    static func report(_ model: PlayerModel, server: Server?) -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        var text = ["Marquee \(version)", [model.title, model.subtitleLine].compactMap { $0 }.joined(separator: " · "), ""]
        text += (stream(model, server: server) + health(model, server: server)).map { "\($0.label): \($0.value)" }
        let engine = EngineDiagnostics.report()
        if !engine.isEmpty { text += ["", "Engine:", engine] }
        if let rounds = server?.probes, !rounds.isEmpty {
            text += ["", "Connection probes:"]
            for round in rounds {
                let picked = round.picked.map { "\($0.kindWord) \($0.displayAddress)" } ?? "none"
                text.append("\(round.started.formatted(date: .omitted, time: .standard)) · picked \(picked)")
                text += round.lines.map { "  \($0)" }
            }
        }
        if let hardware = model.capabilities.hardware { text += ["", "Hardware:"] + hardware.reportLines() }
        return text.joined(separator: "\n")
    }

    private static func mbps(_ bitsPerSecond: Double) -> String {
        "\((bitsPerSecond / 1_000_000).formatted(.number.precision(.fractionLength(1)))) Mbps"
    }

    /// VideoToolbox's gate for the stream's codec. Plex reports neither the sample entry nor the decoder
    /// configuration, so this is the per-codec answer the route was decided on.
    private static func decoder(for video: PlexStream, in decode: HardwareCapabilities.Decode) -> HardwareCapabilities.Support? {
        switch video.codec?.lowercased() {
        case "h264": decode.h264
        case "hevc", "h265":
            video.dolbyVision != nil ? decode.dolbyVisionHEVC : (video.bitDepth ?? 8) > 8 ? decode.hevc10 : decode.hevc
        case "av1": decode.av1
        case "vp9": decode.vp9
        case "mpeg2video", "mpeg2": decode.mpeg2
        case "prores": decode.prores
        default: nil
        }
    }

    private static func words(_ support: HardwareCapabilities.Support) -> String {
        switch support {
        case .hardware: "hardware decode"
        case .softwareOnly: "software decode"
        case .none: "no decoder"
        case .unknown: "decoder unknown"
        }
    }

    private static func summary(_ transcode: PlexTranscodeSession) -> String {
        var parts: [String] = []
        let decisions = [
            transcode.videoDecision.map { "video \($0)" },
            transcode.audioDecision.map { "audio \($0)" },
        ].compactMap { $0 }
        if !decisions.isEmpty { parts.append(decisions.joined(separator: ", ")) }
        if let speed = transcode.speed { parts.append("\(speed.formatted(.number.precision(.fractionLength(1))))×") }
        if transcode.throttled == true { parts.append("throttled") }
        if transcode.hardwareFullPipeline == true {
            parts.append("server GPU")
        } else if transcode.hardwareDecoding != nil || transcode.hardwareEncoding != nil {
            parts.append("server GPU in part")
        }
        return parts.isEmpty ? "running" : parts.joined(separator: " · ")
    }

    private static func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }

    /// The footprint iOS compares against the app's memory limit.
    private static func footprint() -> Int64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : nil
    }

    /// Seconds loaded past the playhead.
    private static func bufferAhead(_ item: AVPlayerItem) -> Double {
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
