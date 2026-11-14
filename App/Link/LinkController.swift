import MarqueeCore
import SwiftUI
import UIKit

/// This phone as the remote for a linked phone's big screen: the eyes-free remote's target, sending each
/// input over the link. Its cue comes back with the other phone's answer (`answersLater`).
@MainActor
final class LinkRemote: RemoteTarget {
    let peer: LinkID
    let tiltEnabled: Bool
    var onCue: ((HapticCue) -> Void)?
    private unowned let link: PhoneLink
    private let haptics = RemoteHaptics()
    private var clock = ClockOffset()
    private var pinger: Task<Void, Never>?

    init(link: PhoneLink, peer: LinkID, tiltEnabled: Bool) {
        self.link = link
        self.peer = peer
        self.tiltEnabled = tiltEnabled
        // A few quick pings settle the offset; after that it only needs keeping up with drift.
        pinger = Task { [weak self] in
            var count = 0
            while !Task.isCancelled {
                guard let self else { return }
                self.link.send(.ping(sent: ProcessInfo.processInfo.systemUptime))
                count += 1
                try? await Task.sleep(for: count < 6 ? .milliseconds(250) : .seconds(3))
            }
        }
    }

    var phoneName: String { link.linkedPhone(peer)?.name ?? "iPhone" }
    var isConnected: Bool { link.presence[peer] != nil }
    var status: LinkStatus? { link.presence[peer]?.status }
    var statusAt: Date { link.presence[peer]?.statusAt ?? .now }

    /// Sends an input stamped with when the touch happened, by the other phone's clock once a ping has told
    /// the two apart, so it can tell how late the input arrived.
    func handle(_ input: GlassesInput) -> HapticCue? {
        let touched = input.touchTime ?? ProcessInfo.processInfo.systemUptime
        link.send(.input(LinkInput(input), at: clock.hostTime(touched)))
        return nil
    }

    func clockAnswered(sent: Double, host: Double) {
        clock.add(sent: sent, remote: host, received: ProcessInfo.processInfo.systemUptime)
    }

    /// Stops asking the other phone for its clock; the remote is going away.
    func stop() {
        pinger?.cancel()
    }

    func command(_ command: LinkCommand) {
        link.send(.command(command))
    }

    /// The other phone's volume, 0 to 1, as it last said.
    var volume: Double? { status?.volume }

    func stepVolume(_ step: Int) -> HapticCue {
        let limit = volume.map { LinkVolume.hitsLimit($0, step: step) } ?? false
        link.send(.command(.volume(step: step)))
        return limit ? .volumeLimit : .volumeStep
    }

    /// A step from the buttons on the screen or on the phone's side, with its own haptic.
    func press(volume step: Int) {
        haptics.play(stepVolume(step))
    }

    var answersLater: Bool { true }
    var focusTitle: String { status?.focus ?? phoneName }
    var focusDetail: String? { status?.focusDetail }
    var symbol: String { status?.screen == .tv ? "tv" : "eyeglasses" }
    var inPlayer: Bool { status?.inPlayer ?? false }
    /// Whether the other phone scrubs is not sent; holding in its player starts one, and tilt's nudges
    /// outside a scrub do nothing there.
    var isScrubbing: Bool { inPlayer }
    var leaveTitle: String { "Done" }
    var leaveLabel: String { "Close" }
    var leaveSymbol: String { "xmark" }

    /// Down in the other phone's player opens its tracks, as on its own remote.
    func openOptions() {
        link.send(.input(.move(.down)))
    }

    func leave() {
        link.stopControlling()
    }

    func openSettings() {
        link.openSettings()
    }
}

/// The controlling phone's remote: a window over the app, like the glasses' remote, but not dimmed, as
/// the player controls are read on it.
@MainActor
final class LinkControllerWindow {
    private var window: UIWindow?
    private let buttons = VolumeButtons()

    func show(remote: LinkRemote, session: AppSession, store: ThemeStore) {
        guard window == nil, let scene = GlassesCenter.phoneScene() else { return }
        let host = LinkRemoteHost(rootView: LinkControlRoot(remote: remote, session: session, store: store))
        host.overrideUserInterfaceStyle = .dark
        host.view.accessibilityViewIsModal = true
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        window.rootViewController = host
        window.makeKeyAndVisible()
        self.window = window
        UIAccessibility.post(notification: .screenChanged, argument: host.view)
        buttons.start { [weak remote] step in remote?.press(volume: step) }
    }

