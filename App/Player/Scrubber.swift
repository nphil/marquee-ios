import MarqueeCore
import SwiftUI
import UIKit

/// The scrubber (DESIGN §8.6): elapsed time, a 6 pt track in a 56 pt hit area, remaining time. A drag
/// shows the scene thumbnail and the time above the thumb the moment the finger lands, ticks once per
/// thumbnail, and slows down as the finger moves away from the track, as in Stashy. The preview is
/// drawn by the chrome (`SeekPreviewLayer`) from the thumb's anchor, so it shares the track's space.
struct Scrubber: View {
    let model: PlayerModel
    let frames: TrickplayFrames

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scrubTime: TimeInterval = 0
    @State private var lastX: CGFloat?
    @State private var speed = ScrubSpeed.full
    @State private var frameIndex: Int?
    @GestureState private var touching = false

    private static let hitHeight: CGFloat = 56
    private static let trackHeight: CGFloat = 6
    private static let thumb: CGFloat = 16

    /// The thumb's drawn size while scrubbing, which the preview sits above.
    private var thumbSize: CGFloat { model.isScrubbing && !reduceMotion ? Self.thumb * 1.4 : Self.thumb }

    #if DEBUG
    /// UI tests hold the scrubber mid-drag at a fraction of the item (`-marquee.uitest.scrub`), since a
    /// touch cannot be held while the test takes its screenshot.
    private func holdForTest() {
        guard FakePlex.isActive, model.duration > 0, !model.isScrubbing,
              let fraction = UserDefaults.standard.string(forKey: "marquee.uitest.scrub").flatMap(Double.init) else { return }
        model.beginScrub()
        speed = .full
        scrubTime = min(1, max(0, fraction)) * model.duration
        frameIndex = frames.index(at: scrubTime)
    }
    #endif

