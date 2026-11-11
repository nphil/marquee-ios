import AVFoundation
import MarqueeCore
import SwiftUI
import UIKit

/// The live player (docs/LIVE-TV.md §6.7-6.8). The picture runs behind everything. The controls are
/// drawn in the dark theme of the pair, as in the film player; the Quick Guide and the programme sheet
/// use the app's own theme.
struct LivePlayerView: View {
    let model: LivePlaybackModel
    let outerTheme: Theme
    let outerScheme: ColorScheme
    let close: () -> Void

    @Environment(AppSession.self) private var session
    @Environment(ThemeStore.self) private var themes
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControl
    @State private var drag: Drag?
    @GestureState private var dragging = false
    @State private var pull: CGFloat = 0
    /// How far the channel card leans with the finger while surfing.
    @State private var lean: CGFloat = 0
    @State private var details: ProgrammeSelection?
    @State private var size = CGSize(width: 2, height: 1)

    /// One swipe gesture, read the way it started.
    private enum Drag {
        /// Sideways: changes channel, one per `surfStep` from `origin`.
        case surf(origin: LiveChannel)
        /// Down: closes.
        case pull
        /// Up: opens the Quick Guide.
        case guide
    }

    /// The distance a sideways swipe travels per channel.
    private static let surfStep: CGFloat = 110

    private var showsChrome: Bool { model.chromeVisible || model.state != .playing }
    private var isWide: Bool { size.width > size.height }

