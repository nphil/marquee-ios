import AVFoundation
import MarqueeCore
import SwiftUI
import UIKit

/// Skip intro, Up Next and, after a long wait on the network, a lower quality (DESIGN §8.6, Offers),
/// bottom trailing and one at a time. They are not part of the auto-hiding chrome: they stay while their
/// marker or wait lasts and take touch while they show.
///
/// The player screen hands down `offer` and this view draws exactly that: no transition, no fade, no state
/// of its own. On an iPhone (iOS 27.2) a Skip Intro pill that left with an animation stayed on screen, and
/// took taps, after the skip had happened, while the player held no offer (0.1.49 with a removal
/// transition, 0.1.51 with a fade). The skip lands about 3 s into an episode, in the same moment as the
/// controls fade and the countdown ring goes; the simulator never showed it.
struct OfferView: View {
    let model: PlayerModel
    let offer: PlayerModel.Offer?

    var body: some View {
        content
            .id(PlayerModel.diagOffer(offer))
            // Whatever animation the change arrives with, the offer comes and goes at once.
            .transaction { $0.animation = nil }
            .onChange(of: offer, initial: true) { _, offer in
                Diag.event(.ui, "offer.view", ["offer": PlayerModel.diagOffer(offer)])
            }
    }

    @ViewBuilder
    private var content: some View {
        switch offer {
        case .skipIntro?:
            SkipIntroOffer(model: model)
        case .upNext(let next)?:
            UpNextCard(model: model, next: next)
        case .lowerQuality(let quality)?:
            Button {
                Haptics.impact(.light)
                model.playAtLowerQuality()
            } label: {
                HStack(spacing: Space.s2) {
                    Image(systemName: "dial.low")
                    Text("Play at Lower Quality")
                }
            }
            .buttonStyle(PlayerPillStyle(prominent: true))
            .accessibilityLabel("Play at lower quality")
            .accessibilityHint("Plays on at \(quality.title) until the player closes.")
            .accessibilityIdentifier("player.lowerQuality")
        case nil:
            EmptyView()
        }
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

/// A ring that fills over the countdown, from the top and clockwise. Core Animation runs it from the countdown's
/// start and length, so its end, at the moment of the skip, touches no SwiftUI animation: a SwiftUI timeline
/// drove it when the Skip Intro pill stayed on screen after the skip (`OfferView`).
struct CountdownRing: UIViewRepresentable {
    let countdown: PlayerModel.Countdown
    let tint: Color
    var lineWidth: CGFloat = 3
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeUIView(context: Context) -> CountdownRingView {
        CountdownRingView()
    }

    func updateUIView(_ view: CountdownRingView, context: Context) {
        view.show(countdown, tint: UIColor(tint), lineWidth: lineWidth, stepped: reduceMotion)
    }
}

final class CountdownRingView: UIView {
    private let track = CAShapeLayer()
    private let fill = CAShapeLayer()
    private var countdown: PlayerModel.Countdown?
    /// Reduce Motion: the ring moves once a second rather than continuously.
    private var stepped = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
        for ring in [track, fill] {
            ring.fillColor = nil
            ring.lineCap = .round
            layer.addSublayer(ring)
        }
        // Core Animation drops a layer's animations while the app is in the background.
        NotificationCenter.default.addObserver(
            self, selector: #selector(restart), name: UIApplication.willEnterForegroundNotification, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ countdown: PlayerModel.Countdown, tint: UIColor, lineWidth: CGFloat, stepped: Bool) {
        track.strokeColor = tint.withAlphaComponent(0.35).cgColor
        fill.strokeColor = tint.cgColor
        if track.lineWidth != lineWidth {
            track.lineWidth = lineWidth
            fill.lineWidth = lineWidth
            setNeedsLayout()
        }
        guard countdown != self.countdown || stepped != self.stepped else { return }
        self.countdown = countdown
        self.stepped = stepped
        restart()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = max(0, min(bounds.width, bounds.height) / 2 - fill.lineWidth / 2)
        let path = UIBezierPath(
            arcCenter: CGPoint(x: bounds.midX, y: bounds.midY), radius: radius,
            startAngle: -.pi / 2, endAngle: .pi * 1.5, clockwise: true
        ).cgPath
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for ring in [track, fill] {
            ring.frame = bounds
            ring.path = path
        }
        CATransaction.commit()
    }

    /// Fills from where the countdown is now to the end over the time it has left; full once that is over.
    @objc private func restart() {
        fill.removeAnimation(forKey: "countdown")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.strokeEnd = 1
        CATransaction.commit()
        guard let countdown, countdown.length > 0 else { return }
        let elapsed = max(0, Date.now.timeIntervalSince(countdown.start))
        let remaining = countdown.length - elapsed
        guard remaining > 0 else { return }
        let from = elapsed / countdown.length
        let animation: CAAnimation
        if stepped {
            // Discrete steps on each whole second of the count; the key times run one past the values.
            let steps = CAKeyframeAnimation(keyPath: "strokeEnd")
            steps.calculationMode = .discrete
            var values = [from]
            var times = [NSNumber(value: 0)]
            var second = elapsed.rounded(.down) + 1
            while second < countdown.length {
                values.append(second / countdown.length)
                times.append(NSNumber(value: (second - elapsed) / remaining))
                second += 1
            }
            times.append(1)
            steps.values = values
            steps.keyTimes = times
            animation = steps
        } else {
            let sweep = CABasicAnimation(keyPath: "strokeEnd")
            sweep.fromValue = from
            sweep.toValue = 1
            sweep.timingFunction = CAMediaTimingFunction(name: .linear)
            animation = sweep
        }
        animation.duration = remaining
        fill.add(animation, forKey: "countdown")
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

/// Find Subtitles' progress and outcome: up while the search runs, then for six seconds.
struct SubtitleSearchBanner: View {
    let finder: SubtitleFinder
    @Environment(\.theme) private var theme
    @State private var fresh = true

    var body: some View {
        ZStack {
            if let status = finder.status, status.tone == .busy || fresh {
                HStack(spacing: Space.s3) {
                    icon(status.tone)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(status.title)
                            .textRole(.label)
                            .foregroundStyle(theme.ink)
                        Text(status.detail)
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
                .accessibilityIdentifier("player.subtitleSearch")
            }
        }
        .animation(.easeOut(duration: 0.18), value: finder.status)
        .animation(.easeOut(duration: 0.18), value: fresh)
        .task(id: finder.status) {
            fresh = true
            guard let status = finder.status, status.tone != .busy else { return }
            try? await Task.sleep(for: .seconds(6))
            fresh = false
        }
    }

    @ViewBuilder
    private func icon(_ tone: SubtitleFinder.Status.Tone) -> some View {
        switch tone {
        case .busy:
            ProgressView()
                .tint(theme.info)
        case .found:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(theme.positive)
        case .missing:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(theme.warning)
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

/// Over the black picture while the video plays on an AirPlay screen or a Chromecast.
struct ExternalPlaybackView: View {
    /// The Chromecast playing the video; nil while AirPlay does.
    var castName: String?
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: Space.s3) {
            Group {
                if castName != nil {
                    CastMark(connected: true)
                        .frame(width: 56, height: 56)
                } else {
                    Image(systemName: "airplayvideo")
                        .font(.system(size: 56, weight: .regular))
                }
            }
            .foregroundStyle(theme.ink2)
            Text("Playing on \(castName ?? routeName)")
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
