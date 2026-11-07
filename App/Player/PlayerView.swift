import AVFoundation
import MarqueeCore
import SwiftUI
import UIKit
import VideoEngine

/// The full-screen player (DESIGN §8.6). The picture runs behind everything. The chrome is drawn in the
/// dark theme of the pair, so glass over video stays dark; panels opened from the player use the app's
/// own theme and scheme.
struct PlayerView: View {
    @Bindable var model: PlayerModel
    let outerTheme: Theme
    let outerScheme: ColorScheme

    @Environment(ThemeStore.self) private var store
    @Environment(AppSession.self) private var session
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControl
    @Environment(\.displayScale) private var displayScale
    @State private var frames = TrickplayFrames()
    @State private var pull: CGFloat = 0
    /// The bottom controls' frame on screen, so subtitles and offers clear them.
    @State private var bottomControls: CGRect = .zero
    @State private var tapTask: Task<Void, Never>?
    @State private var lastTap: (at: Date, side: TapSide)?
    @State private var skipRun: (side: TapSide, until: Date)?

    var body: some View {
        let theme = store.selected(for: .dark)
            .adjusted(increaseContrast: contrast == .increased, reduceTransparency: reduceTransparency)
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { proxy in
                picture(in: proxy.size)
            }
            .ignoresSafeArea()
            .offset(y: pull)
            .scaleEffect(1 - min(pull, 400) / 4000)

            if model.isExternalPlayback {
                ExternalPlaybackView()
                    .allowsHitTesting(false)
            }
            if let flash = model.skipFlash {
                SkipFlashView(flash: flash)
                    .allowsHitTesting(false)
            }
            if model.chromeVisible || model.phase != .playing {
                PlayerChrome(model: model, frames: frames, close: close) { bottomControls = $0 }
                    .transition(.opacity)
            }
            OfferView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, Space.inset)
                .padding(.bottom, model.chromeVisible ? bottomControls.height + Space.s2 : Space.s6)
                .animation(.easeOut(duration: 0.18), value: model.chromeVisible)
            if model.fallback != nil {
                FallbackBanner(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, model.chromeVisible ? 76 : Space.s3)
            }
            if model.showsStats {
                StatsOverlay(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, model.chromeVisible ? 76 : Space.s3)
                    .padding(.horizontal, Space.inset)
            }
        }
        .environment(\.theme, theme)
        .environment(\.plexLibrary, model.library)
        .preferredColorScheme(.dark)
        .statusBarHidden(!model.chromeVisible)
        .persistentSystemOverlays(model.chromeVisible ? .automatic : .hidden)
        .accessibilityAction(.escape) { close() }
        .accessibilityAction(.magicTap) { model.togglePlay() }
        .sheet(isPresented: $model.showsEpisodes) {
            EpisodeSheet(model: model)
                .panel(model, theme: outerTheme, scheme: outerScheme)
        }
        .sheet(isPresented: $model.showsInfo) {
            NavigationStack {
                PlaybackInfoView(model: model)
            }
            .panel(model, theme: outerTheme, scheme: outerScheme)
        }
        .sheet(isPresented: $model.showsStyle) {
            NavigationStack {
                SubtitleStyleView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { model.showsStyle = false }
                        }
                    }
            }
            .panel(model, theme: outerTheme, scheme: outerScheme)
        }
        .onChange(of: session.settings.subtitleStyle) { model.styleChanged() }
        .onChange(of: voiceOver || switchControl) { _, on in
            if on { model.showChrome() }
        }
        .task(id: "\(model.item.ratingKey)/\(model.trickplay?.count ?? 0)") {
            frames.reset(model.trickplay)
        }
        .onAppear { rotate(to: .landscape) }
        .onDisappear { rotate(to: .portrait) }
        .accessibilityIdentifier("player")
    }

    // MARK: Picture

    private func picture(in size: CGSize) -> some View {
        let rect = VideoFrame.rect(aspect: model.aspect, video: model.presentationSize, in: size, displayScale: displayScale)
        return ZStack(alignment: .topLeading) {
            Color.black
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
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.aspect)
            SubtitleOverlay(
                model: model, picture: rect, screen: size,
                lift: model.chromeVisible ? max(0, size.height - bottomControls.minY) : 0,
                style: session.settings.subtitleStyle
            )
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { value in tapped(at: value.location, width: size.width) })
        .simultaneousGesture(pullGesture)
        .simultaneousGesture(pinchGesture)
        .accessibilityHidden(true)
    }

    // MARK: Gestures

    /// Taps are told apart by hand: a single tap waits 0.3 s for a second one, and after a skip more taps
    /// on the same side keep skipping at once (repeat taps within 1.5 s add up, behaviour spec §4).
    private func tapped(at point: CGPoint, width: CGFloat) {
        let side = TapSide(x: point.x, width: width)
        let now = Date.now
        if let run = skipRun, now < run.until, run.side == side {
            tapTask?.cancel()
            skip(side)
            return
        }
        if let last = lastTap, now.timeIntervalSince(last.at) < 0.3, last.side == side {
            tapTask?.cancel()
            lastTap = nil
            if side == .centre {
                Haptics.impact(.light)
                model.setAspect(model.aspect == .fit ? .fill : .fit)
            } else {
                skip(side)
            }
            return
        }
        lastTap = (now, side)
        tapTask?.cancel()
        tapTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            model.tapped()
        }
    }

    private func skip(_ side: TapSide) {
        Haptics.impact(.light)
        model.skip(by: side == .back ? -model.skipInterval : model.skipInterval)
        skipRun = (side, .now.addingTimeInterval(1.5))
    }

    /// A mostly vertical drag down moves the picture with the finger and closes past 140 pt or on a flick.
    private var pullGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                let move = value.translation
                guard pull > 0 || (move.height > 0 && move.height > abs(move.width) * 1.2) else { return }
                pull = max(0, move.height)
            }
            .onEnded { value in
                guard pull > 0 else { return }
                if pull > 140 || value.predictedEndTranslation.height > 360 {
                    close()
                } else {
                    withAnimation(reduceMotion ? .linear(duration: 0.12) : .spring(response: 0.26, dampingFraction: 1)) { pull = 0 }
                }
            }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onEnded { value in
                let wanted: VideoAspect? = value.magnification > 1.12 ? .fill : value.magnification < 0.9 ? .fit : nil
                guard let wanted, wanted != model.aspect else { return }
                Haptics.impact(.light)
                model.setAspect(wanted)
            }
    }

    private func close() {
        session.player.close(model)
    }

    private func rotate(to orientations: UIInterfaceOrientationMask) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        scene.requestGeometryUpdate(UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: orientations))
    }
}