    /// The room the Quick Guide's panel takes. The picture moves clear of it and keeps playing; the
    /// controls step aside until the guide closes.
    private var guideRoom: EdgeInsets {
        guard model.showsGuide else { return EdgeInsets() }
        return isWide
            ? EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: QuickGuide.width(in: size))
            : EdgeInsets(top: 0, leading: 0, bottom: QuickGuide.height(in: size), trailing: 0)
    }

    var body: some View {
        let theme = themes.selected(for: .dark)
            .adjusted(increaseContrast: contrast == .increased, reduceTransparency: reduceTransparency)
        ZStack {
            Color.black.ignoresSafeArea()
            picture
            if showsChrome && !model.showsGuide {
                LiveChrome(model: model, lean: lean, close: close)
                    .transition(.opacity)
            } else if !model.showsGuide, let status = model.status {
                LiveStatusLabel(text: status)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.horizontal, Space.inset)
                    .padding(.bottom, Space.s3)
                    .transition(.opacity)
            }
            if model.showsDiagnostics {
                DiagnosticsLine(text: model.source.diagnosticsLine ?? "\(model.channel.number) · no stream yet")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, showsChrome ? 76 : Space.s3)
                    .padding(.horizontal, Space.inset)
            }
            if model.showsGuide {
                QuickGuide(model: model, isWide: isWide) { details = $0 }
                    .environment(\.theme, outerTheme)
                    .environment(\.colorScheme, outerScheme)
                    .tint(outerTheme.accentText)
                    .transition(reduceMotion ? .opacity : .move(edge: isWide ? .trailing : .bottom))
            }
        }
        .animation(Motion.spring(reduceMotion: reduceMotion), value: model.showsGuide)
        .animation(.easeOut(duration: 0.18), value: model.status)
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            self.size = size
        }
        .environment(\.theme, theme)
        .preferredColorScheme(.dark)
        .statusBarHidden(!showsChrome)
        .persistentSystemOverlays(showsChrome ? .automatic : .hidden)
        .accessibilityAction(.escape) {
            if model.showsGuide { model.setGuide(false) } else { close() }
        }
        .accessibilityAction(.magicTap) { model.togglePlay() }
        .sheet(item: $details) { selection in
            ProgrammeSheet(store: model.store, selection: selection) { channel in
                details = nil
                model.setGuide(false)
                model.tune(channel)
            }
            .environment(\.theme, outerTheme)
            .tint(outerTheme.accentText)
            .preferredColorScheme(outerScheme)
        }
        .onChange(of: model.state) { model.stateChanged() }
        .onChange(of: voiceOver || switchControl, initial: true) { _, on in model.setKeepsChrome(on) }
        .onChange(of: dragging) { _, active in
            // A swipe the system cancels never reaches onEnded.
            if !active, drag != nil { settle(nil) }
        }
        .task {
            // The programme times and progress move every 30 s.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                model.store.tick()
            }
        }
        .onAppear {
            PlayerOrientation.opened(session.settings.videoOrientation)
            model.start()
        }
        .onDisappear {
            // However the player goes away, the tuner is freed.
            model.close()
            PlayerOrientation.closed()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("liveplayer")
    }

    // MARK: Picture

    private var picture: some View {
        ZStack {
            Color.black
            LiveVideoHost(view: model.source.videoView, fills: model.fillsScreen)
        }
        .ignoresSafeArea()
        // After ignoring the safe area, so the picture's region ends exactly where the panel begins.
        .padding(guideRoom)
        .offset(y: pull)
        .scaleEffect(1 - min(pull, 400) / 4000)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            Haptics.impact(.light)
            model.fillsScreen.toggle()
        }
        .onTapGesture { model.tapped() }
        .simultaneousGesture(swipe)
        .accessibilityHidden(true)
    }

    // MARK: Swipes

    /// Sideways surfs, down closes, up opens the Quick Guide (docs/LIVE-TV.md §6.7).
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 20)
            .updating($dragging) { _, active, _ in active = true }
            .onChanged { value in
                let move = value.translation
                if drag == nil {
                    if abs(move.width) > abs(move.height) {
                        drag = .surf(origin: model.shown)
                    } else {
                        drag = move.height > 0 ? .pull : .guide
                    }
                }
                switch drag {
                case .surf(let origin):
                    // A swipe to the left brings the next channel up, as a page turns.
                    let steps = Int((-move.width / Self.surfStep).rounded(.towardZero))
                    if let target = model.channel(steps, from: origin) { model.preview(target) }
                    lean = (move.width + CGFloat(steps) * Self.surfStep) * 0.4
                case .pull:
                    pull = max(0, move.height)
                case .guide, nil:
                    break
                }
            }
            .onEnded { value in settle(value) }
    }

    /// Finishes a swipe: a flick shorter than one step still moves one channel, and a pull past 140 pt
    /// or flung down closes.
    private func settle(_ value: DragGesture.Value?) {
        let ended = drag
        drag = nil
        switch ended {
        case .surf(let origin):
            if let value, model.surfing == nil, abs(value.predictedEndTranslation.width) > Self.surfStep,
               let target = model.channel(value.predictedEndTranslation.width < 0 ? 1 : -1, from: origin) {
                model.preview(target)
            }
            model.commitSurf()
            withAnimation(Motion.spring(reduceMotion: reduceMotion)) { lean = 0 }
        case .pull:
            if let value, pull > 140 || value.predictedEndTranslation.height > 360 {
                close()
            } else {
                withAnimation(Motion.spring(reduceMotion: reduceMotion)) { pull = 0 }
            }
        case .guide:
            if let value, value.translation.height < -60 || value.predictedEndTranslation.height < -200 {
                model.setGuide(true)
            }
        case nil:
            break
        }
    }
}

// MARK: - Chrome

/// The controls over the picture: close, the channel and AirPlay on top; channel down, skip back, pause, skip
/// forward and channel up in the middle, where the channel card shows while surfing or tuning; LIVE, the
/// programme's progress, Last and Guide at the bottom.
private struct LiveChrome: View {
    let model: LivePlaybackModel
    let lean: CGFloat
    let close: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The top row's bottom edge and the bottom row's top edge, on screen, for the scrims.
    @State private var topRow: CGFloat = 0
    @State private var bottomRow: CGFloat = .infinity

