import Foundation
import QuartzCore
import UIKit

/// Whether a browse page is scrolling and, with Diagnostic Logs on Detailed, how evenly it draws while it
/// does (after Stashy's browse scroll telemetry, measured on an iPhone 17 Pro).
///
/// The display link asks for the screen's top rate, 120 Hz on ProMotion, so a longer gap is the main thread
/// stalling and not the display idling down. It cannot see a frame only the compositor dropped; it does count
/// the main-thread spikes behind most SwiftUI judder. While a gesture runs the link only appends to arrays
/// and writes no observed state; the sorting, percentiles and log lines wait for the page to settle, so the
/// measuring stays out of the frames measured.
///
/// Per gesture the log gets `scroll.segment` for each phase (interacting, decelerating) and `scroll.end`
/// for the whole, with the frame rate, the 95th and 99th percentile and longest frame in ms, the share of
/// frames over 1.5 slots (`hitch_pct`), frames of 50 ms or more (`severe`), the 120 Hz slots missed
/// (`missed_120`), the spread of frame times (`judder_pct`) and `gaps_10_14_20_30_over`, the frames at or
/// under 10.5, 14.5, 20.5 and 30 ms and over. Beside them: artwork arrivals and the pages the gesture asked
/// for and how long each took.
@MainActor
final class ScrollMonitor: NSObject {
    static let shared = ScrollMonitor()

    /// Whether a page is moving under a finger, coasting or scrolling to a position. Plain, never observed,
    /// so reading it invalidates no view. Work that only redraws the screen and can wait asks (the guide's
    /// clock, the mini bar's progress); loading images never does.
    private(set) var isScrolling = false

    /// Whether a gesture is being measured, so a caller can skip its own timing when it is not.
    var isMeasuring: Bool { link != nil }

    private struct Frame {
        let interval: Double
        let target: Double
        let phase: Int
    }

    private struct Artwork {
        let milliseconds: Int
        let memoryHit: Bool
        let phase: Int
    }

    private struct Page {
        let items: Int
        let milliseconds: Int
        let phase: Int
    }

    /// A gesture that never reports idle should not keep growing the samples: ten minutes at 120 Hz.
    private static let capacity = 72_000

    private var link: CADisplayLink?
    private var frames: [Frame] = []
    private var artworks: [Artwork] = []
    private var pages: [Page] = []
    private var phases: [String] = []
    private var phase = 0
    private var surface = ""
    private var lastTimestamp = 0.0
    private var maximumHz = 60
    private var pageRequestedAt: ContinuousClock.Instant?

    private override init() {
        super.init()
    }

    /// The scroll view of `surface` started or stopped moving. `moving` is true while interacting,
    /// decelerating or animating, not while a finger only rests on it.
    func moving(_ moving: Bool, surface: String, phase name: String) {
        guard moving else {
            // The page of another surface can report its idle late, after this one began.
            guard surface == self.surface else { return }
            isScrolling = false
            self.surface = ""
            if link != nil { stop(reason: "idle") }
            return
        }
        isScrolling = true
        if link != nil, !Diag.detailed { stop(reason: "logging-off") }
        if link != nil, self.surface != surface { stop(reason: "surface-change") }
        self.surface = surface
        guard Diag.detailed else { return }
        if link == nil { start(phase: name) } else { setPhase(name) }
    }