    func hide() {
        guard let window else { return }
        buttons.stop()
        window.isHidden = true
        self.window = nil
        window.windowScene?.windows.first { !$0.isHidden }?.makeKey()
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }
}

/// Hides the status bar and home indicator, and holds the screen edges for the remote's own gestures.
private final class LinkRemoteHost: UIHostingController<LinkControlRoot> {
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
}

/// The remote follows the active theme's dark side, as the glasses' remote does.
struct LinkControlRoot: View {
    let remote: LinkRemote
    let session: AppSession
    let store: ThemeStore

    var body: some View {
        LinkControlView(remote: remote)
            .environment(session)
            .environment(\.theme, store.selected(for: .dark))
            .environment(\.colorScheme, .dark)
    }
}

/// The eyes-free remote while the other phone drives a big screen, a few player controls while it plays
/// on its own screen, else what the remote waits for.
struct LinkControlView: View {
    let remote: LinkRemote
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack(alignment: .top) {
            theme.canvas
                .ignoresSafeArea()
            if remote.status?.screen != nil {
                GlassesRemoteView(target: remote, showsStrip: false)
            } else if let playing = remote.status?.nowPlaying {
                LinkPlayerControls(remote: remote, playing: playing)
            } else {
                LinkWaitingView(remote: remote)
            }
            header
        }
    }

    private var header: some View {
        HStack(spacing: Space.s3) {
            VStack(alignment: .leading, spacing: Space.s1) {
                Text("Controlling")
                    .textRole(.caption)
                    .foregroundStyle(theme.ink3)
                Text(remote.phoneName)
                    .textRole(.headline)
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .allowsHitTesting(false)
            Spacer(minLength: Space.s3)
            Button { remote.openSettings() } label: {
                Label("Settings", systemImage: "gearshape").labelStyle(.iconOnly)
            }
            .buttonStyle(.pill)
            .accessibilityIdentifier("link.settings")
            Button("Done") { remote.leave() }
                .buttonStyle(.pill)
                .accessibilityIdentifier("link.done")
        }
        .padding(.horizontal, Space.inset)
        .padding(.top, Space.s3)
    }
}

/// The other phone's own player: play and pause, skip, next and subtitles, with where it is.
private struct LinkPlayerControls: View {
    let remote: LinkRemote
    let playing: LinkNowPlaying
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme

