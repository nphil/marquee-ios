import MarqueeCore
import QuartzCore
import UIKit

/// A display link on one screen that calls `tick` once per frame of that screen while it runs.
@MainActor
final class ScrollDriver: NSObject {
    private var link: CADisplayLink?
    private weak var screen: UIScreen?
    private let tick: @MainActor (_ frame: TimeInterval) -> Void

    init(screen: UIScreen?, tick: @escaping @MainActor (_ frame: TimeInterval) -> Void) {
        self.screen = screen
        self.tick = tick
    }

    var isRunning: Bool { link != nil }

    func start() {
        guard link == nil else { return }
        // The big screen's own link ticks at that screen's rate; the phone's is the fallback.
        let link = screen?.displayLink(withTarget: self, selector: #selector(fire(_:)))
            ?? CADisplayLink(target: self, selector: #selector(fire(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func fire(_ link: CADisplayLink) {
        tick(link.targetTimestamp - link.timestamp)
    }
}

/// Moves a page's focus with the thumb on the remote, continuously (DESIGN §8.9). The thumb's travel scrolls
/// the page a fraction of a step at a time; the focus steps when the travel passes half of one, and lifting
/// either settles on the nearest item or, after a flick, coasts as `UIScrollView` does. Everything is applied
/// on the big screen's display link, at most once per frame, whatever rate the inputs arrive at; the page
/// draws `GlassesPage.glide`, which follows the target on a critically damped spring so a late or uneven
/// input does not show as a jump.
@MainActor
final class GlassesScroller {
    typealias Cue = @MainActor (HapticCue) -> Void

    private enum Mode { case idle, tracking, coasting }

    private struct Pending {
        var dx: Double
        var dy: Double
        var time: TimeInterval
        /// Whether `time` is when the touch happened rather than when the input arrived.
        var stamped: Bool
    }

    /// Spring rates (radians a second): following the thumb is stiff, 2 / omega behind a steady drag; a
    /// retarget by key or VoiceOver settles in about the 260 ms of `Motion.spring`.
    private static let followRate = 100.0
    private static let settleRate = 24.0
    /// Points a second a thumb must be moving at lifting for the page to carry on.
    private static let flick = 200.0

    private let screen: () -> UIScreen?
    private var driver: ScrollDriver?
    private weak var page: GlassesPage?
    private var mode = Mode.idle
    private var pan = PanScroll()
    private var track = FingerTrack()
    private var coast = Coast(from: 0, speed: 0)
    private var coastStart: TimeInterval = 0
    private var pending: Pending?
    private var rowSpring = CriticalSpring(0)
    private var columnSpring = CriticalSpring(0)
    private var springRow = 0
    private var cue: Cue?
    private var linked = false
    private var lastTick: TimeInterval = 0

    /// A touch's delay in seconds as the page applied it, and whether it came over a link.
    var onLatency: (@MainActor (_ seconds: TimeInterval, _ linked: Bool) -> Void)?

    init(screen: @escaping () -> UIScreen?) {
        self.screen = screen
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    // MARK: Input

    /// The thumb touched down: a coast stops where it is.
    func touchDown(on page: GlassesPage) {
        guard mode == .coasting, self.page === page else { return }
        settle()
        run()
    }

    /// The thumb is `dx`, `dy` points from where it touched down. `time` is when, on this phone's clock, or
    /// nil when not known.
    func pan(dx: Double, dy: Double, at time: TimeInterval?, on page: GlassesPage, linked: Bool, cue: @escaping Cue) {
        attach(page)
        self.cue = cue
        self.linked = linked
        if mode == .coasting { settle() }
        if mode == .idle {
            mode = .tracking
            pan = PanScroll()
            track = FingerTrack()
        }
        pending = Pending(dx: dx, dy: dy, time: time ?? Self.now, stamped: time != nil)
        run()
    }

    /// The thumb lifted, moving at `vx`, `vy` points a second.
    func lifted(vx: Double, vy: Double, on page: GlassesPage) {
        guard mode == .tracking, self.page === page else { return interrupt() }
        flush(now: Self.now)
        guard let axis = pan.axis else { return interrupt() }
        let speed = axis == .horizontal ? vx : vy
        let against = pan.blocked != 0 && (speed > 0) == (pan.blocked > 0)
        if abs(speed) >= Self.flick, !against {
            coast = Coast(from: pan.travel, speed: speed / PanScroll.step(axis))
            coastStart = Self.now
            mode = .coasting
        } else {
            settle()
        }
        run()
    }

    /// Any other input: what the thumb was doing ends where it is.
    func interrupt() {
        guard mode != .idle else { return }
        settle()
        run()
    }

    /// The focus moved by a key, VoiceOver or a step of the legacy swipe: the page glides there.
    func moved(on page: GlassesPage, from before: (row: Int, column: Int)) {
        attach(page, row: before.row, column: before.column)
        run()
    }

    /// The display went away or the page closed.
    func stop() {
        driver?.stop()
        driver = nil
        page?.glide = nil
        page = nil
        mode = .idle
        pending = nil
        pan = PanScroll()
    }

    // MARK: Frames

    private func attach(_ page: GlassesPage, row: Int? = nil, column: Int? = nil) {
        if self.page !== page {
            self.page?.glide = nil
            self.page = page
            mode = .idle
            pending = nil
            pan = PanScroll()
        }
        guard page.glide == nil else { return }
        springRow = row ?? page.focus.row
        rowSpring = CriticalSpring(Double(springRow))
        columnSpring = CriticalSpring(Double(column ?? page.focus.column))
    }

    private func run() {
        let driver = driver ?? ScrollDriver(screen: screen()) { [weak self] frame in self?.tick(frame: frame) }
        self.driver = driver
        guard !driver.isRunning else { return }
        lastTick = Self.now
        driver.start()
    }

    private func tick(frame: TimeInterval) {
        let now = Self.now
        let dt = min(max(now - lastTick, 0.001), 0.05)
        lastTick = now
        guard let page else { return halt() }
        switch mode {
        case .tracking:
            flush(now: now)
        case .coasting:
            let seconds = now - coastStart
            take(pan.advance(to: coast.position(at: seconds)))
            if seconds >= coast.duration || pan.blocked != 0 { settle() }
        case .idle:
            break
        }
        let (row, column) = targets(of: page, now: now, frame: frame)
        if page.focus.row != springRow {
            // A new row brings its own column; its tiles were drawn there already.
            springRow = page.focus.row
            columnSpring = CriticalSpring(Double(page.focus.column))
        }
        let rate = mode == .idle ? Self.settleRate : Self.followRate
        if reduceMotion {
            rowSpring = CriticalSpring(row)
            columnSpring = CriticalSpring(column)
        } else {
            rowSpring.step(toward: row, omega: rate, dt: dt)
            columnSpring.step(toward: column, omega: rate, dt: dt)
        }
        let atRest = rowSpring.isSettled(at: row) && columnSpring.isSettled(at: column)
        if atRest {
            rowSpring = CriticalSpring(row)
            columnSpring = CriticalSpring(column)
        }
        let resting = (mode == .idle && atRest) || reduceMotion
        page.glide = resting ? nil : GlassesGlide(row: rowSpring.value, column: columnSpring.value)
        // A thumb down and still has nothing to move until its next input starts the link again.
        if atRest, mode != .coasting, pending == nil { halt() }
    }

    /// Where the focus is drawn, in rows and columns: the focused item plus the part of a step the thumb has
    /// travelled, looked ahead of the newest reading.
    private func targets(of page: GlassesPage, now: TimeInterval, frame: TimeInterval) -> (row: Double, column: Double) {
        var lead = pan.fraction
        if mode == .tracking, pan.blocked == 0, let guess = track.predicted(at: now, lead: frame) {
            let limit = 0.5 + PanScroll.hysteresis
            lead = min(max(guess - Double(pan.taken), -limit), limit)
        }
        let rows = page.rows
        let row = min(max(page.focus.row, 0), max(rows.count - 1, 0))
        let columns = rows.indices.contains(row) ? rows[row].tiles.count : 1
        var rowTarget = Double(page.focus.row)
        var columnTarget = Double(page.focus.column)
        switch pan.axis {
        case .vertical: rowTarget += lead
        case .horizontal: columnTarget += lead
        case nil: break
        }
        return (
            min(max(rowTarget, 0), Double(max(rows.count - 1, 0))),
            min(max(columnTarget, 0), Double(max(columns - 1, 0)))
        )
    }

    /// Reads the newest input: how late it is, whole steps now due, and a reading for the guess ahead.
    private func flush(now: TimeInterval) {
        guard let input = pending else { return }
        pending = nil
        if input.stamped { onLatency?(now - input.time, linked) }
        take(pan.moved(dx: input.dx, dy: input.dy))
        if pan.axis != nil { track.add(pan.travel, at: input.time) }
    }

    /// Steps the focus `count` whole items along the locked axis, one haptic for them all: a step, or the
    /// end when the list ran out.
    private func take(_ count: Int) {
        guard count != 0, let page, let axis = pan.axis else { return }
        let forward = count > 0
        let move: FocusMove = axis == .horizontal ? (forward ? .right : .left) : (forward ? .down : .up)
        var done = 0
        var refused = false
        for _ in 0..<abs(count) {
            guard page.focus.move(move) == .moved else {
                refused = true
                break
            }
            page.onMove?()
            done += 1
        }
        pan.took(forward ? done : -done)
        if refused { pan.refused(forward ? 1 : -1) }
        if refused { cue?(.edge) } else if done > 0 { cue?(.focusStep) }
    }

    /// The thumb stopped moving the page: the focus lands on the nearest item.
    private func settle() {
        take(pan.settling())
        mode = .idle
        pending = nil
        pan = PanScroll()
    }

    private func halt() {
        driver?.stop()
        if mode == .idle { page?.glide = nil }
    }
}
