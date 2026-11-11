import MarqueeCore
import SwiftUI

/// The player on the glasses (DESIGN §8.9): the picture fitted to the canvas, subtitles in the
/// profile's style, and while the controls show, the title above and the timeline below on glass.
struct GlassesPlayerView: View {
    let model: PlayerModel
    /// The thumb's scrub, while it holds one.
    let scrub: Scrub?
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    private static let screen = CGSize(width: GlassesCanvas.width, height: GlassesCanvas.height)

    var body: some View {
        let screen = Self.screen
        let rect = VideoFrame.rect(aspect: model.aspect, video: model.presentationSize, in: screen, displayScale: displayScale)
        let controls = model.chromeVisible || scrub != nil || !model.isPlaying
        ZStack(alignment: .topLeading) {
            theme.canvas
            if model.castDevice == nil {
                Group {
                    if let still = model.stillImage {
                        Image(uiImage: still)
                            .resizable()
                    } else {
                        VideoSurface(view: model.layerView)
                    }
                }
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                SubtitleOverlay(
                    model: model, picture: rect, screen: screen,
                    lift: controls ? GlassesCanvas.marginY + GlassesCanvas.heroHeight / 2 : 0,
                    look: session.settings.subtitleStyle
                )
            }
            if controls {
                osd
                    .transition(.opacity)
            }
            center
        }
        .frame(width: screen.width, height: screen.height)
        .animation(Motion.label, value: controls)
        .onAppear { model.viewportChanged(size: screen, scale: displayScale) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("glasses.player")
    }

    private var osd: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: GlassesCanvas.captionGap) {
                Text(model.title)
                    .glassesText(.title)
                    .foregroundStyle(theme.ink)
                if let line = model.subtitleLine {
                    Text(line)
                        .glassesText(.body)
                        .foregroundStyle(theme.ink2)
                }
            }
            .lineLimit(1)
            .padding(GlassesCanvas.tileGap)
            .background(theme.glass, in: RoundedRectangle(cornerRadius: GlassesCanvas.radius, style: .continuous))
            Spacer(minLength: 0)
            if let offer = offerText {
                Text(offer)
                    .glassesText(.headline)
                    .foregroundStyle(theme.accentInk)
                    .padding(.horizontal, GlassesCanvas.tileGap)
                    .frame(height: GlassesCanvas.option)
                    .background(theme.accent, in: Capsule())
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.bottom, GlassesCanvas.rowGap)
                    .accessibilityIdentifier("glasses.player.offer")
            }
            timeline
        }
        .padding(.horizontal, GlassesCanvas.marginX)
        .padding(.vertical, GlassesCanvas.marginY)
    }

    private var timeline: some View {
        let time = scrub?.time ?? model.time
        let fraction = model.duration > 0 ? min(max(time / model.duration, 0), 1) : 0
        return VStack(spacing: GlassesCanvas.titleGap) {
            GeometryReader { proxy in
                Capsule()
                    .fill(theme.trackOff)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(theme.accent)
                            .frame(width: proxy.size.width * fraction)
                    }
            }
            .frame(height: GlassesCanvas.barHeight)
            HStack {
                Text(Self.clock(time))
                    .foregroundStyle(scrub == nil ? theme.ink : theme.accentText)
                Spacer()
                Text("-" + Self.clock(max(model.duration - time, 0)))
                    .foregroundStyle(theme.ink2)
            }
            .glassesText(.body)
            .monospacedDigit()
        }
        .padding(GlassesCanvas.tileGap)
        .background(theme.glass, in: RoundedRectangle(cornerRadius: GlassesCanvas.radius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("glasses.player.timeline")
    }

    @ViewBuilder
    private var center: some View {
        Group {
            switch model.phase {
            case .failed(let message):
                GlassesNotice(symbol: "exclamationmark.triangle", title: "Couldn’t play", message: message)
            case .loading:
                spinner
            case .playing, .finished:
                if model.isBuffering {
                    spinner
                } else if let scrub {
                    Text(Self.clock(scrub.time))
                        .glassesText(.display)
                        .monospacedDigit()
                        .foregroundStyle(theme.ink)
                        .padding(GlassesCanvas.tileGap)
                        .background(theme.glass, in: RoundedRectangle(cornerRadius: GlassesCanvas.radius, style: .continuous))
                } else if !model.isPlaying {
                    Image(systemName: "pause.fill")
                        .font(.system(size: GlassesCanvas.glyph, weight: .semibold))
                        .foregroundStyle(theme.ink)
                        .frame(width: GlassesCanvas.glyph * 2, height: GlassesCanvas.glyph * 2)
                        .background(theme.glass, in: Circle())
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var spinner: some View {
        ProgressView()
            .controlSize(.extraLarge)
            .tint(theme.ink)
    }

    private var offerText: String? {
        switch model.offer {
        case .skipIntro: "Tap to Skip Intro"
        case .upNext(let next): "Tap for Next: \(next.title)"
        case .lowerQuality: "Tap to Play at Lower Quality"
        case nil: nil
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let whole = Int(max(seconds, 0))
        let (hours, minutes, rest) = (whole / 3600, whole / 60 % 60, whole % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }
}

/// Live TV on the glasses: the channel's picture, and while the controls show, what it airs.
struct GlassesLiveView: View {
    let model: LivePlaybackModel
    @Environment(\.theme) private var theme

    var body: some View {
        let channel = model.shown
        ZStack(alignment: .topLeading) {
            theme.canvas
            LiveVideoHost(view: model.source.videoView, fills: false)
                .frame(width: GlassesCanvas.width, height: GlassesCanvas.height)
            if model.chromeVisible || model.timeshift.isPaused {
                HStack(spacing: GlassesCanvas.tileGap) {
                    ChannelLogo(channel: channel, side: GlassesCanvas.logo)
                    VStack(alignment: .leading, spacing: GlassesCanvas.captionGap) {
                        Text("\(channel.number)  \(channel.title)")
                            .glassesText(.title)
                            .foregroundStyle(theme.ink)
                        Text(model.airings(on: channel).now?.title ?? " ")
                            .glassesText(.body)
                            .foregroundStyle(theme.ink2)
                        if let status = model.status {
                            Text(status)
                                .glassesText(.caption)
                                .foregroundStyle(theme.ink3)
                        }
                    }
                    .lineLimit(1)
                }
                .padding(GlassesCanvas.tileGap)
                .background(theme.glass, in: RoundedRectangle(cornerRadius: GlassesCanvas.radius, style: .continuous))
                .padding(.horizontal, GlassesCanvas.marginX)
                .padding(.vertical, GlassesCanvas.marginY)
                .transition(.opacity)
            }
            if model.state == .opening {
                ProgressView()
                    .controlSize(.extraLarge)
                    .tint(theme.ink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: GlassesCanvas.width, height: GlassesCanvas.height)
        .animation(Motion.label, value: model.chromeVisible)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("glasses.live")
    }
}
