import AVFoundation
import Foundation
import MarqueeCore
import UIKit

/// Where the player makes its own scrub frames from: the file it plays, which is a stream the phone reads
/// directly or a download. The URL carries the playback token; it is held in memory and never logged.
struct ScrubPreviewSource: Equatable, Sendable {
    let part: Int
    let url: URL
    let isLocal: Bool
}

/// What the background fill reads from the player each time it picks a frame.
struct ScrubPreviewContext {
    var playhead: TimeInterval
    var duration: TimeInterval
    var isPlaying: Bool
    var isStalled: Bool
    var isScrubbing: Bool
}

/// What the player's frames are made from: the task that sets them up runs again when any of it changes.
struct ScrubSetup: Equatable {
    let item: String
    let indexed: Int
    let source: ScrubPreviewSource?
}

enum ScrubPreviews {
    /// Made frames outlive a player; the cache is the system's to purge when the phone needs the space.
    static let disk = ScrubPreviewDisk(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "ScrubPreviews", directoryHint: .isDirectory)
    )
}

/// Reads frames from the file with a generator of its own, so the playing item is not disturbed. The time
/// tolerance is half a slot either side, which lets the generator take the nearest keyframe instead of
/// decoding up to the exact time.
final class FrameMaker: @unchecked Sendable {
    private let generator: AVAssetImageGenerator

    init(url: URL) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        let side = CGFloat(ScrubPreviewPlan.width)
        generator.maximumSize = CGSize(width: side, height: side)
        let tolerance = CMTime(seconds: ScrubPreviewPlan.interval / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        self.generator = generator
    }

    /// A JPEG of the frame near `time`; nil when it could not be made or the task was cancelled.
    @concurrent
    func jpeg(at time: TimeInterval) async -> Data? {
        guard let made = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)) else { return nil }
        return UIImage(cgImage: made.image).jpegData(compressionQuality: 0.6)
    }

    func cancel() {
        generator.cancelAllCGImageGeneration()
    }
}

/// Decoded scene thumbnails for the scrub preview. A title with Plex's index shows its frames; one without
/// shows frames the player makes from its own file, a slot every 10 s (`ScrubPreviewPlan`): one for the
/// thumb's place at once, and the rest in the background while the title plays. Frames decode off the main
/// thread; asking for one not ready returns the nearest decoded neighbour meanwhile and redraws when it lands.
@MainActor @Observable
final class TrickplayFrames {
    private var trickplay: Trickplay?
    private var landed = 0
    /// The player's own previews have failed to make a frame: the preview shows the time only.
    private var unavailable = false
    @ObservationIgnored private var cache: [Int: UIImage] = [:]
    @ObservationIgnored private var recent: [Int] = []
    @ObservationIgnored private var pending: Set<Int> = []
    @ObservationIgnored private var generation = 0

    @ObservationIgnored private var source: ScrubPreviewSource?
    @ObservationIgnored private var context: (@MainActor () -> ScrubPreviewContext?)?
    @ObservationIgnored private var scrubMaker: FrameMaker?
    @ObservationIgnored private var fillMaker: FrameMaker?
    /// Slots with a frame on disk, or being written.
    @ObservationIgnored private var have: Set<Int> = []
    @ObservationIgnored private var missed: Set<Int> = []
    @ObservationIgnored private var ready: Task<Void, Never>?
    @ObservationIgnored private var worker: Task<Void, Never>?
    /// Which worker may clear `worker` on its way out: a cancelled one must not drop its successor.
    @ObservationIgnored private var workerSerial = 0
    @ObservationIgnored private var fill: Task<Void, Never>?
    @ObservationIgnored private var wanted: Int?
    @ObservationIgnored private var knownDuration: TimeInterval = 0
    @ObservationIgnored private var lastImage: UIImage?
    @ObservationIgnored private var pacer = ScrubPreviewPacer()
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var link = (isUnmeteredWiFi: false, saveData: false)