/// Which third of the picture a tap landed in.
enum TapSide: Equatable {
    case back, centre, forward

    init(x: CGFloat, width: CGFloat) {
        self = x < width / 3 ? .back : x > width * 2 / 3 ? .forward : .centre
    }
}

private extension View {
    /// A panel opened from the player: the app's own theme, and the controls stay up while it shows.
    func panel(_ model: PlayerModel, theme: Theme, scheme: ColorScheme) -> some View {
        environment(\.theme, theme)
            .tint(theme.accent)
            .presentationDetents([.medium, .large])
            .presentationBackground(theme.sheet)
            .preferredColorScheme(scheme)
            .onAppear { model.menuOpened() }
            .onDisappear { model.menuClosed() }
    }
}

/// Where the picture sits on screen for an aspect. Fill and zoom crop; original shows the video's pixels
/// one to one; stretch fills the screen out of proportion.
enum VideoFrame {
    static func rect(aspect: VideoAspect, video: CGSize, in screen: CGSize, displayScale: CGFloat) -> CGRect {
        guard video.width > 0, video.height > 0, screen.width > 0, screen.height > 0 else {
            return CGRect(origin: .zero, size: screen)
        }
        let fit = min(screen.width / video.width, screen.height / video.height)
        let fill = max(screen.width / video.width, screen.height / video.height)
        let size: CGSize
        switch aspect {
        case .fit: size = CGSize(width: video.width * fit, height: video.height * fit)
        case .fill: size = CGSize(width: video.width * fill, height: video.height * fill)
        case .zoom:
            let scale = (fit + fill) / 2
            size = CGSize(width: video.width * scale, height: video.height * scale)
        case .original:
            let scale = 1 / max(1, displayScale)
            size = CGSize(width: video.width * scale, height: video.height * scale)
        case .stretch: size = screen
        }
        return CGRect(x: (screen.width - size.width) / 2, y: (screen.height - size.height) / 2, width: size.width, height: size.height)
    }
}

// MARK: - Subtitles drawn by Marquee

/// Sidecar text cues and image subtitles. They sit on the picture and rise above the bottom controls
/// while those show, so the controls never cover them.
private struct SubtitleOverlay: View {
    let model: PlayerModel
    let picture: CGRect
    let screen: CGSize
    let lift: CGFloat
    let style: SubtitleStyle

    var body: some View {
        let visible = picture.intersection(CGRect(origin: .zero, size: screen))
        let area = visible.isNull ? CGRect(origin: .zero, size: screen) : visible
        let margin = area.height * 0.06
        ZStack(alignment: .topLeading) {
            if !model.bitmaps.isEmpty {
                BitmapSubtitles(bitmaps: model.bitmaps, picture: picture, floor: screen.height - lift - margin)
            }
            if let text = model.cueText {
                VStack(spacing: 0) {
                    if style.position == .bottom { Spacer(minLength: 0) }
                    SubtitleLine(text: text, style: style, pictureHeight: area.height)
                    if style.position == .top { Spacer(minLength: 0) }
                }
                .padding(.horizontal, area.width * 0.06)
                .padding(.top, margin)
                .padding(.bottom, max(margin, lift - (screen.height - area.maxY) + Space.s2))
                .frame(width: area.width, height: area.height)
                .offset(x: area.minX, y: area.minY)
            }
        }
        .frame(width: screen.width, height: screen.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.18), value: lift)
        .accessibilityHidden(true)
    }
}

/// Image subtitles placed where the file puts them on its canvas, scaled to the picture, and moved up
/// only as far as needed to stay above `floor`.
private struct BitmapSubtitles: View {
    let bitmaps: [SubtitleBitmap]
    let picture: CGRect
    let floor: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(bitmaps.enumerated()), id: \.offset) { _, bitmap in
                if let image = Self.image(bitmap), bitmap.canvasWidth > 0, bitmap.canvasHeight > 0 {
                    let sx = picture.width / CGFloat(bitmap.canvasWidth)
                    let sy = picture.height / CGFloat(bitmap.canvasHeight)
                    let frame = CGRect(
                        x: picture.minX + CGFloat(bitmap.x) * sx, y: picture.minY + CGFloat(bitmap.y) * sy,
                        width: CGFloat(bitmap.width) * sx, height: CGFloat(bitmap.height) * sy
                    )
                    let rise = max(0, frame.maxY - floor)
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY - rise)
                }
            }
        }
    }

    private static func image(_ bitmap: SubtitleBitmap) -> CGImage? {
        guard bitmap.width > 0, bitmap.height > 0, bitmap.rgba.count >= bitmap.width * bitmap.height * 4,
              let provider = CGDataProvider(data: bitmap.rgba as CFData) else { return nil }
        return CGImage(
            width: bitmap.width, height: bitmap.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bitmap.width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}
