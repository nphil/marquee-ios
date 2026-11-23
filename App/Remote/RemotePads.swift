import LumaRemoteCore
import LumaRemoteKit
import MarqueeCore
import SwiftUI

extension DpadKey {
    var remoteKey: RemoteKey {
        switch self {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .ok: .ok
        }
    }
}

extension RemotePadMode {
    var symbol: String {
        switch self {
        case .dpad: "dpad"
        case .joystick: "gamecontroller"
        case .touchpad: "hand.draw"
        }
    }

    var label: String {
        switch self {
        case .dpad: "Directional pad"
        case .joystick: "Joystick"
        case .touchpad: "Touchpad"
        }
    }
}

/// One of the four arrows around a pad's centre.
private struct Arrow: Identifiable {
    let key: DpadKey
    /// The direction it points, clockwise from the right as the screen draws it.
    let heading: Angle
    let chevron: String

    var id: DpadKey { key }

    static let all = [
        Arrow(key: .up, heading: .degrees(270), chevron: "chevron.up"),
        Arrow(key: .right, heading: .degrees(0), chevron: "chevron.right"),
        Arrow(key: .down, heading: .degrees(90), chevron: "chevron.down"),
        Arrow(key: .left, heading: .degrees(180), chevron: "chevron.left"),
    ]

    func offset(at distance: CGFloat) -> CGSize {
        CGSize(width: distance * cos(heading.radians), height: distance * sin(heading.radians))
    }
}

/// The pad's area: the D-pad, the joystick or the touchpad, with the switch between them along its foot.
struct RemotePad: View {
    let size: CGSize
    let mode: RemotePadMode
    let ready: Bool
    let onMode: (RemotePadMode) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// From this height the pad shows its switch; a shorter pad is only the pad.
    private static let switchMinHeight: CGFloat = 120

    var body: some View {
        VStack(spacing: Space.s3) {
            stage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .disabled(!ready)
            if size.height >= Self.switchMinHeight {
                RemoteModeSwitch(mode: mode, onMode: onMode)
            }
        }
    }

    private var stage: some View {
        ZStack {
            switch mode {
            case .dpad: RemoteDpad().transition(.opacity)
            case .joystick: RemoteJoystick().transition(.opacity)
            case .touchpad: RemoteTouchPane().transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: mode)
    }
}

/// Three glyph segments on a capsule: which pad the area shows.
private struct RemoteModeSwitch: View {
    let mode: RemotePadMode
    let onMode: (RemotePadMode) -> Void

    @Environment(RemoteModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let maxWidth: CGFloat = 168

    var body: some View {
        HStack(spacing: 0) {
            ForEach(RemotePadMode.allCases, id: \.self) { candidate in
                segment(candidate)
            }
        }
        .frame(maxWidth: Self.maxWidth)
        .frame(height: Size.target)
        .background(theme.glassRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(theme.edge, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private func segment(_ candidate: RemotePadMode) -> some View {
        let selected = candidate == mode
        return Button {
            guard !selected else { return }
            model.feedback.tick()
            onMode(candidate)
        } label: {
            Image(systemName: candidate.symbol)
                .font(.system(size: Space.s5, weight: .semibold))
                .foregroundStyle(selected ? theme.accentInk : theme.ink2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { Capsule().fill(selected ? theme.accent : .clear) }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: selected)
                .padding(Space.s1)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(candidate.label))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("remote.mode.\(candidate.rawValue)")
    }
}

// MARK: - D-pad

/// The classic pad: four wedges around OK, pressed where the finger lands. Pressing is a tap, holding repeats like
/// the remote's, and a finger that slides off lets go without pressing.
struct RemoteDpad: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.isEnabled) private var isEnabled
    @GestureState private var touching = false
    @State private var landed: DpadKey?
    @State private var slidOff = false

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            DpadPlate(side: side, lit: landed)
                .frame(width: side, height: side)
                .contentShape(Circle())
                .gesture(drag(radius: side / 2))
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .opacity(isEnabled ? 1 : RemoteSize.unavailable)
        .onChange(of: touching) { _, touching in
            if !touching { finish(cancelled: true) }
        }
        .accessibilityRepresentation { PadAccessibility(model: model) }
        .accessibilityIdentifier("remote.dpad")
    }

    private func drag(radius: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($touching) { _, touching, _ in touching = true }
            .onChanged { value in
                if landed == nil, !slidOff {
                    let point = CGPoint(x: value.startLocation.x - radius, y: value.startLocation.y - radius)
                    guard let key = dpadKey(at: point, radius: radius) else {
                        slidOff = true
                        return
                    }
                    landed = key
                    model.feedback.press()
                    model.pressBegan(key.remoteKey)
                } else if let key = landed, hypot(value.translation.width, value.translation.height) > RemoteSize.slideOff {
                    landed = nil
                    slidOff = true
                    model.pressCancelled(key.remoteKey)
                }
            }
            .onEnded { _ in finish(cancelled: false) }
    }

    private func finish(cancelled: Bool) {
        if let key = landed {
            if cancelled { model.pressCancelled(key.remoteKey) } else { model.pressEnded(key.remoteKey) }
        }
        landed = nil
        slidOff = false
    }
}

/// What VoiceOver gets for a pad: the five buttons.
private struct PadAccessibility: View {
    let model: RemoteModel