    var body: some View {
        let shown = model.isScrubbing ? scrubTime : model.time
        let hours = model.duration >= 3600
        HStack(spacing: Space.s3) {
            Text(clockText(shown, hours: hours))
                .monospacedDigit()
                .textRole(.caption)
                .foregroundStyle(theme.ink)
            GeometryReader { proxy in
                track(width: proxy.size.width, shown: shown)
            }
            .frame(height: Self.hitHeight)
            Text("-" + clockText(model.duration - shown, hours: hours))
                .monospacedDigit()
                .textRole(.caption)
                .foregroundStyle(theme.ink)
        }
        .onChange(of: touching) { _, touching in
            // A drag the system cancels never reaches onEnded.
            if !touching { finish() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(spoken(shown)) of \(spoken(model.duration))")
        .accessibilityHint(markerHint)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.skip(by: model.skipInterval, flash: false)
            case .decrement: model.skip(by: -model.skipInterval, flash: false)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("player.scrubber")
        #if DEBUG
        .task(id: model.duration) { holdForTest() }
        #endif
    }

    private func track(width: CGFloat, shown: TimeInterval) -> some View {
        let fraction = model.duration > 0 ? min(1, max(0, shown / model.duration)) : 0
        let x = width * fraction
        // Read here, not in the preference's closure, so a thumbnail that lands redraws the preview.
        let content = model.isScrubbing
            ? (image: frames.image(near: scrubTime), hasFrames: frames.hasFrames,
               time: clockText(scrubTime, hours: model.duration >= 3600), speed: speed.label)
            : nil
        return ZStack(alignment: .leading) {
            ZStack(alignment: .leading) {
                // The readable track (DESIGN §5.1): trackOff all but vanished over a bright picture.
                Capsule()
                    .fill(theme.ink.opacity(0.6))
                Capsule()
                    .fill(theme.ink)
                    .frame(width: max(Self.trackHeight, x))
            }
            .frame(width: width, height: Self.trackHeight)
            .mask { TrackSegments(cuts: cuts(width: width)) }
            Circle()
                .fill(theme.ink)
                .frame(width: Self.thumb, height: Self.thumb)
                .scaleEffect(model.isScrubbing && !reduceMotion ? 1.4 : 1)
                .animation(.easeOut(duration: 0.12), value: model.isScrubbing)
                .offset(x: x - Self.thumb / 2)
                .transaction(value: model.isScrubbing) { $0.animation = nil }
        }
        .frame(width: width, height: Self.hitHeight)
        .contentShape(Rectangle())
        .gesture(drag(width: width))
        .overlay(alignment: .leading) {
            // The thumb's frame, handed up as an anchor for the chrome to place the preview by. It sits at
            // the thumb's own offset in this track, so the two cannot drift apart, and it moves without
            // animation: the preview shows at the touch, not on its way there.
            Color.clear
                .frame(width: thumbSize, height: thumbSize)
                .offset(x: x - thumbSize / 2)
                .anchorPreference(key: SeekPreviewKey.self, value: .bounds) { thumb in
                    content.map { SeekPreviewState(thumb: thumb, image: $0.image, hasFrames: $0.hasFrames, time: $0.time, speed: $0.speed) }
                }
                .transaction(value: model.isScrubbing) { $0.animation = nil }
                .allowsHitTesting(false)
        }
    }

    private func position(of milliseconds: Int, width: CGFloat) -> CGFloat {
        guard model.duration > 0 else { return 0 }
        return width * min(1, max(0, Double(milliseconds) / 1000 / model.duration))
    }

    /// The edges of the intro and credits along the track, leaving out those at its ends.
    private func cuts(width: CGFloat) -> [CGFloat] {
        model.markers
            .flatMap { [position(of: $0.start, width: width), position(of: $0.end, width: width)] }
            .filter { $0 > Self.trackHeight && $0 < width - Self.trackHeight }
    }

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($touching) { _, touching, _ in touching = true }
            .onChanged { value in
                guard model.duration > 0, width > 0 else { return }
                if lastX == nil {
                    // A touch jumps to the spot under the finger; moving from there is relative.
                    model.beginScrub()
                    speed = .full
                    scrubTime = Double(min(1, max(0, value.location.x / width))) * model.duration
                    frameIndex = frames.index(at: scrubTime)
                } else {
                    let tier = ScrubSpeed(distance: value.location.y - Self.hitHeight / 2)
                    if tier != speed {
                        speed = tier
                        Haptics.selection()
                    }
                    let moved = Double((value.location.x - (lastX ?? value.location.x)) / width)
                    scrubTime = min(model.duration, max(0, scrubTime + moved * model.duration * speed.rate))
                    if let index = frames.index(at: scrubTime), index != frameIndex {
                        frameIndex = index
                        Haptics.selection()
                    }
                }
                lastX = value.location.x
            }
            .onEnded { _ in finish() }
    }

    private func finish() {
        guard lastX != nil else { return }
        lastX = nil
        speed = .full
        frameIndex = nil
        model.endScrub(at: scrubTime)
    }

    private func spoken(_ seconds: TimeInterval) -> String {
        Duration.seconds(Int64(max(0, seconds.isFinite ? seconds : 0)))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }

    private var markerHint: String {
        let hours = model.duration >= 3600
        return model.markers.compactMap { marker -> String? in
            let start = clockText(Double(marker.start) / 1000, hours: hours)
            let end = clockText(Double(marker.end) / 1000, hours: hours)
            switch marker.kind {
            case .intro: return "Intro from \(start) to \(end)."
            case .credits: return "Credits from \(start)."
            default: return nil
            }
        }
        .joined(separator: " ")
    }
}

/// The track as segments: a 2 pt gap at each cut, so the intro and credits read as parts of the one
/// track (DESIGN §8.6).
private struct TrackSegments: Shape {
    let cuts: [CGFloat]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var start = rect.minX
        for cut in cuts.sorted() where cut - 1 > start {
            path.addRect(CGRect(x: start, y: rect.minY, width: cut - 1 - start, height: rect.height))
            start = cut + 1
        }
        path.addRect(CGRect(x: start, y: rect.minY, width: max(0, rect.maxX - start), height: rect.height))
        return path
    }
}

/// How fast a drag moves the playhead, by how far the finger is above or below the track.
enum ScrubSpeed: Equatable {
    case full, half, quarter, fine

    init(distance: CGFloat) {
        switch abs(distance) {
        case ..<44: self = .full
        case ..<90: self = .half
        case ..<150: self = .quarter
        default: self = .fine
        }
    }

    var rate: Double {
        switch self {
        case .full: 1
        case .half: 0.5
        case .quarter: 0.25
        case .fine: 0.1
        }
    }

    /// Shown only below full speed.
    var label: String? {
        switch self {
        case .full: nil
        case .half: "Half-Speed Scrubbing"
        case .quarter: "Quarter-Speed Scrubbing"
        case .fine: "Fine Scrubbing"
        }
    }
}

/// What the scrubber hands up to be drawn above everything else: the thumb's frame, as an anchor the
/// chrome resolves in its own coordinate space, and the preview's content. The chrome draws the
/// preview, so it is placed in the space the track lives in and clamped against the safe area it fills.
struct SeekPreviewState {
    let thumb: Anchor<CGRect>
    let image: UIImage?
    /// Whether scene thumbnails exist for this item, so the frame is reserved while one decodes.
    let hasFrames: Bool
    let time: String
    let speed: String?
}

struct SeekPreviewKey: PreferenceKey {
    static var defaultValue: SeekPreviewState? { nil }

    static func reduce(value: inout SeekPreviewState?, nextValue: () -> SeekPreviewState?) {
        value = value ?? nextValue()
    }
}

