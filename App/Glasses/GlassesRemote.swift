import CoreHaptics
import CoreMotion
import MarqueeCore
import SwiftUI
import UIKit

/// The iPhone as the glasses' remote (DESIGN §8.12): a window over the phone app whose whole screen
/// takes the gestures, dimmed while it shows.
@MainActor
final class GlassesTakeover {
    /// The remote's own window, told apart from the phone app's.
    final class Window: UIWindow {}

    /// Screen brightness while the remote shows; the phone's own level comes back after.
    private static let dimmed: CGFloat = 0.15

    private var window: Window?
    private var brightness: CGFloat?
    private var observers: [NSObjectProtocol] = []

    nonisolated init() {}

    func show(center: GlassesCenter, navigator: GlassesNavigator, store: ThemeStore) {
        guard window == nil, let scene = GlassesCenter.phoneScene() else { return }
        let host = RemoteHost(rootView: GlassesRemoteRoot(center: center, navigator: navigator, store: store))
        host.overrideUserInterfaceStyle = .dark
        host.view.accessibilityViewIsModal = true
        let window = Window(windowScene: scene)
        window.windowLevel = .normal + 1
        window.rootViewController = host
        window.makeKeyAndVisible()
        self.window = window
        dim()
        let notifications = NotificationCenter.default
        observers = [
            notifications.addObserver(forName: UIScene.willDeactivateNotification, object: scene, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restoreBrightness() }
            },
            notifications.addObserver(forName: UIScene.didActivateNotification, object: scene, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dim() }
            },
        ]
        UIAccessibility.post(notification: .screenChanged, argument: host.view)
    }

    func hide() {
        guard let window else { return }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        restoreBrightness()
        window.isHidden = true
        self.window = nil
        window.windowScene?.windows.first { !($0 is Window) && !$0.isHidden }?.makeKey()
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }

    private func dim() {
        guard let screen = window?.windowScene?.screen else { return }
        if brightness == nil { brightness = screen.brightness }
        screen.brightness = Self.dimmed
    }

    private func restoreBrightness() {
        guard let brightness, let screen = window?.windowScene?.screen else { return }
        screen.brightness = brightness
        self.brightness = nil
    }
}

/// Hides the status bar and home indicator, and holds the screen edges for the remote's own gestures.
private final class RemoteHost: UIHostingController<GlassesRemoteRoot> {
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
}

/// The remote follows the active theme's dark side, as the glasses do.
struct GlassesRemoteRoot: View {
    let center: GlassesCenter
    let navigator: GlassesNavigator
    let store: ThemeStore

    var body: some View {
        GlassesRemoteView(center: center, navigator: navigator)
            .environment(\.theme, store.selected(for: .dark))
            .environment(\.colorScheme, .dark)
    }
}

/// What the phone shows while it is the remote: the focused thing for a glance, and the gestures,
/// faint. Nothing on it is a target; the whole screen is one surface.
struct GlassesRemoteView: View {
    let center: GlassesCenter
    let navigator: GlassesNavigator
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.canvas
                .ignoresSafeArea()
            VStack(spacing: Space.s3) {
                Spacer()
                Image(systemName: "eyeglasses")
                    .font(.largeTitle)
                    .foregroundStyle(theme.ink3)
                Text(navigator.focusTitle)
                    .textRole(.title)
                    .foregroundStyle(theme.ink2)
                    .lineLimit(2)
                if let detail = navigator.focusDetail {
                    Text(detail)
                        .textRole(.body)
                        .foregroundStyle(theme.ink3)
                        .lineLimit(1)
                }
                Spacer()
                Text("Swipe to move · Tap to choose\nSwipe in from the left edge to go back\nHold for options, or in a video to scrub")
                    .textRole(.caption)
                    .foregroundStyle(theme.ink3)
            }
            .multilineTextAlignment(.center)
            .padding(Space.inset)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            RemoteSurface(center: center, navigator: navigator, label: navigator.focusTitle, value: navigator.focusDetail)
                .ignoresSafeArea()
                .accessibilityIdentifier("glasses.remote")
        }
    }
}

private struct RemoteSurface: UIViewRepresentable {
    let center: GlassesCenter
    let navigator: GlassesNavigator
    let label: String
    let value: String?

