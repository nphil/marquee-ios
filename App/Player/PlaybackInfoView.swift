import MarqueeCore
import SwiftUI
import UIKit

/// Playback info from the More menu: how the item plays and why, and the file's tracks. Codec names
/// appear here and nowhere else (DESIGN §8.6).
struct PlaybackInfoView: View {
    let model: PlayerModel
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        List {
            Section("Playing") {
                row("Route", model.route?.title ?? "Choosing…")
                if let route = model.route, !route.reasons.isEmpty {
                    row("Why", route.reasons.map(\.description).joined(separator: "\n"))
                }
                if let fallback = model.fallback {
                    row("Fallback", fallback)
                }
            }
            .listRowBackground(theme.sheet)

            if let video = model.part?.videoStream {
                Section("Video") {
                    row("Format", video.formatSummary)
                    if let size = video.sizeSummary { row("Size", size) }
                    if let rate = video.frameRate { row("Frame Rate", "\(rate.formatted(.number.precision(.fractionLength(0...3)))) fps") }
                    row("Dynamic Range", video.dynamicRange)
                    if let reencodes = model.route?.reencodesVideo, reencodes { row("Delivery", "Converted by the server") }
                }
                .listRowBackground(theme.sheet)
            }

            if let audio = model.audio {
                Section("Audio") {
                    row("Track", audio.label)
                    row("Format", [audio.codec.uppercased(), audio.channels.map(channelWords)].compactMap { $0 }.joined(separator: ", "))
                    if model.route?.audioIsStandIn == true { row("Note", "Stands in for a track the phone can't play") }
                    if model.route?.convertsAudio == true { row("Delivery", "Converted for playback") }
                }
                .listRowBackground(theme.sheet)
            }

            Section("Subtitles") {
                row("Track", model.subtitle?.track?.label ?? (model.subtitleChoice == .onScreenTextOnly ? "On-screen text only" : "Off"))
                if let route = model.route, let delivery = route.subtitle.words {
                    row("Delivery", delivery)
                }
                if let problem = model.subtitleProblem {
                    row("Problem", problem)
                }
            }
            .listRowBackground(theme.sheet)

            if let media = model.media {
                Section("File") {
                    if let container = model.part?.container ?? media.container { row("Container", container.uppercased()) }
                    if let bitrate = media.bitrate { row("Bitrate", "\((Double(bitrate) / 1000).formatted(.number.precision(.fractionLength(1)))) Mbps") }
                    if let size = model.part?.size { row("Size", Int64(size).formatted(.byteCount(style: .file))) }
                }
                .listRowBackground(theme.sheet)
            }

            Section {
                Button {
                    Task {
                        let server = await PlayerStats.Server.read(model)
                        UIPasteboard.general.string = PlayerStats.report(model, server: server)
                        Haptics.impact(.light)
                        AccessibilityNotification.Announcement("Copied").post()
                        copied = true
                    }
                } label: {
                    // A Label in this row drew its title cut off mid-word at accessibility text sizes.
                    HStack(spacing: Space.s3) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .accessibilityHidden(true)
                        Text(copied ? "Copied" : "Copy Diagnostics")
                    }
                    .foregroundStyle(theme.accentText)
                }
                .textRole(.body)
                .accessibilityIdentifier("playbackInfo.copy")
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("The route, the stream's numbers, the engine's recent measurements and this iPhone's decoders, as text for a bug report.")
                    .foregroundStyle(theme.ink2)
            }
            .listRowBackground(theme.sheet)
        }
        .themedList(theme)
        .navigationTitle("Playback Info")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .accessibilityIdentifier("player.info")
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .foregroundStyle(theme.ink2)
                .multilineTextAlignment(.trailing)
        }
        .textRole(.body)
    }

    private func channelWords(_ channels: Int) -> String {
        switch channels {
        case 1: "Mono"
        case 2: "Stereo"
        case 6: "5.1"
        case 8: "7.1"
        default: "\(channels) channels"
        }
    }
}

extension PlaybackRoute {
    /// The route in a few words, for Playback Info and the stats overlay.
    var title: String {
        switch kind {
        case .directPlay: "Direct Play"
        case .remux: "Repackaged on the phone"
        case .serverTranscode: reencodesVideo ? "Converted by the server" : "Repackaged by the server"
        }
    }
}

extension SubtitleDelivery {
    var words: String? {
        switch self {
        case .none: nil
        case .sidecar: "Drawn by Marquee"
        case .inStream: "In the video stream"
        case .burnedIn: "Burned in by the server"
        case .notShown: "Not shown"
        }
    }
}

extension PlexStream {
    /// "HEVC Main 10, level 5.1".
    var formatSummary: String {
        var parts = [codec?.uppercased() ?? "Unknown"]
        if let profile { parts.append(profile.capitalized) }
        var text = parts.joined(separator: " ")
        // Plex passes the stream's level number through: 51 for H.264 5.1, 153 (30 × 5.1) for HEVC.
        if let level {
            let number = Double(level) / (codec == "hevc" ? 30 : 10)
            text += ", level \(number.formatted(.number.precision(.fractionLength(0...1))))"
        }
        return text
    }

    /// "3840 × 2160, 10-bit".
    var sizeSummary: String? {
        guard let width, let height else { return nil }
        return ["\(width) × \(height)", bitDepth.map { "\($0)-bit" }].compactMap { $0 }.joined(separator: ", ")
    }

    var dynamicRange: String {
        if let dolbyVision { return "Dolby Vision profile \(dolbyVision.profile)" }
        switch colorTrc {
        case "smpte2084": return "HDR10"
        case "arib-std-b67": return "HLG"
        default: return "SDR"
        }
    }
}
