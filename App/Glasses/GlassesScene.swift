import MarqueeCore
import SwiftUI
import UIKit

/// The big screen's scene, for glasses or a TV. iOS makes it once the plugin offers it and a display is
/// connected.
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
            center.sceneConnected(screen: scene.screen)
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        MainActor.assumeIsolated {
            GlassesCenter.live?.sceneDisconnected()
            window = nil
        }
    }
}

/// What a view on the big screen needs to know of the display: the canvas and its margins, and, on a TV,
/// the pixels the video plays at.
struct BigScreenMetrics: Equatable {
    var layout = BigScreenLayout.glasses
    /// The display's own pixels on a TV; glasses lay out and ask for the canvas.
    var pixels: CGSize?

    var canvas: CGSize { CGSize(width: layout.width, height: layout.height) }
    var marginX: CGFloat { layout.marginX }
    var marginY: CGFloat { layout.marginY }
}

private struct BigScreenKey: EnvironmentKey {
    static let defaultValue = BigScreenMetrics()
}

extension EnvironmentValues {
    var bigScreen: BigScreenMetrics {
        get { self[BigScreenKey.self] }
        set { self[BigScreenKey.self] = newValue }
    }
}

/// The big screen: Marquee's canvas, 1080 high, scaled to whatever the display reports. SwiftUI draws it
/// at the display's own pixels, so a 4K TV is not upscaled from 1080p.
struct GlassesScreen: View {
    let center: GlassesCenter
    let store: ThemeStore
    let session: AppSession

    var body: some View {
        let metrics = center.metrics
        let theme = store.selected(for: .dark).onBigScreen(metrics.layout.kind)
        GeometryReader { proxy in
            let scale = metrics.layout.scale(fitting: proxy.size.width, proxy.size.height)
            GlassesCanvasView(center: center)
                .frame(width: metrics.canvas.width, height: metrics.canvas.height)
                .scaleEffect(scale)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(theme.canvas)
        .ignoresSafeArea()
        .environment(\.bigScreen, metrics)
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
    @Environment(\.bigScreen) private var metrics

    var body: some View {
        ZStack {
            theme.canvas
            if center.asksToUse {
                GlassesNotice(symbol: "display", title: center.question, message: "Answer on the iPhone.")
            } else if let navigator = center.navigator, session.state == .ready {
                GlassesNavigatorView(navigator: navigator)
                    .task(id: session.library?.instance) { navigator.start() }
            } else if center.isConnected {
                GlassesNotice(symbol: "iphone", title: "Choose a server on the iPhone", message: "Marquee shows here once it is signed in.")
            }
            GlassesVolume(center: center)
        }
        .frame(width: metrics.canvas.width, height: metrics.canvas.height)
        .clipped()
    }
}

/// A message in the middle of the screen.
struct GlassesNotice: View {
    let symbol: String
    let title: String
    let message: String
    @Environment(\.theme) private var theme
    @Environment(\.bigScreen) private var metrics

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
        .padding(metrics.marginY)
        .background(theme.glass, in: RoundedRectangle(cornerRadius: GlassesCanvas.radius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("glasses.notice")
    }
}

/// The system volume for a moment after the buttons change it.
private struct GlassesVolume: View {
    let center: GlassesCenter
    @Environment(\.theme) private var theme
    @Environment(\.bigScreen) private var metrics
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
            .padding(.top, metrics.marginY)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension Theme {
    /// A dark theme as the big screen draws it. With nothing behind them to blur, surfaces are made opaque
    /// over the canvas. Glasses' black is see-through, so their canvas is black; a TV keeps the theme's
    /// own dark canvas.
    func onBigScreen(_ kind: DisplayKind) -> Theme {
        let base = kind == .glasses ? RGBA(red: 0, green: 0, blue: 0, alpha: 1) : roles.canvas
        var screen = roles
        screen.canvas = base
        screen.sheet = roles.sheet.over(base)
        screen.glass = roles.glass.over(base)
        screen.glassRaised = roles.glassRaised.over(base)
        screen.trackOff = roles.trackOff.over(base)
        return Theme(id: id, name: name, mode: .dark, roles: screen)
    }
}

#if DEBUG
/// UI tests draw the big screen's canvas over the phone, turned a quarter so it is as large as the screen
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
        let metrics = center.metrics
        let theme = store.selected(for: .dark).onBigScreen(metrics.layout.kind)
        GeometryReader { proxy in
            let scale = min(proxy.size.width / metrics.canvas.height, proxy.size.height / metrics.canvas.width)
            GlassesCanvasView(center: center)
                .frame(width: metrics.canvas.width, height: metrics.canvas.height)
                .scaleEffect(scale)
                .rotationEffect(.degrees(90))
                .frame(width: metrics.canvas.height * scale, height: metrics.canvas.width * scale)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("glasses.canvas")
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .environment(\.bigScreen, metrics)
        .environment(\.theme, theme)
        .environment(\.plexLibrary, session.library)
        .environment(session)
        .environment(store)
        .environment(\.colorScheme, .dark)
    }
}
#endif