/// Draws the preview centred on the thumb with a fixed gap above it, kept `Space.inset` inside the
/// edges of the space it fills (the chrome, which sits inside the safe area). It appears with the
/// touch, without a transition.
struct SeekPreviewLayer: View {
    let state: SeekPreviewState?

    /// The space between the thumb's top and the preview's bottom edge.
    private static let gap: CGFloat = Space.s3

    var body: some View {
        GeometryReader { proxy in
            if let state {
                let thumb = proxy[state.thumb]
                let half = SeekPreview.width / 2
                let lowest = Space.inset + half
                let centre = min(max(thumb.midX, lowest), max(lowest, proxy.size.width - lowest))
                ZStack(alignment: .bottomLeading) {
                    SeekPreview(image: state.image, hasFrames: state.hasFrames, time: state.time, speed: state.speed)
                        .offset(x: centre - half, y: thumb.minY - Self.gap - proxy.size.height)
                    // Where the thumb is, for the UI tests: the scrubber's own element hides its children.
                    Color.clear
                        .frame(width: thumb.width, height: thumb.height)
                        .offset(x: thumb.minX, y: thumb.minY + thumb.height - proxy.size.height)
                        .accessibilityHidden(!SeekPreview.exposedToTests)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Thumb")
                        .accessibilityIdentifier("player.scrubThumb")
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomLeading)
                .transition(.identity)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The scene thumbnail, 16:9, and the time under it.
struct SeekPreview: View {
    let image: UIImage?
    let hasFrames: Bool
    let time: String
    var speed: String?

    @Environment(\.theme) private var theme
    /// 25-30% over the first version's 176 pt.
    static let width: CGFloat = 224
    /// The UI tests read the preview and the thumb through the accessibility tree; users never do.
    static var exposedToTests: Bool { FakePlex.isActive }

    var body: some View {
        VStack(spacing: Space.s2) {
            if hasFrames || image != nil {
                let shape = RoundedRectangle(cornerRadius: Radius.control)
                Group {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(theme.glass)
                    }
                }
                .frame(width: Self.width, height: Self.width * 9 / 16)
                .clipShape(shape)
                .overlay(shape.strokeBorder(theme.edgeRaised, lineWidth: 1))
            }
            VStack(spacing: 2) {
                Text(time)
                    .monospacedDigit()
                    .textRole(.label)
                    .foregroundStyle(theme.ink)
                if let speed {
                    Text(speed)
                        .textRole(.caption)
                        .foregroundStyle(theme.ink2)
                }
            }
            .padding(.horizontal, Space.s3)
            .padding(.vertical, Space.s1)
            .background(theme.glass, in: Capsule())
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(!Self.exposedToTests)
        .accessibilityLabel(time)
        .accessibilityValue(image == nil ? "pending" : "ready")
        .accessibilityIdentifier("player.seekPreview")
    }
}

/// Decoded scene thumbnails for the scrub preview. Frames decode off the main thread; asking for one
/// not decoded yet returns the nearest decoded neighbour meanwhile and redraws when it lands.
@MainActor @Observable
final class TrickplayFrames {
    private var trickplay: Trickplay?
    private var landed = 0
    @ObservationIgnored private var cache: [Int: UIImage] = [:]
    @ObservationIgnored private var recent: [Int] = []
    @ObservationIgnored private var pending: Set<Int> = []
    @ObservationIgnored private var generation = 0

    /// Plex's frames are 320 pt wide, about 230 KB decoded: 32 is about 7 MB.
    private static let limit = 32

    func reset(_ trickplay: Trickplay?) {
        generation += 1
        self.trickplay = trickplay
        cache = [:]
        recent = []
        pending = []
    }

    var hasFrames: Bool { trickplay != nil }

    func index(at time: TimeInterval) -> Int? {
        trickplay?.index(at: time)
    }

    func image(near time: TimeInterval) -> UIImage? {
        _ = landed
        guard let trickplay else { return nil }
        let index = trickplay.index(at: time)
        if let image = cache[index] { return image }
        decode(index, from: trickplay)
        for distance in 1...4 {
            if let image = cache[index - distance] ?? cache[index + distance] { return image }
        }
        return nil
    }

    private func decode(_ index: Int, from trickplay: Trickplay) {
        guard pending.insert(index).inserted else { return }
        let generation = generation
        Task {
            let image = await FrameDecoding.decode(trickplay, at: index)
            guard generation == self.generation else { return }
            pending.remove(index)
            guard let image else { return }
            cache[index] = image
            recent.append(index)
            if recent.count > Self.limit {
                cache[recent.removeFirst()] = nil
            }
            landed += 1
        }
    }
}

private enum FrameDecoding {
    @concurrent
    static func decode(_ trickplay: Trickplay, at index: Int) async -> UIImage? {
        guard let image = trickplay.image(at: index) else { return nil }
        return await image.byPreparingForDisplay() ?? image
    }
}