    func makeUIView(context: Context) -> RemoteSurfaceView {
        RemoteSurfaceView(center: center, navigator: navigator)
    }

    func updateUIView(_ view: RemoteSurfaceView, context: Context) {
        view.describe(label: label, value: value)
    }
}

/// The remote's one touch surface: swipes step the focus and a flick coasts on; a tap chooses; a swipe in
/// from the left edge goes back; a hold opens the options or, in a video, scrubs while the thumb slides.
/// With tilt on, holding the thumb still after a swipe lets the phone's tilt keep scrolling, and tilt
/// fine-tunes a scrub. Motion runs only while the thumb is down.
final class RemoteSurfaceView: UIView {
    private enum Phase {
        case idle
        /// Down and not yet moved past the axis lock.
        case touching
        /// Started at the left edge: a swipe right from there goes back.
        case edge
        case swiping
        /// Swiped, then held still: tilt scrolls.
        case tilting
        case held
        /// The touch already did its one thing (went back); the rest of it is ignored.
        case done
    }

    /// A still thumb becomes a hold after this long.
    private static let holdDelay: Duration = .milliseconds(450)
    /// A thumb held still this long after a swipe hands scrolling to tilt.
    private static let stillDelay: Duration = .milliseconds(350)
    /// Touches starting this close to the left edge can go back once they travel `backTravel` right.
    private static let edgeWidth: CGFloat = 20
    private static let backTravel: CGFloat = 80
    /// Tilt's top rates: focus steps a second when scrolling, playhead seconds a second when scrubbing.
    private static let scrollRate = 12.0
    private static let scrubRate = 30.0

    private weak var center: GlassesCenter?
    private weak var navigator: GlassesNavigator?
    private let haptics = RemoteHaptics()
    private let tilt = RemoteTilt()

    private var phase = Phase.idle
    private weak var tracked: UITouch?
    private var start = CGPoint.zero
    private var tiltAnchor = CGPoint.zero
    private var steps = SwipeSteps()
    private var samples: [(point: CGPoint, time: TimeInterval)] = []
    private var holdTask: Task<Void, Never>?
    private var stillTask: Task<Void, Never>?
    private var coastTask: Task<Void, Never>?
    /// Tilt scrolling stops pushing into an end it has met, until it turns the other way.
    private var tiltBlocked: FocusMove?