    /// Plex's frames are 320 pt wide, about 230 KB decoded: 32 is about 7 MB. Made frames are 240 px, about
    /// 130 KB: 64 is about 8 MB.
    private static let limit = 32
    private static let madeLimit = 64
    /// The fill's pause between frames, so it never keeps the cores busy.
    private static let fillPause: Duration = .milliseconds(250)

    private var makes: Bool { trickplay == nil && source != nil }

    func reset(_ trickplay: Trickplay?, preview: ScrubPreviewSource? = nil, context: (@MainActor () -> ScrubPreviewContext?)? = nil) {
        generation += 1
        worker?.cancel()
        fill?.cancel()
        workerSerial += 1
        scrubMaker?.cancel()
        fillMaker?.cancel()
        self.trickplay = trickplay
        source = trickplay == nil ? preview : nil
        self.context = context
        cache = [:]
        recent = []
        pending = []
        have = []
        missed = []
        worker = nil
        fill = nil
        ready = nil
        scrubMaker = nil
        fillMaker = nil
        wanted = nil
        lastImage = nil
        unavailable = false
        failures = 0
        pacer.reset()
        guard let source = self.source else { return }
        let part = source.part
        let current = generation
        ready = Task {
            let slots = await ScrubPreviews.disk.slots(part: part)
            if current == self.generation { have = slots }
        }
        guard !FakePlex.isActive else { return }
        fill = Task(priority: .background) {
            await runFill(source, generation: current)
        }
    }

    var hasFrames: Bool { trickplay != nil || (makes && !unavailable) }

    func index(at time: TimeInterval, duration: TimeInterval) -> Int? {
        if let trickplay { return trickplay.index(at: time) }
        return makes && !unavailable ? ScrubPreviewPlan.slot(at: time, duration: duration) : nil
    }

    func image(near time: TimeInterval) -> UIImage? {
        _ = landed
        if let trickplay {
            let index = trickplay.index(at: time)
            if let image = cache[index] { return image }
            decode(index, from: trickplay)
            for distance in 1...4 {
                if let image = cache[index - distance] ?? cache[index + distance] { return image }
            }
            return nil
        }
        guard makes, knownDuration > 0 else { return nil }
        let slot = ScrubPreviewPlan.slot(at: time, duration: knownDuration)
        if let image = cache[slot] { return image }
        for distance in 1...4 {
            if let image = cache[slot - distance] ?? cache[slot + distance] { return image }
        }
        return lastImage
    }

    // MARK: Frames made on request

    /// The thumb is at `time`: makes that slot's frame. The newest request wins, and a drag asks for one
    /// frame per pause (`ScrubPreviewPacer`), the first at once.
    func want(_ time: TimeInterval, duration: TimeInterval) {
        guard makes, !unavailable, duration > 0 else { return }
        knownDuration = duration
        let slot = ScrubPreviewPlan.slot(at: time, duration: duration)
        guard slot != wanted else { return }
        wanted = slot
        guard worker == nil else { return }
        let generation = generation
        workerSerial += 1
        let serial = workerSerial
        worker = Task { await work(generation: generation, serial: serial) }
    }

    /// The finger lifted: stale requests are dropped and the next scrub starts at once.
    func scrubEnded() {
        wanted = nil
        pacer.reset()
        worker?.cancel()
        worker = nil
        workerSerial += 1
        scrubMaker?.cancel()
    }

    private func work(generation: Int, serial: Int) async {
        defer { if serial == workerSerial { worker = nil } }
        await ready?.value
        while !Task.isCancelled, generation == self.generation {
            guard let first = wanted, cache[first] == nil, !missed.contains(first) else { return }
            let wait = pacer.delay(at: ContinuousClock.now)
            if wait > .zero { try? await Task.sleep(for: wait) }
            guard !Task.isCancelled, generation == self.generation, let slot = wanted else { return }
            if cache[slot] == nil, !missed.contains(slot) { await make(slot, generation: generation) }
        }
    }