    var body: some View {
        VStack {
            Button("Up") { model.tap(.up) }
            HStack {
                Button("Left") { model.tap(.left) }
                Button("Select") { model.tap(.ok) }
                Button("Right") { model.tap(.right) }
            }
            Button("Down") { model.tap(.down) }
        }
    }
}

private struct DpadPlate: View {
    let side: CGFloat
    let lit: DpadKey?

    @Environment(\.theme) private var theme

    /// Where the arrows sit, as a share of the radius.
    private static let reach: CGFloat = 0.72
    private static let chevron: CGFloat = 0.2
    private static let check: CGFloat = 0.2

    var body: some View {
        let radius = side / 2
        ZStack {
            Circle().fill(theme.glassRaised)
            if let lit, let arrow = Arrow.all.first(where: { $0.key == lit }) {
                Wedge(direction: arrow.heading, inner: DpadGeometry.okRadius).fill(theme.focus)
            }
            Dividers(inner: DpadGeometry.okRadius).stroke(theme.edge, lineWidth: 1)
            Circle().strokeBorder(theme.edge, lineWidth: 1)
            ForEach(Arrow.all) { arrow in
                Image(systemName: arrow.chevron)
                    .font(.system(size: radius * Self.chevron, weight: .semibold))
                    .foregroundStyle(lit == arrow.key ? theme.focusInk : theme.ink2)
                    .offset(arrow.offset(at: radius * Self.reach))
            }
            Circle()
                .fill(lit == .ok ? theme.focus : theme.accent)
                .frame(width: side * DpadGeometry.okRadius, height: side * DpadGeometry.okRadius)
                .overlay {
                    Image(systemName: "checkmark")
                        .font(.system(size: side * Self.check, weight: .semibold))
                        .foregroundStyle(lit == .ok ? theme.focusInk : theme.accentInk)
                }
        }
    }
}

/// A quarter of a ring, centred on `direction`.
private struct Wedge: Shape {
    var direction: Angle
    /// The hole's diameter as a share of the ring's.
    var inner: CGFloat

    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        path.addArc(center: centre, radius: radius, startAngle: direction - .degrees(45), endAngle: direction + .degrees(45), clockwise: false)
        path.addArc(center: centre, radius: radius * inner, startAngle: direction + .degrees(45), endAngle: direction - .degrees(45), clockwise: true)
        path.closeSubpath()
        return path
    }
}

/// The four lines between the arrows, from the OK disc to the rim.
private struct Dividers: Shape {
    /// The disc's diameter as a share of the plate's.
    var inner: CGFloat

    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        for degrees in [45.0, 135, 225, 315] {
            let angle = Angle.degrees(degrees).radians
            let direction = CGPoint(x: cos(angle), y: sin(angle))
            path.move(to: CGPoint(x: centre.x + direction.x * radius * inner, y: centre.y + direction.y * radius * inner))
            path.addLine(to: CGPoint(x: centre.x + direction.x * radius, y: centre.y + direction.y * radius))
        }
        return path
    }
}

// MARK: - Joystick