    /// Waits, for at most five seconds, until nothing scrolls. For work that redraws a whole page and can
    /// wait a moment; the bound keeps a scroll view that never reported idle from holding it back.
    func untilSettled() async {
        var waited = 0
        while isScrolling, waited < 20, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            waited += 1
        }
    }

    /// A poster's art reached its cell: found in memory, or loaded since `start`.
    func artworkPublished(since start: ContinuousClock.Instant, memoryHit: Bool) {
        guard link != nil else { return }
        artworks.append(Artwork(milliseconds: Diag.ms(since: start), memoryHit: memoryHit, phase: phase))
    }

    /// A grid asked for its next page.
    func pageRequested() {
        guard link != nil, pageRequestedAt == nil else { return }
        pageRequestedAt = ContinuousClock.now
    }

    /// The page asked for landed, with `items` more titles in the grid.
    func pageAppended(items: Int) {
        guard link != nil, let requested = pageRequestedAt else { return }
        pageRequestedAt = nil
        pages.append(Page(items: max(0, items), milliseconds: Diag.ms(since: requested), phase: phase))
    }

    /// The name a surface goes by in the log, from the `#fileID` of the file that hosts its scroll view.
    static func name(ofFile fileID: String) -> String {
        let file = fileID.split(separator: "/").last.map(String.init) ?? fileID
        return file.hasSuffix(".swift") ? String(file.dropLast(6)) : file
    }

    // MARK: Measuring

    private func setPhase(_ name: String) {
        if let index = phases.firstIndex(of: name) {
            phase = index
        } else {
            phases.append(name)
            phase = phases.count - 1
        }
    }

    private func start(phase name: String) {
        phases = []
        setPhase(name)
        frames.removeAll(keepingCapacity: true)
        artworks.removeAll(keepingCapacity: true)
        pages.removeAll(keepingCapacity: true)
        pageRequestedAt = nil
        lastTimestamp = 0
        let screen = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive && $0.session.role == .windowApplication }?
            .screen
        maximumHz = max(60, screen?.maximumFramesPerSecond ?? 60)
        let link = screen?.displayLink(withTarget: self, selector: #selector(fire(_:)))
            ?? CADisplayLink(target: self, selector: #selector(fire(_:)))
        let maximum = Float(maximumHz)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(80, maximum), maximum: maximum, preferred: maximum)
        link.add(to: .main, forMode: .common)
        self.link = link
        Diag.event(.ui, "scroll.start", ["surface": surface, "phase": name, "requested_hz": maximumHz], .debug)
    }

    private func stop(reason: String) {
        if phases.count > 1 {
            for (index, name) in phases.enumerated() {
                report(
                    "scroll.segment", phase: name, reason: nil, frames: frames.filter { $0.phase == index },
                    artworks: artworks.filter { $0.phase == index }, pages: pages.filter { $0.phase == index }
                )
            }
        }
        report("scroll.end", phase: "all", reason: reason, frames: frames, artworks: artworks, pages: pages)
        link?.invalidate()
        link = nil
        frames.removeAll(keepingCapacity: true)
        artworks.removeAll(keepingCapacity: true)
        pages.removeAll(keepingCapacity: true)
        pageRequestedAt = nil
        lastTimestamp = 0
    }

    @objc private func fire(_ link: CADisplayLink) {
        let timestamp = link.timestamp
        if lastTimestamp > 0 {
            if frames.count >= Self.capacity { frames.removeFirst(Self.capacity / 6) }
            let target = max(1 / Double(maximumHz), link.targetTimestamp - timestamp)
            frames.append(Frame(interval: timestamp - lastTimestamp, target: target, phase: phase))
        }
        lastTimestamp = timestamp
    }

    // MARK: Reporting

    private func report(
        _ name: String, phase: String, reason: String?, frames: [Frame], artworks: [Artwork], pages: [Page]
    ) {
        guard !frames.isEmpty else { return }
        let intervals = frames.map(\.interval)
        let ordered = intervals.sorted()
        let seconds = intervals.reduce(0, +)
        let mean = seconds / Double(intervals.count)
        let spread = (intervals.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(intervals.count)).squareRoot()
        let slot = 1 / Double(maximumHz)
        let target = Self.percentile(frames.map(\.target).sorted(), 0.5)
        let hitches = frames.count { $0.interval > max($0.target, slot) * 1.5 }
        let severe = frames.count { $0.interval >= 0.05 }
        let missed = frames.reduce(0) { $0 + max(0, Int(($1.interval / slot).rounded()) - 1) }
        let loads = artworks.filter { !$0.memoryHit }.map { Double($0.milliseconds) }.sorted()
        let pageLoads = pages.map { Double($0.milliseconds) }.sorted()
        let fields: [(String, Any?)] = [
            ("surface", surface),
            ("phase", phase),
            ("reason", reason),
            ("sec", Self.rounded(seconds, 2)),
            ("fps", Self.rounded(Double(intervals.count) / max(seconds, 0.001), 1)),
            ("target_hz", Self.rounded(1 / max(target, 0.001), 0)),
            ("avg_ms", Self.rounded(mean * 1000, 2)),
            ("p95_ms", Self.rounded(Self.percentile(ordered, 0.95) * 1000, 2)),
            ("p99_ms", Self.rounded(Self.percentile(ordered, 0.99) * 1000, 2)),
            ("max_ms", Self.rounded((ordered.last ?? 0) * 1000, 2)),
            ("hitch_pct", Self.rounded(Double(hitches) * 100 / Double(intervals.count), 1)),
            ("severe", severe),
            ("missed_\(maximumHz)", missed),
            ("judder_pct", Self.rounded(spread / max(mean, 0.001) * 100, 1)),
            ("gaps_10_14_20_30_over", Self.gaps(intervals)),
            ("art_publishes", artworks.count),
            ("art_memory_hits", artworks.count { $0.memoryHit }),
            ("art_load_p95_ms", loads.isEmpty ? nil : Self.rounded(Self.percentile(loads, 0.95), 0)),
            ("page_appends", pages.count),
            ("page_items", pages.reduce(0) { $0 + $1.items }),
            ("page_load_p95_ms", pageLoads.isEmpty ? nil : Self.rounded(Self.percentile(pageLoads, 0.95), 0)),
        ]
        Diag.event(.ui, name, list: fields, .debug)
    }

    /// Frames at or under 10.5 ms (about 120 Hz), 14.5 (80), 20.5 (60 or one missed 120 Hz slot), 30, and over.
    private static func gaps(_ intervals: [Double]) -> String {
        var buckets = [0, 0, 0, 0, 0]
        for interval in intervals {
            switch interval * 1000 {
            case ...10.5: buckets[0] += 1
            case ...14.5: buckets[1] += 1
            case ...20.5: buckets[2] += 1
            case ...30: buckets[3] += 1
            default: buckets[4] += 1
            }
        }
        return buckets.map(String.init).joined(separator: "/")
    }

    private static func percentile(_ ordered: [Double], _ fraction: Double) -> Double {
        guard !ordered.isEmpty else { return 0 }
        return ordered[min(ordered.count - 1, Int((Double(ordered.count - 1) * fraction).rounded()))]
    }

    private static func rounded(_ value: Double, _ places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (value * scale).rounded() / scale
    }
}