    var body: some View {
        VStack(spacing: 0) {
            top
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.frame(in: .global).maxY
                } action: { maxY in
                    topRow = maxY
                }
            Spacer(minLength: Space.s3)
            centre
            Spacer(minLength: Space.s3)
            bottom
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.frame(in: .global).minY
                } action: { minY in
                    bottomRow = minY
                }
        }
        .padding(.horizontal, Space.inset)
        .padding(.vertical, Space.s2)
        .background {
            Scrims(topRow: topRow, bottomRow: bottomRow)
                .allowsHitTesting(false)
        }
    }

    // MARK: Top

    private var top: some View {
        HStack(spacing: Space.s3) {
            Button(action: close) {
                Image(systemName: "xmark")
            }
            .buttonStyle(PlayerButtonStyle())
            .accessibilityLabel("Close")
            .accessibilityIdentifier("liveplayer.close")

            NowWatching(model: model)
                .frame(maxWidth: .infinity, alignment: .leading)

            AirPlayButton()
        }
    }

    // MARK: Centre

    @ViewBuilder
    private var centre: some View {
        if case .failed(let error) = model.state, model.surfing == nil {
            if model.tunerHolder != nil || error.isTunerBusy {
                TunerBusyCard(model: model, recording: model.tunerHolder, close: close)
            } else {
                FailureCard(message: error.description, close: close, retry: model.retry)
            }
        } else {
            HStack(spacing: Space.s4) {
                surfButton(by: -1)
                ZStack {
                    if showsCard {
                        let channel = model.shown
                        let airings = model.airings(on: channel)
                        ChannelCard(channel: channel, airing: airings.now, next: airings.next, now: model.moment(on: channel))
                            .id(channel.id)
                            .offset(x: lean)
                            .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.97)))
                    } else {
                        transport
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: showsCard)
                .animation(.easeOut(duration: 0.12), value: model.shown.id)
                surfButton(by: 1)
            }
        }
    }

    /// The card stands in for the transport while surfing, and while a channel tunes, which on the Plex
    /// path takes about 3 s.
    private var showsCard: Bool {
        model.surfing != nil || model.state == .opening
    }

    /// Back, pause and forward within the buffer (docs/LIVE-TV.md §6.7); forward only behind live.
    private var transport: some View {
        let seconds = Int(model.skipInterval)
        let timeshift = model.timeshift
        let playing = !(timeshift.isPaused || model.state == .idle)
        return HStack(spacing: Space.s3) {
            Button {
                Haptics.impact(.light)
                model.skip(by: -model.skipInterval)
            } label: {
                Image(systemName: "gobackward.\(seconds)")
            }
            .buttonStyle(PlayerButtonStyle())
            .disabled(!timeshift.canSkipBack)
            .accessibilityLabel("Skip back \(seconds) seconds")
            .accessibilityIdentifier("liveplayer.skipBack")

            Button {
                Haptics.impact(.medium)
                model.togglePlay()
            } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PlayerButtonStyle(prominent: true))
            .accessibilityLabel(playing ? "Pause" : "Play")
            .accessibilityIdentifier("liveplayer.playPause")

            Button {
                Haptics.impact(.light)
                model.skip(by: model.skipInterval)
            } label: {
                Image(systemName: "goforward.\(seconds)")
            }
            .buttonStyle(PlayerButtonStyle())
            .disabled(!timeshift.isBehindLive)
            .accessibilityLabel("Skip forward \(seconds) seconds")
            .accessibilityIdentifier("liveplayer.skipForward")
        }
    }

    private func surfButton(by steps: Int) -> some View {
        Button {
            model.surf(by: steps)
        } label: {
            Image(systemName: steps < 0 ? "backward.end.fill" : "forward.end.fill")
        }
        .buttonStyle(PlayerButtonStyle())
        .disabled(model.store.lineup.count < 2)
        .accessibilityLabel(steps < 0 ? "Previous channel" : "Next channel")
        .accessibilityValue(model.channel(steps, from: model.shown)?.label ?? "")
        .accessibilityIdentifier(steps < 0 ? "liveplayer.previous" : "liveplayer.next")
    }

    // MARK: Bottom

    private var bottom: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            if let status = model.status {
                LiveStatusLabel(text: status)
            }
            HStack(spacing: Space.s3) {
                LiveChip(timeshift: model.timeshift, isOn: model.state != .idle, goLive: model.goLive)
                programmeProgress
                    .frame(maxWidth: .infinity)
                Button {
                    model.lastChannel()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(PlayerButtonStyle())
                .disabled(model.previous == nil)
                .accessibilityLabel("Last channel")
                .accessibilityValue(model.previous?.label ?? "")
                .accessibilityIdentifier("liveplayer.last")

                Button {
                    model.setGuide(true)
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                }
                .buttonStyle(PlayerButtonStyle())
                .accessibilityLabel("Guide")
                .accessibilityIdentifier("liveplayer.guide")
            }
        }
    }

    /// Start, progress and end of the programme on screen, which behind live is the one the picture is from.
    @ViewBuilder
    private var programmeProgress: some View {
        let now = model.moment(on: model.channel)
        if let airing = model.airings(on: model.channel).now {
            HStack(spacing: Space.s2) {
                Text(LiveText.time(airing.start))
                ProgressLine(progress: airing.progress(at: now), height: 4, fill: theme.ink, track: theme.trackOff)
                    .frame(maxWidth: .infinity)
                Text(LiveText.time(airing.end))
            }
            .textRole(.caption)
            .monospacedDigit()
            .foregroundStyle(theme.ink)
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(LiveText.range(airing))
            .accessibilityValue(LiveText.left(airing, at: now))
        } else {
            Spacer(minLength: 0)
        }
    }
}