    init(center: GlassesCenter, navigator: GlassesNavigator) {
        self.center = center
        self.navigator = navigator
        super.init(frame: .zero)
        isMultipleTouchEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = [.allowsDirectInteraction]
        accessibilityHint = "Swipe to move, tap to choose, swipe in from the left edge to go back, hold for options or to scrub."
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Back") { [weak self] _ in self?.send(.back) != nil },
            UIAccessibilityCustomAction(name: "Options") { [weak self] _ in
                guard let self, let navigator else { return false }
                if let player = navigator.player { navigator.openTracks(player) } else { send(.holdBegan) }
                return true
            },
            UIAccessibilityCustomAction(name: "Use the Phone App") { [weak self] _ in
                self?.center?.showPhoneApp()
                return true
            },
        ]
        navigator.onCue = { [weak self] cue in self?.haptics.play(cue) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func describe(label: String, value: String?) {
        let changed = accessibilityLabel != nil && accessibilityLabel != label
        accessibilityLabel = label
        accessibilityValue = value
        if changed, UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: label)
        }
    }

    // MARK: VoiceOver

    override func accessibilityActivate() -> Bool {
        send(.select) != nil
    }

    override func accessibilityPerformEscape() -> Bool {
        send(.back) != nil
    }

    override func accessibilityPerformMagicTap() -> Bool {
        send(.select) != nil
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        let move: FocusMove? = switch direction {
        case .up: .down
        case .down: .up
        case .left: .right
        case .right: .left
        default: nil
        }
        guard let move else { return false }
        return send(.move(move)) != nil
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard phase == .idle, let touch = touches.first else { return }
        coastTask?.cancel()
        tracked = touch
        start = touch.location(in: self)
        samples = [(start, touch.timestamp)]
        steps = SwipeSteps()
        phase = start.x <= Self.edgeWidth ? .edge : .touching
        holdTask = Task { [weak self] in
            try? await Task.sleep(for: Self.holdDelay)
            guard !Task.isCancelled, let self, phase == .touching || phase == .edge else { return }
            phase = .held
            holdBegan()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = tracked, touches.contains(touch) else { return }
        let point = touch.location(in: self)
        samples.append((point, touch.timestamp))
        if samples.count > 6 { samples.removeFirst(samples.count - 6) }
        let dx = point.x - start.x, dy = point.y - start.y
        switch phase {
        case .idle, .done:
            return
        case .held:
            send(.slide(dx: dx, width: bounds.width))
        case .edge:
            if dx >= Self.backTravel, dx > abs(dy) {
                holdTask?.cancel()
                phase = .done
                send(.back)
            } else if abs(dy) >= SwipeSteps.lockDistance, abs(dy) > dx {
                phase = .touching
                swipe(dx: dx, dy: dy)
            } else if hypot(dx, dy) >= SwipeSteps.lockDistance {
                holdTask?.cancel()
            }
        case .tilting:
            guard hypot(point.x - tiltAnchor.x, point.y - tiltAnchor.y) >= SwipeSteps.lockDistance else { return }
            tilt.stop()
            phase = .swiping
            swipe(dx: dx, dy: dy)
        case .touching, .swiping:
            swipe(dx: dx, dy: dy)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = tracked, touches.contains(touch) else { return }
        let point = touch.location(in: self)
        let ended = phase
        finish()
        switch ended {
        case .touching:
            send(.select)
        case .edge:
            let velocity = velocity(at: (point, touch.timestamp))
            if point.x - start.x >= SwipeSteps.lockDistance, velocity.dx >= SwipeSteps.flickSpeed {
                send(.back)
            } else if hypot(point.x - start.x, point.y - start.y) < SwipeSteps.lockDistance {
                send(.select)
            }
        case .swiping, .tilting:
            let velocity = velocity(at: (point, touch.timestamp))
            let release = steps.released(vx: velocity.dx, vy: velocity.dy)
            if let step = release.step { send(.move(step)) }
            if let coast = release.coast { self.coast(coast.move, speed: coast.speed) }
        case .held:
            send(.holdEnded)
        case .idle, .done:
            break
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = tracked, touches.contains(touch) else { return }
        let ended = phase
        finish()
        if ended == .held { send(.holdEnded) }
    }

    private func finish() {
        holdTask?.cancel()
        stillTask?.cancel()
        tilt.stop()
        tracked = nil
        phase = .idle
    }

    private func swipe(dx: CGFloat, dy: CGFloat) {
        if hypot(dx, dy) >= SwipeSteps.lockDistance { holdTask?.cancel() }
        for move in steps.moved(dx: dx, dy: dy) { send(.move(move)) }
        guard steps.axis != nil else { return }
        phase = .swiping
        stillTask?.cancel()
        guard center?.tiltEnabled == true else { return }
        stillTask = Task { [weak self] in
            try? await Task.sleep(for: Self.stillDelay)
            guard !Task.isCancelled, let self, phase == .swiping else { return }
            tiltScroll()
        }
    }

    /// Points a second over the last few samples.
    private func velocity(at last: (point: CGPoint, time: TimeInterval)) -> CGVector {
        guard let first = samples.first, last.time > first.time else { return .zero }
        let seconds = last.time - first.time
        return CGVector(dx: (last.point.x - first.point.x) / seconds, dy: (last.point.y - first.point.y) / seconds)
    }

    // MARK: Hold, coast and tilt

    private func holdBegan() {
        send(.holdBegan)
        guard navigator?.player != nil, navigator?.scrub != nil, center?.tiltEnabled == true else { return }
        let drive = TiltDrive(topRate: Self.scrubRate)
        tilt.start { [weak self] roll, _, seconds in
            let amount = drive.amount(at: roll, for: seconds)
            guard amount != 0 else { return }
            self?.send(.nudge(amount))
        }
    }

    private func tiltScroll() {
        guard let axis = steps.axis else { return }
        phase = .tilting
        tiltAnchor = samples.last?.point ?? start
        tiltBlocked = nil
        var drive = TiltDrive(topRate: Self.scrollRate)
        tilt.start { [weak self] roll, pitch, seconds in
            guard let self else { return }
            // Tipping the top of the phone away scrolls down; tipping its right side down scrolls right.
            let count = drive.steps(at: axis == .horizontal ? roll : -pitch, for: seconds)
            guard count != 0 else { return }
            let move: FocusMove = axis == .horizontal ? (count > 0 ? .right : .left) : (count > 0 ? .down : .up)
            guard move != tiltBlocked else { return }
            tiltBlocked = nil
            for _ in 0..<abs(count) {
                if send(.move(move)) == .edge {
                    tiltBlocked = move
                    return
                }
            }
        }
    }

    /// A hard flick keeps stepping after the thumb lifts, slowing as it goes, and stops at an end.
    private func coast(_ move: FocusMove, speed: Double) {
        let step = move.isHorizontal ? SwipeSteps.stepAcross : SwipeSteps.stepDown
        let times = SwipeSteps.coast(speed: speed, step: step)
        coastTask = Task { [weak self] in
            var clock: TimeInterval = 0
            for time in times {
                try? await Task.sleep(for: .seconds(time - clock))
                clock = time
                guard !Task.isCancelled, let self, send(.move(move)) != .edge else { return }
            }
        }
    }

    @discardableResult
    private func send(_ input: GlassesInput) -> HapticCue? {
        guard let cue = navigator?.handle(input) else { return nil }
        haptics.play(cue)
        return cue
    }
}

/// Plays the remote's touch vocabulary (`HapticCue`) on the Taptic Engine.
@MainActor
private final class RemoteHaptics {
    private var engine: CHHapticEngine?
    private var patterns: [HapticCue: CHHapticPattern] = [:]

    init() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        engine = try? CHHapticEngine()
        engine?.playsHapticsOnly = true
        engine?.isAutoShutdownEnabled = true
        for cue in HapticCue.allCases {
            patterns[cue] = try? Self.pattern(cue)
        }
    }

    func play(_ cue: HapticCue) {
        guard let engine, let pattern = patterns[cue] else { return }
        // Auto shutdown stops the engine between cues, and a reset after an audio interruption leaves it
        // stopped; starting a running engine does nothing.
        try? engine.start()
        try? engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
    }

    private static func pattern(_ cue: HapticCue) throws -> CHHapticPattern {
        let events = cue.events.map { event in
            CHHapticEvent(
                eventType: event.duration > 0 ? .hapticContinuous : .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(event.intensity)),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(event.sharpness)),
                ],
                relativeTime: event.time,
                duration: event.duration
            )
        }
        return try CHHapticPattern(events: events, parameters: [])
    }
}