/// A knob in a ring. Leaning on it steps the arrows at a rate set by how far it leans: a light lean crawls and a
/// full one runs at the most the TV takes. A tap on the knob that never leaves the dead zone is OK.
struct RemoteJoystick: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var touching = false
    /// The thumb's offset from the ring's centre while it is down.
    @State private var thumb: CGPoint?
    @State private var lit: DpadKey?
    /// The steps' pacing. Held apart from the view's state: the clock below runs at display rate.
    @State private var driver = StickDriver()

    /// A tap on the knob this quick, without leaving the dead zone, is OK.
    private static let tapTime = 0.25
    private static let pollInterval = Duration.milliseconds(8)

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let radius = side / 2
            let reach = radius * DpadGeometry.stickReach
            JoystickPlate(side: side, thumb: thumb, lit: lit)
                .frame(width: side, height: side)
                .contentShape(Circle())
                .gesture(drag(radius: radius, reach: reach))
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                .task(id: thumb != nil) {
                    // Frames can stall, and a finger can rest without an event: the clock keeps the repeats going.
                    while thumb != nil, !Task.isCancelled {
                        lean(reach: reach)
                        try? await Task.sleep(for: Self.pollInterval)
                    }
                }
        }
        .opacity(isEnabled ? 1 : RemoteSize.unavailable)
        .onChange(of: touching) { _, touching in
            if !touching { end(cancelled: true) }
        }
        .accessibilityRepresentation { PadAccessibility(model: model) }
        .accessibilityIdentifier("remote.joystick")
    }

    private func drag(radius: CGFloat, reach: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($touching) { _, touching, _ in touching = true }
            .onChanged { value in
                if thumb == nil {
                    driver.landedAt = ProcessInfo.processInfo.systemUptime
                    driver.left = false
                }
                thumb = CGPoint(x: value.location.x - radius, y: value.location.y - radius)
                lean(reach: reach)
            }
            .onEnded { _ in end(cancelled: false) }
    }

    /// Takes the step the thumb's lean has earned, if one is due.
    private func lean(reach: CGFloat) {
        guard let thumb else { return }
        let deflection = stickDeflection(thumb: thumb, reach: reach)
        if hypot(deflection.x, deflection.y) >= JoystickRepeater.deadIn { driver.left = true }
        let now = ProcessInfo.processInfo.systemUptime
        if let step = driver.repeater.update(now: now, dx: deflection.x, dy: deflection.y) {
            model.feedback.tick()
            model.tap(step.remoteKey)
        }
        if lit != driver.repeater.held { lit = driver.repeater.held }
    }

    private func end(cancelled: Bool) {
        guard thumb != nil else { return }
        let quick = ProcessInfo.processInfo.systemUptime - driver.landedAt <= Self.tapTime
        if !cancelled, !driver.left, quick {
            model.feedback.tick()
            model.tap(.ok)
        }
        driver.repeater.release()
        lit = nil
        withAnimation(Motion.spring(reduceMotion: reduceMotion)) { thumb = nil }
    }
}

private final class StickDriver {
    var repeater = JoystickRepeater()
    var landedAt = 0.0
    /// The thumb has left the dead zone since it landed.
    var left = false
}

private struct JoystickPlate: View {
    let side: CGFloat
    let thumb: CGPoint?
    let lit: DpadKey?

    @Environment(\.theme) private var theme

    /// Where the arrows sit, as a share of the radius.
    private static let reach: CGFloat = 0.84
    private static let chevron: CGFloat = 0.18

    var body: some View {
        let radius = side / 2
        let reach = radius * DpadGeometry.stickReach
        let deflection = thumb.map { stickDeflection(thumb: $0, reach: reach) } ?? .zero
        let dead = reach * JoystickRepeater.deadIn * 2
        let knob = radius * DpadGeometry.knobRadius * 2
        ZStack {
            Circle().fill(theme.glassRaised)
            Circle().strokeBorder(theme.edge, lineWidth: 1)
            Circle().strokeBorder(theme.edge, lineWidth: 1).frame(width: dead, height: dead)
            ForEach(Arrow.all) { arrow in
                Image(systemName: arrow.chevron)
                    .font(.system(size: radius * Self.chevron, weight: .semibold))
                    .foregroundStyle(lit == arrow.key ? theme.accentText : theme.ink2)
                    .offset(arrow.offset(at: radius * Self.reach))
            }
            Circle()
                .fill(theme.accent)
                .frame(width: knob, height: knob)
                .offset(x: deflection.x * reach, y: deflection.y * reach)
        }
    }
}