    var body: some View {
        let seconds = session.settings.skipInterval
        VStack(spacing: Space.s6) {
            Spacer()
            VStack(spacing: Space.s2) {
                Text(playing.title)
                    .textRole(.title)
                    .foregroundStyle(theme.ink)
                    .lineLimit(3)
                    .accessibilityIdentifier("link.title")
                if let detail = playing.detail {
                    Text(detail)
                        .textRole(.body)
                        .foregroundStyle(theme.ink2)
                        .lineLimit(2)
                }
            }
            .multilineTextAlignment(.center)
            if playing.duration > 0 { progress }
            HStack(spacing: Space.s8) {
                Button {
                    Haptics.impact(.light)
                    remote.command(.skip(seconds: -Double(seconds)))
                } label: {
                    Image(systemName: "gobackward.\(seconds)")
                }
                .buttonStyle(PlayerButtonStyle())
                .accessibilityLabel("Skip back \(seconds) seconds")
                .accessibilityIdentifier("link.skipBack")

                Button {
                    Haptics.impact(.medium)
                    remote.command(.playPause)
                } label: {
                    Image(systemName: playing.isPlaying ? "pause.fill" : "play.fill")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(PlayerButtonStyle(prominent: true))
                .accessibilityLabel(playing.isPlaying ? "Pause" : "Play")
                .accessibilityIdentifier("link.playPause")

                Button {
                    Haptics.impact(.light)
                    remote.command(.skip(seconds: Double(seconds)))
                } label: {
                    Image(systemName: "goforward.\(seconds)")
                }
                .buttonStyle(PlayerButtonStyle())
                .accessibilityLabel("Skip forward \(seconds) seconds")
                .accessibilityIdentifier("link.skipForward")
            }
            HStack(spacing: Space.s8) {
                if !playing.subtitles.isEmpty { subtitles }
                if playing.hasNext {
                    Button {
                        Haptics.impact(.light)
                        remote.command(.next)
                    } label: {
                        Image(systemName: "forward.end.fill")
                    }
                    .buttonStyle(PlayerButtonStyle())
                    .accessibilityLabel("Next")
                    .accessibilityIdentifier("link.next")
                }
            }
            volumeRow
            Spacer()
        }
        .padding(Space.inset)
        .frame(maxWidth: .infinity)
    }

    /// Quieter and louder with the other phone's level between; this phone's own volume buttons do the same.
    private var volumeRow: some View {
        let level = remote.volume
        return HStack(spacing: Space.s4) {
            Button {
                remote.press(volume: -1)
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(PlayerButtonStyle())
            .accessibilityLabel("Volume down")
            .accessibilityIdentifier("link.volumeDown")

            VStack(spacing: Space.s1) {
                Image(systemName: level == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(theme.ink3)
                ProgressView(value: level ?? 0)
                    .tint(theme.accent)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Volume")
            .accessibilityValue(level.map { "\(Int(($0 * 100).rounded())) percent" } ?? "Unknown")
            .accessibilityIdentifier("link.volume")

            Button {
                remote.press(volume: 1)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(PlayerButtonStyle())
            .accessibilityLabel("Volume up")
            .accessibilityIdentifier("link.volumeUp")
        }
    }

    private var progress: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let position = playing.position(after: context.date.timeIntervalSince(remote.statusAt))
            VStack(spacing: Space.s1) {
                ProgressView(value: min(1, position / playing.duration))
                    .tint(theme.accent)
                HStack {
                    Text(clockText(position))
                    Spacer()
                    Text(clockText(playing.duration))
                }
                .textRole(.caption)
                .monospacedDigit()
                .foregroundStyle(theme.ink3)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Position")
            .accessibilityValue("\(clockText(position)) of \(clockText(playing.duration))")
        }
    }

    private var subtitles: some View {
        Menu {
            Picker("Subtitles", selection: Binding(get: { playing.subtitle }, set: { remote.command(.subtitle($0)) })) {
                Text("Off").tag(Int?.none)
                ForEach(playing.subtitles) { track in
                    Text(track.label).tag(Int?.some(track.id))
                }
            }
        } label: {
            Image(systemName: playing.subtitle == nil ? "captions.bubble" : "captions.bubble.fill")
        }
        .menuStyle(.button)
        .buttonStyle(PlayerButtonStyle())
        .contentShape(.contextMenuPreview, Circle())
        .accessibilityLabel("Subtitles")
        .accessibilityValue(playing.subtitles.first { $0.id == playing.subtitle }?.label ?? "Off")
        .accessibilityIdentifier("link.subtitles")
    }
}

/// While the other phone is out of reach, or shows nothing to control.
private struct LinkWaitingView: View {
    let remote: LinkRemote
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: Space.s3) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.largeTitle)
                .foregroundStyle(theme.ink3)
            Text(remote.isConnected ? "Nothing to control" : "Looking for \(remote.phoneName)")
                .textRole(.headline)
                .foregroundStyle(theme.ink2)
            Text(remote.isConnected
                ? "The controls show here once \(remote.phoneName) plays something or drives a big screen."
                : "Keep both iPhones near each other with Wi-Fi switched on, or on the same Wi-Fi, with Marquee open on both.")
                .textRole(.body)
                .foregroundStyle(theme.ink3)
        }
        .multilineTextAlignment(.center)
        .padding(Space.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("link.waiting")
    }
}

/// Home's button for a linked phone that drives a big screen or plays something: it opens this phone's
/// remote for it, in the place and shape of the TV remote and glasses buttons.
struct LinkControlButton: View {
    let phone: LinkedPhone
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme

    var body: some View {
        Button {
            session.link.control(phone.id)
        } label: {
            Image(systemName: "iphone.radiowaves.left.and.right")
                // 40% of the disc, the player controls' glyph proportion (Size.controlGlyph).
                .font(.system(size: (Size.barButton - 2 * Space.s1) * Size.controlGlyph / Size.control, weight: .semibold))
                .foregroundStyle(theme.accentText)
                .frame(width: Size.barButton - 2 * Space.s1, height: Size.barButton - 2 * Space.s1)
                .background(theme.sheet, in: Circle())
                .padding(Space.s1)
                .overlay(Circle().strokeBorder(theme.accent, lineWidth: 2))
                .frame(width: Size.barButton, height: Size.barButton)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Control \(phone.name)")
        .accessibilityHint("Turns this iPhone into the remote for \(phone.name).")
        .accessibilityShowsLargeContentViewer {
            Label("Control \(phone.name)", systemImage: "iphone.radiowaves.left.and.right")
        }
        .accessibilityIdentifier("link.button")
    }
}
