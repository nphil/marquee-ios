import MarqueeCore
import SwiftUI
import UIKit

/// The scrubber (DESIGN §8.6): elapsed time, a 6 pt track in a 56 pt hit area, remaining time. A drag
/// shows the scene thumbnail and the time above the thumb, ticks once per thumbnail, and slows down as
/// the finger moves away from the track, as in Stashy.
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
    }

    private func track(width: CGFloat, shown: TimeInterval) -> some View {
        let fraction = model.duration > 0 ? min(1, max(0, shown / model.duration)) : 0
        let x = width * fraction
        return ZStack(alignment: .leading) {
            // The readable track (DESIGN §5.1): trackOff all but vanished over a bright picture.
            Capsule()
                .fill(theme.ink.opacity(0.6))
                .frame(height: Self.trackHeight)
            Capsule()
                .fill(theme.ink)
                .frame(width: max(Self.trackHeight, x), height: Self.trackHeight)
            ForEach(Array(model.markers.enumerated()), id: \.offset) { _, marker in
                let start = position(of: marker.start, width: width)
                let end = position(of: marker.end, width: width)
                Capsule()
                    .fill(theme.ink2)
                    .frame(width: max(3, end - start), height: 3)
                    .offset(x: start, y: Self.trackHeight / 2 + 5)
            }
            Circle()
                .fill(theme.ink)
                .frame(width: Self.thumb, height: Self.thumb)
                .scaleEffect(model.isScrubbing && !reduceMotion ? 1.4 : 1)
                .offset(x: x - Self.thumb / 2)
                .animation(.easeOut(duration: 0.12), value: model.isScrubbing)
        }
        .frame(width: width, height: Self.hitHeight)
        .contentShape(Rectangle())
        .gesture(drag(width: width))
        .overlay(alignment: .bottomLeading) {
            if model.isScrubbing {
                SeekPreview(
                    image: frames.image(near: scrubTime),
                    time: clockText(scrubTime, hours: model.duration >= 3600),
                    speed: speed.label
                )
                .alignmentGuide(.leading) { size in
                    size.width / 2 - min(max(x, size.width / 2), max(size.width / 2, width - size.width / 2))
                }
                .offset(y: -(Self.hitHeight / 2 + 20))
                .allowsHitTesting(false)
            }
        }
    }

    private func position(of milliseconds: Int, width: CGFloat) -> CGFloat {
        guard model.duration > 0 else { return 0 }
        return width * min(1, max(0, Double(milliseconds) / 1000 / model.duration))
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

/// The scene thumbnail and time above the scrubber's thumb.
struct SeekPreview: View {
    let image: UIImage?
    let time: String
    var speed: String?

    @Environment(\.theme) private var theme
    private static let width: CGFloat = 176

    var body: some View {
        VStack(spacing: Space.s2) {
            if let image {
                let aspect = image.size.height > 0 ? image.size.width / image.size.height : 16 / 9
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.width, height: Self.width / min(2.4, max(1.33, aspect)))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control))
                    .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(theme.edgeRaised, lineWidth: 1))
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
        .fixedSize()
        .accessibilityHidden(true)
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