/// The channel playing and its programme. Touch and hold shows the stream's diagnostics; VoiceOver
/// users swipe up and down on it to change channel.
private struct NowWatching: View {
    let model: LivePlaybackModel
    @Environment(\.theme) private var theme

    var body: some View {
        let channel = model.channel
        let airing = model.airings(on: channel).now
        HStack(spacing: Space.s3) {
            ChannelLogo(channel: channel, side: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(airing?.title ?? channel.title)
                    .textRole(.headline)
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                Text(airing.map { "\(channel.label) · \(LiveText.range($0))" } ?? channel.label)
                    .textRole(.caption)
                    .monospacedDigit()
                    .foregroundStyle(theme.ink2)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.5) {
            Haptics.impact(.light)
            model.showsDiagnostics.toggle()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LiveText.spoken(channel, airing: airing, at: model.moment(on: channel), mark: nil))
        .accessibilityAddTraits(.isHeader)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.surf(by: 1)
            case .decrement: model.surf(by: -1)
            @unknown default: break
            }
        }
        .accessibilityAction(named: model.showsDiagnostics ? "Hide diagnostics" : "Show diagnostics") {
            model.showsDiagnostics.toggle()
        }
        .accessibilityIdentifier("liveplayer.channel")
    }
}

/// The channel surfing has reached, or the one tuning (docs/LIVE-TV.md §6.8): logo, number and call
/// sign, the programme with its progress, and what follows.
private struct ChannelCard: View {
    let channel: LiveChannel
    let airing: LiveAiring?
    let next: LiveAiring?
    let now: Date

    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        HStack(alignment: .top, spacing: Space.s3) {
            ChannelLogo(channel: channel, side: 56)
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(channel.label)
                    .textRole(.label)
                    .monospacedDigit()
                    .foregroundStyle(theme.ink2)
                    .lineLimit(1)
                Text(airing?.title ?? channel.title)
                    .textRole(.headline)
                    .foregroundStyle(theme.ink)
                    .lineLimit(typeSize.isAccessibilitySize ? 1 : 2)
                if let airing {
                    Text("\(LiveText.range(airing)) · \(LiveText.left(airing, at: now))")
                        .textRole(.caption)
                        .monospacedDigit()
                        .foregroundStyle(theme.ink2)
                        .lineLimit(1)
                    ProgressLine(progress: airing.progress(at: now), height: 3, fill: theme.ink)
                        .padding(.vertical, 2)
                }
                if let next, !typeSize.isAccessibilitySize {
                    Text("\(Text("Next").foregroundStyle(theme.ink3))  \(Text(LiveText.time(next.start)).monospacedDigit())  \(next.title)")
                        .textRole(.caption)
                        .foregroundStyle(theme.ink2)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Space.s4)
        .frame(maxWidth: 340)
        .background {
            ZStack {
                shape.fill(theme.roles.scrim.withAlpha(0.8).color)
                shape.fill(theme.glassRaised)
            }
        }
        .overlay { shape.strokeBorder(theme.edgeRaised, lineWidth: 1) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LiveText.spoken(channel, airing: airing, at: now, mark: nil))
        .accessibilityIdentifier("liveplayer.card")
    }
}

