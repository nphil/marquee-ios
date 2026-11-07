import AVFoundation
import MarqueeCore
import SwiftUI

/// Skip intro and Up Next (DESIGN §8.6, Offers), bottom trailing and one at a time. They are not part of
/// the auto-hiding chrome: they stay while their marker runs and take touch while they show.
struct OfferView: View {
    let model: PlayerModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            switch model.offer {
            case .skipIntro?:
                SkipIntroOffer(model: model)
                    .transition(transition)
            case .upNext(let next)?:
                UpNextCard(model: model, next: next)
                    .transition(transition)
            case nil:
                EmptyView()
            }
        }
    }

    /// In over 220 ms travelling 16 pt, out over 180 ms; opacity alone under Reduce Motion (DESIGN §9).
    private var transition: AnyTransition {
        let insertion: AnyTransition = reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 16))
        return .asymmetric(
            insertion: insertion.animation(.easeOut(duration: reduceMotion ? 0.12 : 0.22)),
            removal: .opacity.animation(.easeOut(duration: 0.18))
        )
    }
}

/// The accent pill, 56 pt tall; with a ring while auto-skip counts down, and "Watch Intro" beside it to
/// stop the count for this episode.
private struct SkipIntroOffer: View {
    let model: PlayerModel
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: Space.s3) {
            if model.countdown != nil {
                Button("Watch Intro") {
                    model.watchIntro()
                }
                .buttonStyle(PlayerPillStyle())
                .accessibilityIdentifier("player.watchIntro")
            }
            Button {
                Haptics.impact(.light)
                model.skipIntro()
            } label: {
                HStack(spacing: Space.s2) {
                    if let countdown = model.countdown {
                        CountdownRing(countdown: countdown, tint: theme.accentInk, lineWidth: 2.5)
                            .frame(width: 20, height: 20)
                    } else {
                        Image(systemName: "forward.fill")
                    }
                    Text("Skip Intro")
                }
            }
            .buttonStyle(PlayerPillStyle(prominent: true))
            .accessibilityLabel("Skip intro")
            .accessibilityHint(model.countdown != nil ? "Skips by itself in a few seconds." : "")
            .accessibilityIdentifier("player.skipIntro")
        }
    }
}

/// An opaque card at the credits: the next episode's still and name, a play button ringed by the
/// countdown, and "Watch Credits" to stay.
private struct UpNextCard: View {
    let model: PlayerModel
    let next: PlexMetadata
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: Space.s3) {
            PlexArtView(path: next.thumb ?? next.art, size: CGSize(width: 112, height: 63), placeholder: "tv")
                .frame(width: 112, height: 63)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Up Next")
                    .textRole(.caption)
                    .foregroundStyle(theme.ink2)
                Text(line)
                    .textRole(.headline)
                    .foregroundStyle(theme.ink)
                    .lineLimit(2)
                Button("Watch Credits") {
                    model.watchCredits()
                }
                .buttonStyle(.plain)
                .textRole(.label)
                .foregroundStyle(theme.accentText)
                .frame(minHeight: Size.target)
                .contentShape(Rectangle())
                .accessibilityIdentifier("player.watchCredits")
            }
            .frame(maxWidth: 220, alignment: .leading)
            Button {
                Haptics.impact(.light)
                model.next()
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(theme.accentInk)
                    .frame(width: 56, height: 56)
                    .background(theme.accent, in: Circle())
                    .overlay {
                        if let countdown = model.countdown {
                            CountdownRing(countdown: countdown, tint: theme.accentInk, lineWidth: 3)
                                .padding(4)
                        }
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(PressStyle(shape: Circle()))
            .accessibilityLabel("Play \(line)")
            .accessibilityIdentifier("player.playNext")
        }
        .padding(Space.s3)
        .background(theme.sheet, in: RoundedRectangle(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(theme.edge, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Up next")
    }

    private var line: String {
        [next.episodeCode, next.title].compactMap { $0 }.joined(separator: " · ")
    }
}

/// A ring that fills over the countdown.
struct CountdownRing: View {
    let countdown: PlayerModel.Countdown
    let tint: Color
    var lineWidth: CGFloat = 3
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : nil)) { context in
            let elapsed = context.date.timeIntervalSince(countdown.start)
            let fraction = countdown.length > 0 ? min(1, max(0, elapsed / countdown.length)) : 1
            ZStack {
                Circle()
                    .stroke(tint.opacity(0.35), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .accessibilityHidden(true)
    }
}

/// The player's text buttons: an accent pill for the main action, glass for the rest; 56 pt tall.
struct PlayerPillStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        PlayerPillLabel(configuration: configuration, prominent: prominent)
    }
}

