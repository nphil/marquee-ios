import MarqueeCore
import SwiftUI
import UIKit

/// The glasses' scene. iOS makes it once the plugin offers it and a display is connected.
final class GlassesSceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        MainActor.assumeIsolated {
            guard let center = GlassesCenter.live, let store = center.themeStore, let appSession = center.session else { return }
            let host = UIHostingController(rootView: GlassesScreen(center: center, store: store, session: appSession))
            host.view.backgroundColor = .black
            let window = UIWindow(windowScene: scene)
            window.rootViewController = host
            // Shown without becoming key: the volume buttons and VoiceOver stay with the phone's window.
            window.isHidden = false
            self.window = window
            center.sceneConnected()
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        MainActor.assumeIsolated {
            GlassesCenter.live?.sceneDisconnected()
            window = nil
        }
    }
}

/// The glasses' screen: Marquee's 1920 × 1080 canvas, scaled to whatever the display reports.
struct GlassesScreen: View {
    let center: GlassesCenter
    let store: ThemeStore
    let session: AppSession

    var body: some View {
        let theme = store.selected(for: .dark).onGlasses()
        GeometryReader { proxy in
            let scale = min(proxy.size.width / GlassesCanvas.width, proxy.size.height / GlassesCanvas.height)
            GlassesCanvasView(center: center)
                .frame(width: GlassesCanvas.width, height: GlassesCanvas.height)
                .scaleEffect(scale)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(theme.canvas)
        .ignoresSafeArea()
        .environment(\.theme, theme)
        .environment(\.plexLibrary, session.library)
        .environment(session)
        .environment(store)
        .environment(\.colorScheme, .dark)
    }
}

/// What the canvas shows: the question while it is asked, a note while there is nothing to drive,
/// else the pages and the player.
struct GlassesCanvasView: View {
    let center: GlassesCenter
    @Environment(AppSession.self) private var session
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.canvas
            if center.asksToUse {
                GlassesNotice(symbol: "eyeglasses", title: "Use as XR glasses?", message: "Answer on the iPhone.")
            } else if let navigator = center.navigator, session.state == .ready {
                GlassesNavigatorView(navigator: navigator)
                    .task(id: session.library?.instance) { navigator.start() }
            } else if center.isConnected {
                GlassesNotice(symbol: "iphone", title: "Choose a server on the iPhone", message: "Marquee shows here once it is signed in.")
            }
            GlassesVolume(center: center)
        }
        .frame(width: GlassesCanvas.width, height: GlassesCanvas.height)
        .clipped()
    }
}

/// A message in the middle of the glasses.
struct GlassesNotice: View {
    let symbol: String
    let title: String
    let message: String
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: GlassesCanvas.tileGap) {
            Image(systemName: symbol)
                .font(.system(size: GlassesCanvas.glyph, weight: .semibold))
                .foregroundStyle(theme.accentText)
            Text(title)
                .glassesText(.title)
                .foregroundStyle(theme.ink)
            Text(message)
                .glassesText(.body)
                .foregroundStyle(theme.ink2)
        }
        .multilineTextAlignment(.center)
        .padding(GlassesCanvas.marginY)
        .background(theme.glass, in: RoundedRectangle(cornerRadius: GlassesCanvas.radius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("glasses.notice")
    }
}

/// The system volume for a moment after the buttons change it.
private struct GlassesVolume: View {
    let center: GlassesCenter
    @Environment(\.theme) private var theme
    /// How long the level stays up after the last press.
    private static let shownFor: TimeInterval = 2

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.shownFor / 4)) { context in
            let shown = center.volumeChanged.map { context.date.timeIntervalSince($0) < Self.shownFor } ?? false
            HStack(spacing: GlassesCanvas.titleGap) {
                Image(systemName: center.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: GlassesText.headline.size, weight: .semibold))
                    .foregroundStyle(theme.ink)
                Capsule()
                    .fill(theme.trackOff)
                    .frame(width: GlassesCanvas.volumeWidth, height: GlassesCanvas.barHeight)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(theme.accent)
                            .frame(width: GlassesCanvas.volumeWidth * CGFloat(center.volume), height: GlassesCanvas.barHeight)
                    }
            }
            .padding(.horizontal, GlassesCanvas.tileGap)
            .frame(height: GlassesCanvas.option)
            .background(theme.glassRaised, in: Capsule())
            .opacity(shown ? 1 : 0)
            .animation(Motion.label, value: shown)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, GlassesCanvas.marginY)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension Theme {
    /// A dark theme as the glasses draw it. Their black is see-through, so the canvas is black and the
    /// surfaces, with nothing behind them to blur, are made opaque over it.
    func onGlasses() -> Theme {
        let black = RGBA(red: 0, green: 0, blue: 0, alpha: 1)
        var glasses = roles
        glasses.canvas = black
        glasses.sheet = roles.sheet.over(black)
        glasses.glass = roles.glass.over(black)
        glasses.glassRaised = roles.glassRaised.over(black)
        glasses.trackOff = roles.trackOff.over(black)
        return Theme(id: id, name: name, mode: .dark, roles: glasses)
    }
}

#if DEBUG
/// UI tests draw the glasses' canvas over the phone, turned a quarter so it is as large as the screen
/// allows. The window lets every touch through to the remote below it.
@MainActor
enum GlassesPreview {
    private static var window: UIWindow?

    static func show(center: GlassesCenter) {
        guard window == nil, let scene = GlassesCenter.phoneScene(), let store = center.themeStore,
              let session = center.session else { return }
        let host = UIHostingController(rootView: GlassesPreviewView(center: center, store: store, session: session))
        host.view.backgroundColor = .clear
        let window = PassThroughWindow(windowScene: scene)
        window.windowLevel = .normal + 2
        window.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = false
        self.window = window
    }

    private final class PassThroughWindow: UIWindow {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    }
}

private struct GlassesPreviewView: View {
    let center: GlassesCenter
    let store: ThemeStore
    let session: AppSession

    var body: some View {
        let theme = store.selected(for: .dark).onGlasses()
        GeometryReader { proxy in
            let scale = min(proxy.size.width / GlassesCanvas.height, proxy.size.height / GlassesCanvas.width)
            GlassesCanvasView(center: center)
                .frame(width: GlassesCanvas.width, height: GlassesCanvas.height)
                .scaleEffect(scale)
                .rotationEffect(.degrees(90))
                .frame(width: GlassesCanvas.height * scale, height: GlassesCanvas.width * scale)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("glasses.canvas")
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .environment(\.theme, theme)
        .environment(\.plexLibrary, session.library)
        .environment(session)
        .environment(store)
        .environment(\.colorScheme, .dark)
    }
}
#endif