    private func make(_ slot: Int, generation: Int) async {
        guard let source else { return }
        let started = ContinuousClock.now
        var data: Data?
        var origin = "disk"
        if have.contains(slot) { data = await ScrubPreviews.disk.data(part: source.part, slot: slot) }
        if data == nil {
            origin = "made"
            let maker = scrubMaker ?? FrameMaker(url: source.url)
            if generation == self.generation { scrubMaker = maker }
            data = await maker.jpeg(at: ScrubPreviewPlan.time(of: slot, duration: knownDuration))
            if let data {
                await ScrubPreviews.disk.store(data, part: source.part, slot: slot)
                if generation == self.generation { have.insert(slot) }
            }
        }
        guard generation == self.generation, !Task.isCancelled else { return }
        guard let data, let image = await FrameDecoding.decode(data) else {
            missed.insert(slot)
            failures += 1
            // A file the generator cannot read at all (no picture track, a stream it cannot seek) leaves the time only.
            if failures >= 3, cache.isEmpty { unavailable = true }
            Diag.event(.player, "scrub.frame.failed", ["slot": slot, "ms": Diag.ms(since: started)], .debug)
            return
        }
        guard generation == self.generation else { return }
        failures = 0
        store(image, at: slot, limit: Self.madeLimit)
        lastImage = image
        landed += 1
        Diag.event(.player, "scrub.frame", ["slot": slot, "origin": origin, "ms": Diag.ms(since: started), "bytes": data.count], .debug)
    }

    // MARK: Frames made in the background

    private func runFill(_ source: ScrubPreviewSource, generation: Int) async {
        await ready?.value
        let watch = Task { [weak self] in
            for await update in NetworkPath.scrubFillUpdates() { self?.link = update }
        }
        defer { watch.cancel() }
        let begun = ContinuousClock.now
        var made = 0
        var misses = 0
        while !Task.isCancelled, generation == self.generation {
            guard let reading = context?() else { return }
            let policy = ScrubPreviewFillPolicy(
                isLocalFile: source.isLocal, isUnmeteredWiFi: link.isUnmeteredWiFi, saveData: link.saveData,
                isPlaying: reading.isPlaying, isStalled: reading.isStalled,
                isThermalSerious: ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
            )
            let order = ScrubPreviewPlan.fillOrder(playhead: reading.playhead, duration: reading.duration)
            guard policy.allows, !reading.isScrubbing, !order.isEmpty else {
                try? await Task.sleep(for: .seconds(2))
                continue
            }
            guard let slot = order.first(where: { !have.contains($0) && !missed.contains($0) }) else {
                Diag.event(.player, "scrub.fill.done", ["frames": made, "ms": Diag.ms(since: begun)], .debug)
                return
            }
            let maker = fillMaker ?? FrameMaker(url: source.url)
            fillMaker = maker
            let started = ContinuousClock.now
            let data = await maker.jpeg(at: ScrubPreviewPlan.time(of: slot, duration: reading.duration))
            guard !Task.isCancelled, generation == self.generation else { return }
            if let data {
                await ScrubPreviews.disk.store(data, part: source.part, slot: slot)
                guard generation == self.generation else { return }
                have.insert(slot)
                made += 1
                misses = 0
                Diag.event(.player, "scrub.fill", ["slot": slot, "frames": made, "ms": Diag.ms(since: started), "bytes": data.count], .debug)
            } else {
                missed.insert(slot)
                misses += 1
                // Five in a row: the file gives no frames, so the fill stops.
                if misses >= 5 { return }
            }
            try? await Task.sleep(for: Self.fillPause)
        }
    }

    // MARK: Plex's index

    private func store(_ image: UIImage, at index: Int, limit: Int) {
        if cache.updateValue(image, forKey: index) == nil { recent.append(index) }
        if recent.count > limit {
            cache[recent.removeFirst()] = nil
        }
    }

    private func decode(_ index: Int, from trickplay: Trickplay) {
        guard pending.insert(index).inserted else { return }
        let generation = generation
        Task {
            let image = await FrameDecoding.decode(trickplay, at: index)
            guard generation == self.generation else { return }
            pending.remove(index)
            guard let image else { return }
            store(image, at: index, limit: Self.limit)
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

    @concurrent
    static func decode(_ data: Data) async -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        return await image.byPreparingForDisplay() ?? image
    }
}