private struct PlayerPillLabel: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        configuration.label
            .textRole(.headline)
            // One line at standard sizes, where every pill fits: offered less as the offer appeared,
            // "Skip Intro" wrapped inside the pill. Accessibility sizes may need the second line.
            .fixedSize(horizontal: !typeSize.isAccessibilitySize, vertical: false)
            .foregroundStyle(prominent ? theme.accentInk : theme.ink)
            .padding(.horizontal, Space.s5)
            .frame(minHeight: 56)
            .background(prominent ? theme.accent : theme.glass, in: Capsule())
            .overlay {
                if !prominent { Capsule().strokeBorder(theme.edge, lineWidth: 1) }
            }
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.5)
            .pressed(configuration.isPressed, in: Capsule())
    }
}

/// Press feedback alone, for buttons that draw their own label.
private struct PressStyle<S: Shape>: ButtonStyle {
    let shape: S

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.pressed(configuration.isPressed, in: shape)
    }
}

// MARK: - States

/// The end of an item: the last frame and the chrome stay (DESIGN §8.6).
struct FinishedCard: View {
    let model: PlayerModel
    let close: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: Space.s4) {
            Text("Finished")
                .textRole(.title)
                .foregroundStyle(theme.ink)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: Space.s3) {
                Button {
                    model.replay()
                } label: {
                    Label("Replay", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(PlayerPillStyle(prominent: true))
                .accessibilityIdentifier("player.replay")
                if model.hasNext {
                    Button {
                        model.next()
                    } label: {
                        Label("Next Episode", systemImage: "forward.end.fill")
                    }
                    .buttonStyle(PlayerPillStyle())
                    .accessibilityIdentifier("player.finishedNext")
                }
                Button("Close", action: close)
                    .buttonStyle(PlayerPillStyle())
            }
        }
        .accessibilityIdentifier("player.finished")
    }
}

/// Playback failed (DESIGN §11): it stays in the player with the reason, Retry and Close.
struct FailureCard: View {
    let message: String
    let close: () -> Void
    let retry: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: Space.s3) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(theme.warning)
                .accessibilityHidden(true)
            Text("Can't play this")
                .textRole(.title)
                .foregroundStyle(theme.ink)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .textRole(.body)
                .foregroundStyle(theme.ink2)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            HStack(spacing: Space.s3) {
                Button("Retry", action: retry)
                    .buttonStyle(PlayerPillStyle(prominent: true))
                    .accessibilityIdentifier("player.retry")
                Button("Close", action: close)
                    .buttonStyle(PlayerPillStyle())
            }
            .padding(.top, Space.s2)
        }
        .frame(maxWidth: 480)
        .onAppear { Haptics.error() }
        .accessibilityIdentifier("player.failed")
    }
}

/// Playback moved from the phone to the server; shown for six seconds, then with the chrome. The error
/// behind it stays in Playback info.
struct FallbackBanner: View {
    let model: PlayerModel
    @Environment(\.theme) private var theme
    @State private var fresh = true

    var body: some View {
        ZStack {
            if model.fallback != nil, fresh || model.chromeVisible {
                HStack(spacing: Space.s3) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(theme.info)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Playing through the server")
                            .textRole(.label)
                            .foregroundStyle(theme.ink)
                        Text("This file didn't play on the phone itself.")
                            .textRole(.caption)
                            .foregroundStyle(theme.ink2)
                            .lineLimit(2)
                    }
                }
                .padding(.horizontal, Space.s4)
                .padding(.vertical, Space.s3)
                .background(theme.glassRaised, in: RoundedRectangle(cornerRadius: Radius.row))
                .overlay(RoundedRectangle(cornerRadius: Radius.row).strokeBorder(theme.edge, lineWidth: 1))
                .frame(maxWidth: 520)
                .transition(.opacity)
                .accessibilityElement(children: .combine)
            }
        }
        .animation(.easeOut(duration: 0.18), value: fresh || model.chromeVisible)
        .task(id: model.fallback) {
            fresh = true
            try? await Task.sleep(for: .seconds(6))
            fresh = false
        }
    }
}

