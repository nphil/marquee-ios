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
    @State private var taps = SkipTaps(mode: .doubleTap)
    /// The format badge of the item that has started, and the item it was shown for: seeks, stalls and
    /// restarts of the same item never show it again.
    @State private var formatBadge: FormatBadge?
    /// The badge of a first start still waiting for the controls to fade.
    @State private var pendingBadge: FormatBadge?
    @State private var badgedItem: String?
    @State private var badgeTask: Task<Void, Never>?
    /// The whole screen, safe areas included. A landscape screen gets the episodes as a side panel.
    @State private var screen: CGSize = .zero

    private var sideLayout: Bool { screen.width > screen.height }

    var body: some View {
        let theme = store.selected(for: .dark)
            .adjusted(increaseContrast: contrast == .increased, reduceTransparency: reduceTransparency)
        ZStack {
            Color.black.ignoresSafeArea()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { screen = $0 }
            GeometryReader { proxy in
                picture(in: proxy.size)
            }
            .ignoresSafeArea()
            .offset(y: pull)
            .scaleEffect(1 - min(pull, 400) / 4000)

            if model.isExternalPlayback || model.castDevice != nil {
                ExternalPlaybackView(castName: model.castDevice?.name)
                    .allowsHitTesting(false)
            }
            if let flash = model.skipFlash {
                SkipFlashView(flash: flash)
                    .allowsHitTesting(false)
            }
            // Under the chrome and the offers: the panel only reports, so the controls over it stay
            // legible and take the touches.
            if model.showsStats {
                StatsOverlay(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, model.chromeVisible ? 76 : Space.s3)
                    .padding(.horizontal, Space.inset)
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
            if model.showsTiming, model.canTimeSubtitles, model.phase == .playing {
                timingCapsule
            }
            if let formatBadge {
                // The corner of the controls' own margins, inside the safe area; it shows only once the
                // controls have faded, so they never cover it.
                FormatBadgeView(badge: formatBadge, screenShortSide: min(screen.width, screen.height))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.horizontal, Space.inset)
                    .padding(.vertical, sideLayout ? Space.s4 : Space.s2)
                    .allowsHitTesting(false)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.94, anchor: .topTrailing)))
            }
            VStack(spacing: Space.s2) {
                if model.fallback != nil {
                    FallbackBanner(model: model)
                }
                SubtitleSearchBanner(finder: model.subtitleFinder)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, model.chromeVisible ? 76 : Space.s3)
            episodePanel
        }
        .environment(\.theme, theme)
        .environment(\.plexLibrary, model.library)
        .preferredColorScheme(.dark)
        .statusBarHidden(!model.chromeVisible)
        .persistentSystemOverlays(model.chromeVisible ? .automatic : .hidden)
        .accessibilityAction(.escape) { close() }
        .accessibilityAction(.magicTap) { model.togglePlay() }
        .sheet(isPresented: Binding(get: { model.showsEpisodes && !sideLayout }, set: { if !$0 { model.showsEpisodes = false } })) {
            EpisodeSheet(model: model) { model.showsEpisodes = false }
                .panel(model, theme: outerTheme, scheme: outerScheme, detents: [.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(Radius.sheet)
                // The picture above the sheet keeps playing and answers taps.
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .sheet(isPresented: $model.showsInfo) {
            NavigationStack {
                PlaybackInfoView(model: model)
            }
            .panel(model, theme: outerTheme, scheme: outerScheme)
        }
        .onChange(of: model.phase, initial: true) {
            showFormatBadge()
            model.viewportChanged(size: screen, scale: displayScale)
        }
        .onChange(of: model.chromeVisible) {
            if model.chromeVisible { hideFormatBadge() } else { revealFormatBadge() }
        }
        .onChange(of: screen) { model.viewportChanged(size: screen, scale: displayScale) }
        .onChange(of: displayScale) { model.viewportChanged(size: screen, scale: displayScale) }
        .onChange(of: model.aspect) { model.viewportChanged(size: screen, scale: displayScale) }
        .onChange(of: session.settings.subtitleStyle) { model.styleChanged() }
        .onChange(of: voiceOver || switchControl) { _, on in
            if on { model.showChrome() }
        }
        .task(id: "\(model.item.ratingKey)/\(model.trickplay?.count ?? 0)") {
            frames.reset(model.trickplay)
        }
        .onAppear { PlayerOrientation.opened(session.settings.videoOrientation) }
        .onDisappear { PlayerOrientation.closed() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("player")
    }

    /// Opposite the subtitles, clear of the chrome while it shows.
    private var timingCapsule: some View {
        let atTop = session.settings.subtitleStyle.anchor == .bottom
        return TimingCapsule(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: atTop ? .top : .bottom)
            .padding(.top, atTop ? (model.chromeVisible ? 76 : Space.s3) : 0)
            .padding(.bottom, atTop ? 0 : (model.chromeVisible ? bottomControls.height + Space.s2 : Space.s6))
            .animation(.easeOut(duration: 0.18), value: model.chromeVisible)
            .transition(.opacity)
    }

    // MARK: Picture

    private func picture(in size: CGSize) -> some View {
        let rect = VideoFrame.rect(aspect: model.aspect, video: model.presentationSize, in: size, displayScale: displayScale)
        return ZStack(alignment: .topLeading) {
            Color.black
            // A Chromecast draws the picture and its subtitles itself.
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
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.aspect)
                SubtitleOverlay(
                    model: model, picture: rect, screen: size,
                    lift: model.chromeVisible ? max(0, size.height - bottomControls.minY) : 0,
                    look: session.settings.subtitleStyle
                )
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { value in tapped(at: value.location, width: size.width) })
        .simultaneousGesture(pullGesture)
        .simultaneousGesture(pinchGesture)
        .accessibilityHidden(true)
    }

    // MARK: Episodes

    /// On a landscape screen the episodes are a compact panel on the trailing edge, about 40% of the
    /// width, and the picture stays visible and playing beside it; a portrait screen gets the sheet.
    private var episodePanel: some View {
        let width = min(max(screen.width * 0.4, 340), screen.width * 0.5)
        let shape = UnevenRoundedRectangle(topLeadingRadius: Radius.sheet, bottomLeadingRadius: Radius.sheet, style: .continuous)
        return Group {
            if model.showsEpisodes, sideLayout {
                GeometryReader { proxy in
                    // Both sides report the same inset, but only the one beside the Dynamic Island has
                    // anything in it: the content keeps clear of that side and runs to the edge on the
                    // other. The panel grows by the inset so the content keeps its width either way.
                    let cutout = PlayerOrientation.cutoutIsTrailing ? proxy.safeAreaInsets.trailing : 0
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        EpisodeSheet(model: model, side: true) { model.showsEpisodes = false }
                            .ignoresSafeArea(.container, edges: .horizontal)
                            .padding(.trailing, cutout)
                            .frame(width: width + cutout)
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 30).onEnded { value in
                                    if value.translation.width > 80, value.translation.width > abs(value.translation.height) * 2 {
                                        model.showsEpisodes = false
                                    }
                                }
                            )
                            .background {
                                ZStack {
                                    shape.fill(outerTheme.sheet)
                                    shape.strokeBorder(outerTheme.edge, lineWidth: 1)
                                }
                                .ignoresSafeArea()
                            }
                    }
                }
                .ignoresSafeArea(.container, edges: .trailing)
                .environment(\.theme, outerTheme)
                .environment(\.colorScheme, outerScheme)
                .tint(outerTheme.accent)
                .onAppear { model.menuOpened() }
                .onDisappear { model.menuClosed() }
                .accessibilityAddTraits(.isModal)
                .accessibilityAction(.escape) { model.showsEpisodes = false }
                .transition(reduceMotion ? .opacity : .move(edge: .trailing))
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.3), value: model.showsEpisodes)
    }

    // MARK: Format badge

    /// When an item first plays, its format is made ready; it shows for 1 s once the controls have faded.
    private func showFormatBadge() {
        guard model.phase == .playing, badgedItem != model.item.ratingKey else { return }
        badgedItem = model.item.ratingKey
        let audio = model.audio.flatMap { track in model.part?.streams.first { $0.id == track.id } }
        let badge = FormatBadge.make(video: model.part?.videoStream, media: model.media, audio: audio, route: model.route)
        badgeTask?.cancel()
        formatBadge = nil
        pendingBadge = badge.isEmpty ? nil : badge
        revealFormatBadge()
    }

    /// Shows the waiting badge when no controls are up. VoiceOver and Switch Control keep the controls up
    /// for good, so for them it shows at once.
    private func revealFormatBadge() {
        guard let badge = pendingBadge, model.phase == .playing, !model.chromeVisible || voiceOver || switchControl else { return }
        pendingBadge = nil
        let fade: Animation = reduceMotion ? .easeOut(duration: 0.15) : .easeOut(duration: 0.3)
        withAnimation(fade) { formatBadge = badge }
        #if DEBUG
        // A UI test lengthens the hold so a slow runner can still see the badge.
        let override = UserDefaults.standard.double(forKey: "marquee.uitest.badgeSeconds")
        let hold = override > 0 ? override : 1
        #else
        let hold = 1.0
        #endif
        badgeTask = Task {
            try? await Task.sleep(for: .seconds(hold))
            guard !Task.isCancelled else { return }
            withAnimation(fade) { formatBadge = nil }
        }
    }

    /// The controls came back: the badge leaves rather than sit under or beside them.
    private func hideFormatBadge() {
        guard formatBadge != nil, !(voiceOver || switchControl) else { return }
        badgeTask?.cancel()
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .easeOut(duration: 0.3)) { formatBadge = nil }
    }

    // MARK: Gestures

    /// Taps are told apart by hand (`SkipTaps`): a single tap waits 0.3 s for a second one. In the
    /// chained mode more taps on the same side keep skipping at once after a skip (repeat taps within
    /// 1.5 s add up, behaviour spec §4); in the double-tap mode only a true double-tap skips.
    private func tapped(at point: CGPoint, width: CGFloat) {
        let side = TapSide(x: point.x, width: width)
        taps.mode = session.settings.skipTaps
        // A tap on the picture beside the episodes panel closes it.
        if model.showsEpisodes, sideLayout {
            model.showsEpisodes = false
            return
        }
        // A still picture invites taps to wake it; while playback waits on data they bring the controls
        // and never skip.
        if model.isStalled {
            tapTask?.cancel()
            taps.reset()
            model.showChrome()
            return
        }
        switch taps.tap(side, at: ProcessInfo.processInfo.systemUptime) {
        case .skip(let side):
            tapTask?.cancel()
            Haptics.impact(.light)
            model.skip(by: side == .back ? -model.skipInterval : model.skipInterval)
        case .toggleAspect:
            tapTask?.cancel()
            Haptics.impact(.light)
            model.setAspect(model.aspect == .fit ? .fill : .fit)
        case .single:
            tapTask?.cancel()
            tapTask = Task {
                try? await Task.sleep(for: .seconds(SkipTaps.doubleTapWindow))
                guard !Task.isCancelled else { return }
                model.tapped()
            }
        }
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
}