/// "● LIVE" on the scrim at live; behind live, a button that says how far behind and goes back to live.
private struct LiveChip: View {
    let timeshift: LiveTimeshift
    /// A stream is open; without one the dot greys.
    let isOn: Bool
    let goLive: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        if isOn, timeshift.isBehindLive {
            Button {
                Haptics.impact(.light)
                goLive()
            } label: {
                chip(behind: "−" + clockText(timeshift.behindLive))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Go to live")
            .accessibilityValue(Duration.seconds(Int(timeshift.behindLive)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide)) + " behind")
            .accessibilityIdentifier("liveplayer.goLive")
        } else {
            chip(behind: nil)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(isOn ? "Live" : "Not playing")
        }
    }

    private func chip(behind: String?) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isOn && behind == nil ? theme.live : theme.ink3)
                .frame(width: 8, height: 8)
            Text("LIVE")
                .font(.caption.weight(.bold))
                .tracking(0.6)
                .foregroundStyle(theme.ink)
            if let behind {
                Text(behind)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(theme.ink2)
            }
        }
        .padding(.horizontal, Space.s3)
        .frame(minHeight: 28)
        .background(theme.roles.scrim.withAlpha(0.8).color, in: Capsule())
        .fixedSize()
    }
}

/// One line about the stream, only when it says something: "Tuning 7.1", "Playing through Plex", a
/// refusal. Never a spinner over the picture.
private struct LiveStatusLabel: View {
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .textRole(.caption)
            .foregroundStyle(theme.ink)
            .lineLimit(2)
            .padding(.horizontal, Space.s3)
            .padding(.vertical, 6)
            .background(theme.roles.scrim.withAlpha(0.8).color, in: Capsule())
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityIdentifier("liveplayer.status")
    }
}

/// The tune's diagnostics line (docs/LIVE-TV.md §4.3), for receipts.
private struct DiagnosticsLine: View {
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(.caption.monospacedDigit())
            .foregroundStyle(theme.ink)
            .padding(.horizontal, Space.s3)
            .padding(.vertical, Space.s2)
            .background(theme.roles.scrim.withAlpha(0.8).color, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .textSelection(.enabled)
            .accessibilityIdentifier("liveplayer.diagnostics")
    }
}

/// Hosts a source's video view as it is and sets only how the picture fills the screen: the content
/// mode, and the video gravity of a player or sample-buffer layer behind it.
struct LiveVideoHost: UIViewRepresentable {
    let view: UIView
    let fills: Bool

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        container.clipsToBounds = true
        // Taps and swipes belong to the SwiftUI gestures over the picture.
        container.isUserInteractionEnabled = false
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if view.superview !== container {
            for old in container.subviews { old.removeFromSuperview() }
            view.frame = container.bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(view)
        }
        view.contentMode = fills ? .scaleAspectFill : .scaleAspectFit
        let gravity: AVLayerVideoGravity = fills ? .resizeAspectFill : .resizeAspect
        switch view.layer {
        case let layer as AVPlayerLayer:
            layer.videoGravity = gravity
        case let layer as AVSampleBufferDisplayLayer:
            layer.videoGravity = gravity
        default:
            break
        }
    }
}