/// The phone's tilt from where it was when the reading started, about 30 times a second, only between
/// `start` and `stop`.
@MainActor
private final class RemoteTilt {
    typealias Reading = (_ roll: Double, _ pitch: Double, _ seconds: TimeInterval) -> Void

    private static let interval: TimeInterval = 1.0 / 30

    private let manager = CMMotionManager()
    private var reference: CMAttitude?
    private var reading: Reading?
    private var task: Task<Void, Never>?
    private var last: TimeInterval = 0

    func start(_ reading: @escaping Reading) {
        guard task == nil, manager.isDeviceMotionAvailable else { return }
        self.reading = reading
        reference = nil
        manager.deviceMotionUpdateInterval = Self.interval
        manager.startDeviceMotionUpdates()
        last = CACurrentMediaTime()
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.interval))
                guard !Task.isCancelled, let self else { return }
                read()
            }
        }
    }

    func stop() {
        guard task != nil else { return }
        task?.cancel()
        task = nil
        reading = nil
        reference = nil
        manager.stopDeviceMotionUpdates()
    }

    private func read() {
        let now = CACurrentMediaTime()
        let seconds = now - last
        last = now
        // Copies: the manager may hand back the same sample object until a new one arrives.
        guard let attitude = manager.deviceMotion?.attitude.copy() as? CMAttitude else { return }
        guard let reference else {
            reference = attitude
            return
        }
        attitude.multiply(byInverseOf: reference)
        reading?(attitude.roll, attitude.pitch, seconds)
    }
}