private extension View {
    /// A panel opened from the player: the app's own theme, and the controls stay up while it shows.
    func panel(
        _ model: PlayerModel, theme: Theme, scheme: ColorScheme,
        detents: Set<PresentationDetent> = [.medium, .large]
    ) -> some View {
        environment(\.theme, theme)
            .tint(theme.accent)
            .presentationDetents(detents)
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
struct SubtitleOverlay: View {
    let model: PlayerModel
    let picture: CGRect
    let screen: CGSize
    let lift: CGFloat
    let look: SubtitleLook

    var body: some View {
        let visible = picture.intersection(CGRect(origin: .zero, size: screen))
        let area = visible.isNull ? CGRect(origin: .zero, size: screen) : visible
        let margin = area.height * 0.06
        ZStack(alignment: .topLeading) {
            if !model.bitmaps.isEmpty {
                BitmapSubtitles(bitmaps: model.bitmaps, picture: picture, floor: screen.height - lift - margin)
                    // The look's colour tints the picture's white letters; their own outline stays dark.
                    .colorMultiply(PictureColours.subtitle(look))
            }
            if let text = model.cueText {
                let distance = CGFloat(look.edgeDistance) * area.height / 1080
                VStack(spacing: 0) {
                    if look.anchor == .bottom { Spacer(minLength: 0) }
                    SubtitleLine(text: text, look: look, pictureHeight: area.height, words: model.cueWords)
                    if look.anchor == .top { Spacer(minLength: 0) }
                }
                .padding(.horizontal, area.width * 0.06)
                .padding(.top, distance)
                .padding(.bottom, max(distance, lift - (screen.height - area.maxY) + Space.s2))
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