/// Moves the subtitles against the picture, a tenth of a second a step, for the playing item only. It sits
/// on the side of the picture away from the subtitles, so the line being matched stays in sight.
struct TimingCapsule: View {
    let model: PlayerModel
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            step(-1, symbol: "minus", label: "Earlier")
            Text(model.timingText)
                .textRole(.label)
                .monospacedDigit()
                .foregroundStyle(theme.ink)
                .contentTransition(.numericText(value: model.timing.seconds))
                .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: model.timing)
                .lineLimit(1)
                .frame(minWidth: 172)
                .accessibilityHidden(true)
            step(1, symbol: "plus", label: "Later")
            Rectangle()
                .fill(theme.edge)
                .frame(width: 1, height: 28)
                .padding(.horizontal, Space.s1)
            glyph("arrow.counterclockwise", label: "Original Timing", id: "reset") { model.resetTiming() }
                .disabled(model.timing.isOriginal)
            glyph("xmark", label: "Done", id: "done") { model.closeTiming() }
        }
        .padding(.horizontal, Space.s1)
        .frame(minHeight: 56)
        .background(theme.glassRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(theme.edge, lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Subtitle Timing")
        .accessibilityAction(.escape) { model.closeTiming() }
        .accessibilityIdentifier("player.timing")
    }

    private func step(_ direction: Int, symbol: String, label: String) -> some View {
        glyph(symbol, label: label, id: direction > 0 ? "later" : "earlier") { model.nudgeTiming(direction) }
            .buttonRepeatBehavior(.enabled)
            .disabled(!model.canNudgeTiming(direction))
            .accessibilityValue(model.timingText)
    }

    private func glyph(_ symbol: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: Size.target, height: Size.target)
                .contentShape(Circle())
        }
        .buttonStyle(TimingGlyphStyle())
        .accessibilityLabel(label)
        .accessibilityIdentifier("player.timing.\(id)")
    }
}

private struct TimingGlyphStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TimingGlyph(configuration: configuration)
    }
}

private struct TimingGlyph: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .foregroundStyle(theme.ink)
            .opacity(isEnabled ? 1 : 0.35)
            .pressed(configuration.isPressed, in: Circle())
    }
}

/// The running total of quick skips, flashed on the side that was tapped.
struct SkipFlashView: View {
    let flash: PlayerModel.SkipFlash
    @Environment(\.theme) private var theme
    @State private var visible = false

    var body: some View {
        HStack(spacing: 0) {
            slot(shows: !flash.forward)
            Color.clear.frame(maxWidth: .infinity)
            slot(shows: flash.forward)
        }
        .opacity(visible ? 1 : 0)
        .task(id: flash.serial) {
            withAnimation(.easeOut(duration: 0.12)) { visible = true }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) { visible = false }
        }
        .accessibilityHidden(true)
    }

    private func slot(shows: Bool) -> some View {
        ZStack {
            if shows {
                VStack(spacing: Space.s1) {
                    Image(systemName: flash.forward ? "goforward" : "gobackward")
                        .font(.system(size: 30, weight: .semibold))
                    Text("\(flash.seconds) seconds")
                        .monospacedDigit()
                        .textRole(.caption)
                }
                .foregroundStyle(theme.ink)
                .frame(width: 112, height: 112)
                .background(theme.glass, in: Circle())
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Over the black picture while the video plays on an AirPlay screen.
struct ExternalPlaybackView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: Space.s3) {
            Image(systemName: "airplayvideo")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(theme.ink2)
            Text("Playing on \(routeName)")
                .textRole(.headline)
                .foregroundStyle(theme.ink)
                .multilineTextAlignment(.center)
        }
        .padding(Space.inset)
        .accessibilityElement(children: .combine)
    }

    private var routeName: String {
        AVAudioSession.sharedInstance().currentRoute.outputs.first { $0.portType == .airPlay }?.portName ?? "AirPlay"
    }
}
